//! axum HTTP server + SSE event stream.
//!
//! Matches the existing Express surface route-for-route so the Mac/web
//! clients can flip transports with no other changes. Reads come from the
//! in-memory index when possible; mutations and the residual reads
//! (sexp-bearing days, capture templates) go through the persistent
//! `BridgeClient`.

pub mod events;
pub mod routes;

use axum::Router;
use eav_agenda::AgendaConfig;
use eav_bridge::BridgeClient;
use eav_core::{AgendaFile, OrgConfig, OrgListConfig, OrgPriorities, TodoKeywords};
use eav_index::{Index, Store};
use parking_lot::{Mutex, RwLock};
use std::path::PathBuf;
use std::sync::Arc;
use tokio::sync::{broadcast, oneshot};
use tower_http::services::{ServeDir, ServeFile};

pub use events::{EventBus, ServerEvent};

/// Cached bridge-only metadata refreshed on `config-changed` events. Keeping
/// it cached avoids a bridge round-trip for every `/api/files` etc. read.
#[derive(Default, Clone)]
pub struct CachedConfig {
    pub files: Vec<AgendaFile>,
    pub keywords: Option<TodoKeywords>,
    pub priorities: Option<OrgPriorities>,
    pub config: Option<OrgConfig>,
    pub list_config: Option<OrgListConfig>,
}

#[derive(Clone)]
pub struct AppState {
    pub index: Index,
    pub bridge: BridgeClient,
    pub events: EventBus,
    pub cached_config: Arc<RwLock<CachedConfig>>,
    pub agenda_config: AgendaConfig,
    /// Durable store for clocks and habit completions. Separate from the
    /// snapshot cache — data here survives schema bumps and daemon restarts.
    pub store: Store,
    /// When set, the router serves SPA assets from this directory and
    /// falls back to `index.html` for unknown paths (client-side routing).
    /// Replaces the old Express `app.use(express.static(...))` setup that
    /// the legacy server used to host the React frontend on the same port.
    pub static_dir: Option<PathBuf>,
    /// One-shot used by `POST /api/shutdown` to trigger axum's graceful
    /// shutdown. Wrapped in a Mutex<Option<…>> because `oneshot::Sender`
    /// is single-use; `AppState` itself stays Clone-friendly so handlers
    /// can keep using `State<AppState>`.
    pub shutdown_tx: Arc<Mutex<Option<oneshot::Sender<()>>>>,
}

impl AppState {
    pub fn new(index: Index, bridge: BridgeClient, store: Store) -> Self {
        Self {
            index,
            bridge,
            events: EventBus::new(),
            cached_config: Arc::new(RwLock::new(CachedConfig::default())),
            agenda_config: AgendaConfig::default(),
            store,
            static_dir: None,
            shutdown_tx: Arc::new(Mutex::new(None)),
        }
    }

    pub fn with_static_dir(mut self, dir: Option<PathBuf>) -> Self {
        self.static_dir = dir;
        self
    }

    /// Stash the shutdown trigger. Call once at startup with the `Sender`
    /// end of a `oneshot::channel`; the `Receiver` is the `with_graceful_shutdown`
    /// future passed to `axum::serve`.
    pub fn with_shutdown_tx(mut self, tx: oneshot::Sender<()>) -> Self {
        self.shutdown_tx = Arc::new(Mutex::new(Some(tx)));
        self
    }

    pub fn subscribe_events(&self) -> broadcast::Receiver<ServerEvent> {
        self.events.subscribe()
    }

