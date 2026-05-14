//! File watcher.
//!
//! Wraps `notify-debouncer-full` so callers receive at most one event per
//! changed path per debounce window (100 ms). Supports a "self-write" set:
//! when the daemon proxies a write to Emacs, the bridge marks the path; the
//! resulting fsnotify event within `SELF_WRITE_TTL` is dropped because the
//! bridge will already publish an `after-save` event of its own.

use notify::{EventKind, RecursiveMode};
use notify_debouncer_full::{new_debouncer, DebounceEventResult, Debouncer, RecommendedCache};
use parking_lot::Mutex;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::mpsc;

const DEBOUNCE: Duration = Duration::from_millis(100);
const SELF_WRITE_TTL: Duration = Duration::from_secs(2);

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FileChange {
    /// Content changed (created or modified).
    Modified(PathBuf),
    /// File was removed.
    Removed(PathBuf),
}

/// State shared between the OS watcher thread and the API surface (so callers
/// can register self-writes from any thread).
#[derive(Default)]
struct SelfWriteSet {
    pending: HashMap<PathBuf, Instant>,
}

impl SelfWriteSet {
    fn mark(&mut self, path: PathBuf) {
        self.prune();
        self.pending.insert(path, Instant::now() + SELF_WRITE_TTL);
    }

    fn consume(&mut self, path: &Path) -> bool {
        self.prune();
        match self.pending.remove(path) {
            Some(deadline) => Instant::now() < deadline,
            None => false,
        }
    }

    fn prune(&mut self) {
        let now = Instant::now();
        self.pending.retain(|_, deadline| *deadline > now);
    }
}

pub struct FileWatcher {
    _debouncer: Debouncer<notify::RecommendedWatcher, RecommendedCache>,
    self_writes: Arc<Mutex<SelfWriteSet>>,
}

impl FileWatcher {
    /// Start watching PATHS. Events arrive on the returned `mpsc::Receiver`.
    pub fn start(paths: &[PathBuf]) -> notify::Result<(Self, mpsc::UnboundedReceiver<FileChange>)> {
        let (tx, rx) = mpsc::unbounded_channel::<FileChange>();
        let self_writes: Arc<Mutex<SelfWriteSet>> = Arc::new(Mutex::new(SelfWriteSet::default()));

        let self_writes_handler = Arc::clone(&self_writes);
        let mut debouncer = new_debouncer(DEBOUNCE, None, move |result: DebounceEventResult| {
            let events = match result {
                Ok(events) => events,
                Err(errors) => {
                    for e in errors {
                        tracing::warn!(error = %e, "watcher reported error");
                    }
                    return;
                }
            };
            for ev in events {
                let kind = ev.event.kind;
                if !is_relevant(&kind) {
                    continue;
                }
                for path in &ev.event.paths {
                    let suppressed = self_writes_handler.lock().consume(path);
                    if suppressed {
                        tracing::debug!(?path, "self-write event suppressed");
                        continue;
                    }
                    let msg = match kind {
                        EventKind::Remove(_) => FileChange::Removed(path.clone()),
                        _ => FileChange::Modified(path.clone()),
                    };
                    if tx.send(msg).is_err() {
                        return;
                    }
                }
            }
        })?;

        for p in paths {
            // Watch the *parent* directory, not the file itself: rename/remove
            // events on the file would otherwise stop arriving once it's
            // deleted on a system that re-creates files atomically (write to
            // tmp, rename over). Filter back to the registered file set in the
            // index.
            if let Some(parent) = p.parent() {
                if parent.exists() {
                    debouncer.watch(parent, RecursiveMode::NonRecursive)?;
                }
            }
        }

        Ok((
            FileWatcher {
                _debouncer: debouncer,
                self_writes,
            },
            rx,
        ))
    }

    /// Suppress the next watcher event for PATH within `SELF_WRITE_TTL`.
    /// Called by the bridge layer when proxying a mutation to Emacs.
    pub fn mark_self_write(&self, path: PathBuf) {
        self.self_writes.lock().mark(path);
    }
}

fn is_relevant(kind: &EventKind) -> bool {
    matches!(
        kind,
        EventKind::Create(_) | EventKind::Modify(_) | EventKind::Remove(_)
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::time::Duration;
    use tokio::time::timeout;

    /// macOS sometimes emits no events for files inside watched dirs in CI;
    /// the test verifies the suppression logic in isolation.
    #[test]
    fn self_write_set_suppresses_within_ttl() {
        let mut set = SelfWriteSet::default();
        let p = PathBuf::from("/tmp/a.org");
        set.mark(p.clone());
        assert!(set.consume(&p));
        // Already consumed.
        assert!(!set.consume(&p));
    }

    #[tokio::test]
    async fn watches_a_real_file_change() {
        let dir = std::env::temp_dir().join(format!(
            "eavd-watcher-{}-{}",
            std::process::id(),
            rand_suffix()
        ));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let file = dir.join("x.org");
        fs::write(&file, "* TODO seed\n").unwrap();

        let (watcher, mut rx) = FileWatcher::start(std::slice::from_ref(&file)).unwrap();
        // Give the OS a moment to register.
        tokio::time::sleep(Duration::from_millis(150)).await;

        fs::write(&file, "* TODO updated\n").unwrap();

        let event = timeout(Duration::from_secs(3), rx.recv())
            .await
            .expect("watcher event timed out")
            .expect("watcher closed");
        match event {
            FileChange::Modified(p) | FileChange::Removed(p) => {
                assert_eq!(p.canonicalize().ok(), file.canonicalize().ok());
            }
        }
        drop(watcher);
    }

    fn rand_suffix() -> u64 {
        use std::time::SystemTime;
        SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .unwrap()
            .as_nanos() as u64
    }
}
