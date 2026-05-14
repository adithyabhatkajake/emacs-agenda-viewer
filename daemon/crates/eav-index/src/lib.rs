//! In-memory task index with secondary lookups by file, tag, and date bucket.
//!
//! Phase 1 owns the data structure and the rebuild path; phase 2 adds the
//! `notify` watcher and SQLite snapshot persistence.

pub mod snapshot;
pub mod watcher;

pub use snapshot::{FileEntry, Snapshot};
pub use watcher::{FileChange, FileWatcher};

use eav_core::OrgTask;
use eav_parse::{extract_tasks_from_source_with, FileMeta, GlobalKeywords};
use parking_lot::RwLock;
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::path::{Path, PathBuf};
use std::sync::Arc;

/// The shared index. Cheap to clone (Arc).
#[derive(Debug, Clone, Default)]
pub struct Index {
    inner: Arc<RwLock<IndexInner>>,
}

#[derive(Debug, Default)]
struct IndexInner {
    /// Tasks keyed by their stable id (`OrgTask::id`).
    tasks: BTreeMap<String, OrgTask>,
    /// File path -> list of task ids in that file (insertion order preserved).
    by_file: HashMap<PathBuf, Vec<String>>,
    /// File path -> per-file resolved metadata (categories, keyword sequences, ...).
    file_meta: HashMap<PathBuf, FileMeta>,
    /// Tag -> set of task ids (includes both local and inherited).
    by_tag: HashMap<String, BTreeSet<String>>,
    /// YYYY-MM-DD -> set of task ids that have any timestamp matching that date.
    by_date: BTreeMap<String, BTreeSet<String>>,
    /// User's global TODO keywords (from Emacs config) used as fallback when
    /// a file has no `#+TODO:` line.
    globals: Option<GlobalKeywords>,
}

impl Index {
    pub fn new() -> Self {
        Self::default()
    }

    /// Set the global TODO-keyword fallback used for files without a
    /// `#+TODO:` line. Triggers a full reindex of currently-known files.
    pub fn set_global_keywords(&self, kws: GlobalKeywords) {
        let to_rebuild = {
            let mut inner = self.inner.write();
            inner.globals = Some(kws);
            inner.by_file.keys().cloned().collect::<Vec<_>>()
        };
        for path in to_rebuild {
            if let Ok(text) = std::fs::read_to_string(&path) {
                self.rebuild_file(&path, &text);
            }
        }
    }

    /// Replace the index entries for FILE with FILE's current contents.
    /// Returns (added_or_changed_ids, removed_ids).
    ///
    /// The input `path` is canonicalised (symlinks resolved) before it's
    /// used as a key in any of the secondary maps. This matches what the
    /// parser writes into `OrgTask.file` (which is also canonicalised) and
    /// what the SQLite snapshot persists, so a path arriving as a symlink
    /// (`~/iCloud/Notes/foo.org`) ends up under the same key as the same
    /// file arriving canonical (`~/Library/Mobile Documents/.../foo.org`).
    /// Without this, snapshot-load + live-rebuild would each populate
    /// `by_file` under a different key, doubling the visible task list.
    pub fn rebuild_file(
        &self,
        path: &Path,
        source: &str,
    ) -> (Vec<String>, Vec<String>) {
        let canonical = canonicalize_path(path);
        let globals = self.inner.read().globals.clone();
        let (tasks, meta) = extract_tasks_from_source_with(source, &canonical, globals.as_ref());

        let mut inner = self.inner.write();

        // Remove old entries for this file.
        let removed: Vec<String> = inner
            .by_file
            .get(&canonical)
            .cloned()
            .unwrap_or_default();
        for id in &removed {
            if let Some(old) = inner.tasks.remove(id) {
                strip_secondary(&mut inner, &old);
            }
        }
        inner.by_file.remove(&canonical);

        // Insert fresh entries.
        let mut new_ids = Vec::with_capacity(tasks.len());
        for task in &tasks {
            new_ids.push(task.id.clone());
        }
        for task in tasks {
            insert_secondary(&mut inner, &task);
            inner.tasks.insert(task.id.clone(), task);
        }
        inner.by_file.insert(canonical.clone(), new_ids.clone());
        inner.file_meta.insert(canonical, meta);

        let removed_ids: Vec<String> = removed
            .into_iter()
            .filter(|id| !inner.tasks.contains_key(id))
            .collect();
        (new_ids, removed_ids)
    }

