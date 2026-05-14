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
use eav_index::Index;
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
    pub fn new(index: Index, bridge: BridgeClient) -> Self {
        Self {
            index,
            bridge,
            events: EventBus::new(),
            cached_config: Arc::new(RwLock::new(CachedConfig::default())),
            agenda_config: AgendaConfig::default(),
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