    /// Synchronously re-index every org file a just-proxied write touched, so
    /// a client that reads immediately after its own mutation sees fresh data.
    ///
    /// Without this the in-memory index only catches up later, via the bridge's
    /// async `after-save` event (see eavd's `"after-save"` handler), which races
    /// the HTTP response: the client's post-mutation refresh reads the stale
    /// index and the row flickers (done → not-done → done; priority reverts on
    /// refresh). Emacs has already `save-buffer`'d the affected file(s) to disk
    /// by the time the bridge call returns, so re-reading here is safe. The
    /// async after-save reindex still fires (and notifies *other* clients via
    /// SSE) — calling `rebuild_file` twice with the same content is idempotent.
    ///
    /// File paths are read from the write body's common keys; archive's
    /// `.org_archive` destination and capture targets that aren't passed
    /// explicitly aren't tracked here and fall through to the after-save path.
    pub fn reindex_after_write(&self, body: &serde_json::Value) {
        for key in ["file", "sourceFile", "targetFile"] {
            let Some(file) = body.get(key).and_then(|v| v.as_str()) else {
                continue;
            };
            let path = std::path::Path::new(file);
            match std::fs::read_to_string(path) {
                Ok(text) => {
                    self.index.rebuild_file(path, &text);
                }
                Err(e) => {
                    // Untracked/unreadable path (e.g. archive destination) —
                    // leave the async after-save / watcher path to reconcile.
                    tracing::debug!(file, error = %e, "post-write reindex skipped");
                }
            }
        }
    }
}

/// Build the axum Router with all `/api/*` routes wired up. If `state` has
/// a `static_dir`, also mount a SPA fallback service for non-API paths.
pub fn build_router(state: AppState) -> Router {
    let static_dir = state.static_dir.clone();
    let api = routes::router(state);
    if let Some(dir) = static_dir {
        if dir.exists() {
            // SPA convention: any unknown path serves index.html so the
            // client-side router can pick it up. ServeDir handles real
            // files first; the not-found-service handles the rest.
            let index = dir.join("index.html");
            let serve = ServeDir::new(&dir).not_found_service(ServeFile::new(&index));
            api.fallback_service(serve)
        } else {
            tracing::warn!(?dir, "static-dir does not exist; SPA fallback disabled");
            api
        }
    } else {
        api
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use eav_bridge::BridgeClient;
    use eav_index::{Index, Store};

    /// Regression: after a proxied write (Emacs has already saved the file to
    /// disk), `reindex_after_write` must make the in-memory index reflect the
    /// new content *synchronously* — before the HTTP response returns — so a
    /// client refreshing immediately doesn't read the stale pre-write task and
    /// flicker (done → not-done → done). Mirrors the eavd write-path flow.
    #[tokio::test]
    async fn reindex_after_write_refreshes_index_synchronously() {
        let dir = std::env::temp_dir().join(format!("eav-raw-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("t.org");

        // Initial index state: one TODO task (as it was before the mutation).
        std::fs::write(&file, "* TODO foo\n").unwrap();
        let index = Index::new();
        index.rebuild_file(&file, "* TODO foo\n");

        // A bridge client that never connects is fine — reindex_after_write
        // touches only the index and the filesystem, never the bridge.
        let bridge = BridgeClient::connect(dir.join("nonexistent.sock"))
            .await
            .unwrap();
        let store = Store::open_in_memory().unwrap();
        let state = AppState::new(index, bridge, store);

        // Emacs saved the new (DONE) content to disk during the bridge call,
        // but the index hasn't been told yet — this is the stale window.
        std::fs::write(&file, "* DONE foo\n").unwrap();
        let stale = state.index.all_tasks();
        assert_eq!(stale.len(), 1);
        assert_eq!(stale[0].todo_state.as_deref(), Some("TODO"));

        // The post-write reindex closes the window immediately.
        let body = serde_json::json!({ "file": file.to_string_lossy() });
        state.reindex_after_write(&body);

        let fresh = state.index.all_tasks();
        assert_eq!(fresh.len(), 1);
        assert_eq!(fresh[0].todo_state.as_deref(), Some("DONE"));

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A body with no recognizable file key (e.g. a capture whose destination
    /// is template-resolved) must be a no-op, not a panic.
    #[tokio::test]
    async fn reindex_after_write_without_file_key_is_noop() {
        let index = Index::new();
        let bridge = BridgeClient::connect(std::env::temp_dir().join("nope.sock"))
            .await
            .unwrap();
        let store = Store::open_in_memory().unwrap();
        let state = AppState::new(index, bridge, store);
        state.reindex_after_write(&serde_json::json!({ "template": "t" }));
        assert_eq!(state.index.task_count(), 0);
    }
}