    /// Drop all tasks belonging to FILE (e.g. for an unwatched file).
    pub fn drop_file(&self, path: &Path) -> Vec<String> {
        let canonical = canonicalize_path(path);
        let mut inner = self.inner.write();
        let ids = inner.by_file.remove(&canonical).unwrap_or_default();
        inner.file_meta.remove(&canonical);
        for id in &ids {
            if let Some(t) = inner.tasks.remove(id) {
                strip_secondary(&mut inner, &t);
            }
        }
        ids
    }

    /// All TODO-bearing entries across all files (insertion order is file
    /// order then heading order within file). Matches the Express
    /// `eav-extract-all-tasks` semantics: only headings whose `todo_state`
    /// is set show up here. Calendar-style headings (no TODO keyword,
    /// agenda-relevant only) are excluded — see `all_agenda_entries`.
    pub fn all_tasks(&self) -> Vec<OrgTask> {
        let inner = self.inner.read();
        let mut files: Vec<&PathBuf> = inner.by_file.keys().collect();
        files.sort();
        let mut out = Vec::with_capacity(inner.tasks.len());
        for f in files {
            for id in &inner.by_file[f] {
                if let Some(t) = inner.tasks.get(id) {
                    if t.todo_state.is_some() {
                        out.push(t.clone());
                    }
                }
            }
        }
        out
    }

    /// Every indexed entry, including non-TODO calendar headings that the
    /// agenda evaluator needs. Don't expose this through the tasks endpoint.
    pub fn all_agenda_entries(&self) -> Vec<OrgTask> {
        let inner = self.inner.read();
        let mut files: Vec<&PathBuf> = inner.by_file.keys().collect();
        files.sort();
        let mut out = Vec::with_capacity(inner.tasks.len());
        for f in files {
            for id in &inner.by_file[f] {
                if let Some(t) = inner.tasks.get(id) {
                    out.push(t.clone());
                }
            }
        }
        out
    }

    /// Active tasks: those whose `todo_state` is in the active half of the
    /// owning file's keyword sequence (i.e. not done).
    pub fn active_tasks(&self) -> Vec<OrgTask> {
        let inner = self.inner.read();
        let mut files: Vec<&PathBuf> = inner.by_file.keys().collect();
        files.sort();
        let mut out = Vec::new();
        for f in files {
            let meta = match inner.file_meta.get(f) {
                Some(m) => m,
                None => continue,
            };
            for id in &inner.by_file[f] {
                if let Some(t) = inner.tasks.get(id) {
                    if let Some(state) = t.todo_state.as_deref() {
                        if !meta.is_done_keyword(state) {
                            out.push(t.clone());
                        }
                    }
                }
            }
        }
        out
    }

    pub fn task_by_id(&self, id: &str) -> Option<OrgTask> {
        self.inner.read().tasks.get(id).cloned()
    }

    pub fn tasks_in_file(&self, path: &Path) -> Vec<OrgTask> {
        let canonical = canonicalize_path(path);
        let inner = self.inner.read();
        let mut out = Vec::new();
        if let Some(ids) = inner.by_file.get(&canonical) {
            for id in ids {
                if let Some(t) = inner.tasks.get(id) {
                    out.push(t.clone());
                }
            }
        }
        out
    }

    pub fn tasks_by_date(&self, date: &str) -> Vec<OrgTask> {
        let inner = self.inner.read();
        let Some(ids) = inner.by_date.get(date) else {
            return Vec::new();
        };
        ids.iter()
            .filter_map(|id| inner.tasks.get(id).cloned())
            .collect()
    }

    pub fn tasks_by_tag(&self, tag: &str) -> Vec<OrgTask> {
        let inner = self.inner.read();
        let Some(ids) = inner.by_tag.get(tag) else {
            return Vec::new();
        };
        ids.iter()
            .filter_map(|id| inner.tasks.get(id).cloned())
            .collect()
    }

    pub fn known_files(&self) -> Vec<PathBuf> {
        let inner = self.inner.read();
        let mut files: Vec<PathBuf> = inner.by_file.keys().cloned().collect();
        files.sort();
        files
    }

    pub fn file_meta(&self, path: &Path) -> Option<FileMeta> {
        let canonical = canonicalize_path(path);
        self.inner.read().file_meta.get(&canonical).cloned()
    }

