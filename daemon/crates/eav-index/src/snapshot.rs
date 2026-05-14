//! SQLite cold-start snapshot.
//!
//! Stores serialized `OrgTask` records keyed by id along with a per-file mtime
//! and the cached `FileMeta`. The snapshot is purely a cache: deleting it
//! costs at most a re-parse of every file.

use eav_core::OrgTask;
use rusqlite::{params, Connection};
use std::path::{Path, PathBuf};

/// Schema versioned via `user_version` PRAGMA. Bump when the on-disk shape
/// changes so we discard stale data instead of mis-deserialising it.
const SCHEMA_VERSION: i32 = 1;

const SCHEMA_SQL: &str = r#"
CREATE TABLE IF NOT EXISTS files (
    path  TEXT PRIMARY KEY,
    mtime INTEGER NOT NULL,
    size  INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS tasks (
    id        TEXT PRIMARY KEY,
    file      TEXT NOT NULL,
    body      TEXT NOT NULL,  -- serialized OrgTask JSON
    FOREIGN KEY (file) REFERENCES files(path) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_tasks_file ON tasks(file);
"#;

pub struct Snapshot {
    conn: Connection,
}

#[derive(Debug, Clone)]
pub struct FileEntry {
    pub path: PathBuf,
    pub mtime: i64,
    pub size: i64,
}

impl Snapshot {
    /// Open or create the snapshot at PATH, creating intermediate dirs.
    pub fn open(path: &Path) -> rusqlite::Result<Self> {
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let conn = Connection::open(path)?;
        conn.execute_batch(SCHEMA_SQL)?;
        let stored: i32 = conn.pragma_query_value(None, "user_version", |r| r.get(0))?;
        if stored != SCHEMA_VERSION {
            // Stale schema — wipe and rewrite.
            conn.execute("DELETE FROM tasks", [])?;
            conn.execute("DELETE FROM files", [])?;
            conn.pragma_update(None, "user_version", SCHEMA_VERSION)?;
        }
        Ok(Self { conn })
    }

    /// Default location: $XDG_CACHE_HOME/eavd/snapshot.sqlite, fallback
    /// ~/Library/Caches/eavd/snapshot.sqlite (macOS) or ~/.cache/eavd on Linux.
    pub fn default_path() -> PathBuf {
        if let Ok(xdg) = std::env::var("XDG_CACHE_HOME") {
            return PathBuf::from(xdg).join("eavd").join("snapshot.sqlite");
        }
        if let Ok(home) = std::env::var("HOME") {
            #[cfg(target_os = "macos")]
            {
                return PathBuf::from(home)
                    .join("Library")
                    .join("Caches")
                    .join("eavd")
                    .join("snapshot.sqlite");
            }
            #[cfg(not(target_os = "macos"))]
            {
                return PathBuf::from(home)
                    .join(".cache")
                    .join("eavd")
                    .join("snapshot.sqlite");
            }
        }
        PathBuf::from("eavd-snapshot.sqlite")
    }

    /// Replace the stored entries for FILE.
    pub fn write_file(
        &mut self,
        path: &Path,
        mtime: i64,
        size: i64,
        tasks: &[OrgTask],
    ) -> rusqlite::Result<()> {
        let tx = self.conn.transaction()?;
        let key = path.to_string_lossy();
        tx.execute("DELETE FROM tasks WHERE file = ?1", params![key])?;
        tx.execute(
            "INSERT OR REPLACE INTO files (path, mtime, size) VALUES (?1, ?2, ?3)",
            params![key, mtime, size],
        )?;
        for t in tasks {
            let body = serde_json::to_string(t).unwrap();
            tx.execute(
                "INSERT OR REPLACE INTO tasks (id, file, body) VALUES (?1, ?2, ?3)",
                params![t.id, key, body],
            )?;
        }
        tx.commit()
    }

    pub fn load_all_tasks(&self) -> rusqlite::Result<Vec<OrgTask>> {
        let mut stmt = self
            .conn
            .prepare("SELECT body FROM tasks ORDER BY file, id")?;
        let rows = stmt.query_map([], |r| {
            let body: String = r.get(0)?;
            Ok(body)
        })?;
        let mut out = Vec::new();
        for row in rows {
            let body = row?;
            if let Ok(task) = serde_json::from_str::<OrgTask>(&body) {
                out.push(task);
            }
        }
        Ok(out)
    }

    pub fn load_files(&self) -> rusqlite::Result<Vec<FileEntry>> {
        let mut stmt = self
            .conn
            .prepare("SELECT path, mtime, size FROM files ORDER BY path")?;
        let rows = stmt.query_map([], |r| {
            Ok(FileEntry {
                path: PathBuf::from(r.get::<_, String>(0)?),
                mtime: r.get(1)?,
                size: r.get(2)?,
            })
        })?;
        rows.collect()
    }

    pub fn forget_file(&mut self, path: &Path) -> rusqlite::Result<()> {
        let key = path.to_string_lossy();
        self.conn
            .execute("DELETE FROM tasks WHERE file = ?1", params![key])?;
        self.conn
            .execute("DELETE FROM files WHERE path = ?1", params![key])?;
        Ok(())
    }

    pub fn task_count(&self) -> rusqlite::Result<i64> {
        self.conn
            .query_row("SELECT COUNT(*) FROM tasks", [], |r| r.get(0))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;

    fn task(id: &str, file: &str) -> OrgTask {
        OrgTask {
            id: id.into(),
            title: "x".into(),
            todo_state: Some("TODO".into()),
            priority: None,
            tags: vec![],
            inherited_tags: vec![],
            scheduled: None,
            deadline: None,
            closed: None,
            category: "Inbox".into(),
            level: 1,
            file: file.into(),
            pos: 1,
            parent_id: None,
            effort: None,
            notes: None,
            active_timestamps: None,
            properties: Some(BTreeMap::new()),
            completions: None,
        }
    }

    #[test]
    fn round_trip() {
        let dir = tempfile_dir();
        let p = dir.join("snap.sqlite");
        let mut snap = Snapshot::open(&p).unwrap();
        snap.write_file(
            Path::new("/tmp/a.org"),
            123,
            456,
            &[task("/tmp/a.org::1", "/tmp/a.org")],
        )
        .unwrap();

        let loaded = snap.load_all_tasks().unwrap();
        assert_eq!(loaded.len(), 1);
        assert_eq!(loaded[0].id, "/tmp/a.org::1");

        let files = snap.load_files().unwrap();
        assert_eq!(files.len(), 1);
        assert_eq!(files[0].mtime, 123);
    }

    #[test]
    fn rewriting_a_file_replaces_its_tasks() {
        let dir = tempfile_dir();
        let mut snap = Snapshot::open(&dir.join("snap.sqlite")).unwrap();
        snap.write_file(
            Path::new("/tmp/x.org"),
            1,
            1,
            &[
                task("/tmp/x.org::1", "/tmp/x.org"),
                task("/tmp/x.org::2", "/tmp/x.org"),
            ],
        )
        .unwrap();
        snap.write_file(
            Path::new("/tmp/x.org"),
            2,
            2,
            &[task("/tmp/x.org::1", "/tmp/x.org")],
        )
        .unwrap();
        assert_eq!(snap.task_count().unwrap(), 1);
    }

    fn tempfile_dir() -> PathBuf {
        use std::sync::atomic::{AtomicUsize, Ordering};
        static COUNTER: AtomicUsize = AtomicUsize::new(0);
        let n = COUNTER.fetch_add(1, Ordering::SeqCst);
        let dir = std::env::temp_dir().join(format!("eavd-test-{}-{}", std::process::id(), n));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }
}