    pub fn task_count(&self) -> usize {
        self.inner.read().tasks.len()
    }

    /// Populate the index from a snapshot. Used at cold start while the live
    /// reindex runs in the background.
    ///
    /// Critically: canonicalize the path before storing it in `by_file` so
    /// that the subsequent live `rebuild_file` (which always canonicalizes)
    /// targets the same bucket. Without this, the snapshot path and the
    /// live-reindex path can differ — most often when the user's agenda
    /// files sit under iCloud Drive, where macOS sometimes returns the same
    /// file via two different superficial path forms — and every task ends
    /// up in two `by_file` buckets, doubling all read paths.
    pub fn load_snapshot(&self, snap: &Snapshot) -> rusqlite::Result<()> {
        let tasks = snap.load_all_tasks()?;
        let mut inner = self.inner.write();
        for t in tasks {
            let path = canonicalize_path(&std::path::PathBuf::from(&t.file));
            inner.by_file.entry(path).or_default().push(t.id.clone());
            insert_secondary(&mut inner, &t);
            inner.tasks.insert(t.id.clone(), t);
        }
        Ok(())
    }

    /// Persist the in-memory index to SNAP. Overwrites previous content.
    pub fn save_snapshot(&self, snap: &mut Snapshot) -> rusqlite::Result<()> {
        // Group tasks by file in order to call snap.write_file() once per file.
        let groups: Vec<(std::path::PathBuf, i64, i64, Vec<OrgTask>)> = {
            let inner = self.inner.read();
            let mut groups = Vec::new();
            for (path, ids) in inner.by_file.iter() {
                let (mtime, size) = std::fs::metadata(path)
                    .ok()
                    .map(|m| {
                        let mtime = m
                            .modified()
                            .ok()
                            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                            .map(|d| d.as_secs() as i64)
                            .unwrap_or(0);
                        (mtime, m.len() as i64)
                    })
                    .unwrap_or((0, 0));
                let tasks: Vec<OrgTask> = ids
                    .iter()
                    .filter_map(|id| inner.tasks.get(id).cloned())
                    .collect();
                groups.push((path.clone(), mtime, size, tasks));
            }
            groups
        };
        for (path, mtime, size, tasks) in groups {
            snap.write_file(&path, mtime, size, &tasks)?;
        }
        Ok(())
    }
}

/// Resolve a path the same way the parser does, so the key we store in
/// `by_file` matches the `file` field on each `OrgTask` and the path that
/// the SQLite snapshot persists. Falls back to the input path on resolve
/// failure (e.g. the file was deleted).
fn canonicalize_path(path: &Path) -> PathBuf {
    std::fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf())
}

fn task_dates(t: &OrgTask) -> BTreeSet<String> {
    let mut out = BTreeSet::new();
    if let Some(ts) = &t.scheduled {
        out.insert(format_ymd(ts));
    }
    if let Some(ts) = &t.deadline {
        out.insert(format_ymd(ts));
    }
    if let Some(stamps) = &t.active_timestamps {
        for ts in stamps {
            out.insert(format_ymd(ts));
        }
    }
    out
}

fn format_ymd(ts: &eav_core::OrgTimestamp) -> String {
    format!(
        "{:04}-{:02}-{:02}",
        ts.start.year, ts.start.month, ts.start.day
    )
}

fn insert_secondary(inner: &mut IndexInner, task: &OrgTask) {
    for tag in task.tags.iter().chain(task.inherited_tags.iter()) {
        inner
            .by_tag
            .entry(tag.clone())
            .or_default()
            .insert(task.id.clone());
    }
    for date in task_dates(task) {
        inner
            .by_date
            .entry(date)
            .or_default()
            .insert(task.id.clone());
    }
}

fn strip_secondary(inner: &mut IndexInner, task: &OrgTask) {
    for tag in task.tags.iter().chain(task.inherited_tags.iter()) {
        if let Some(set) = inner.by_tag.get_mut(tag) {
            set.remove(&task.id);
        }
    }
    for date in task_dates(task) {
        if let Some(set) = inner.by_date.get_mut(&date) {
            set.remove(&task.id);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn fixture(path: &str) -> PathBuf {
        PathBuf::from(path)
    }

    #[test]
    fn rebuild_replaces_file_tasks() {
        let idx = Index::new();
        let p = fixture("/tmp/work.org");
        let v1 = "* TODO first\n* TODO second\n";
        let (added, removed) = idx.rebuild_file(&p, v1);
        assert_eq!(added.len(), 2);
        assert!(removed.is_empty());
        assert_eq!(idx.task_count(), 2);

        // v2 keeps the first heading at the same byte offset (synthetic id =
        // file::1 for both v1 and v2), so it counts as "changed" rather than
        // "removed". Only the second heading actually disappears.
        let v2 = "* TODO renamed\n";
        let (added, removed) = idx.rebuild_file(&p, v2);
        assert_eq!(added.len(), 1);
        assert_eq!(removed.len(), 1);
        assert_eq!(idx.task_count(), 1);
    }

    #[test]
    fn active_filters_done() {
        let idx = Index::new();
        let p = fixture("/tmp/x.org");
        idx.rebuild_file(&p, "* TODO open\n* DONE shut\n");
        let active = idx.active_tasks();
        let titles: Vec<&str> = active.iter().map(|t| t.title.as_str()).collect();
        assert_eq!(titles, vec!["open"]);
        assert_eq!(idx.all_tasks().len(), 2);
    }

    #[test]
    fn date_index_picks_up_scheduled() {
        let idx = Index::new();
        let p = fixture("/tmp/sched.org");
        idx.rebuild_file(
            &p,
            "* TODO meeting\nSCHEDULED: <2026-05-07 Thu 10:00>\n",
        );
        let on_date = idx.tasks_by_date("2026-05-07");
        assert_eq!(on_date.len(), 1);
        let elsewhere = idx.tasks_by_date("2026-05-08");
        assert!(elsewhere.is_empty());
    }

    #[test]
    fn tag_index_includes_inherited() {
        let idx = Index::new();
        let p = fixture("/tmp/tags.org");
        idx.rebuild_file(
            &p,
            "#+FILETAGS: :proj:\n* Parent :work:\n** TODO Child :urgent:\n",
        );
        assert_eq!(idx.tasks_by_tag("proj").len(), 1);
        assert_eq!(idx.tasks_by_tag("work").len(), 1);
        assert_eq!(idx.tasks_by_tag("urgent").len(), 1);
    }

    /// Regression: a file accessed by both its symlink path and its
    /// canonicalised path used to populate `by_file` under two different
    /// keys, so the snapshot-load + live-reindex sequence the daemon does
    /// at startup would surface every task twice. Canonicalising at
    /// `rebuild_file` collapses the two keys.
    #[test]
    fn rebuild_via_symlink_does_not_double_count() {
        use std::sync::atomic::{AtomicUsize, Ordering};
        static N: AtomicUsize = AtomicUsize::new(0);
        let n = N.fetch_add(1, Ordering::SeqCst);
        let dir = std::env::temp_dir().join(format!("eavd-symlink-{}-{}", std::process::id(), n));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let real = dir.join("real.org");
        std::fs::write(&real, "* TODO seed\n* TODO second\n").unwrap();
        let link = dir.join("link.org");
        std::os::unix::fs::symlink(&real, &link).unwrap();
        // Sanity: the two paths point at the same file but differ as strings.
        assert_ne!(real, link);
        let real_canonical = std::fs::canonicalize(&real).unwrap();
        let link_canonical = std::fs::canonicalize(&link).unwrap();
        assert_eq!(real_canonical, link_canonical);

        let idx = Index::new();
        let text = std::fs::read_to_string(&real).unwrap();

        // First pass via the canonical path (mirrors snapshot-load).
        idx.rebuild_file(&real, &text);
        assert_eq!(idx.task_count(), 2);
        assert_eq!(idx.all_tasks().len(), 2);

        // Second pass via the symlink (mirrors the bridge's "agenda files"
        // arriving with the user's `~/iCloud/...` path).
        idx.rebuild_file(&link, &text);
        // Canonicalisation collapses the two keys into one — task count
        // stays at 2 instead of jumping to 4.
        assert_eq!(idx.task_count(), 2, "tasks doubled — symlink and canonical path produced separate by_file keys");
        assert_eq!(idx.all_tasks().len(), 2, "all_tasks duplicated tasks");
        assert_eq!(idx.known_files().len(), 1, "by_file should have a single key after canonicalisation");
    }
}
