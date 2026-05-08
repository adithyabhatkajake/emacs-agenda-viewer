//! SSE event channel.
//!
//! The daemon publishes four high-level events that drive UI invalidation:
//!   * `task-changed`   — single heading mutated (id known)
//!   * `file-changed`   — bulk reindex on file-system event or after-save
//!   * `clock-changed`  — clock-in/out
//!   * `config-changed` — agenda-files / keywords / priorities reload
//!
//! Internally we use a broadcast channel; SSE consumers attach a subscriber
//! and stream events as `text/event-stream` per the W3C spec.

use serde::Serialize;
use tokio::sync::broadcast;

#[derive(Debug, Clone, Serialize)]
#[serde(tag = "kind", rename_all = "kebab-case")]
pub enum ServerEvent {
    TaskChanged {
        id: String,
        file: String,
        pos: u64,
    },
    FileChanged {
        file: String,
    },
    ClockChanged {
        #[serde(skip_serializing_if = "Option::is_none")]
        file: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        pos: Option<u64>,
        clocking: bool,
    },
    ConfigChanged,
}

impl ServerEvent {
    /// SSE event name corresponding to this event variant.
    pub fn event_name(&self) -> &'static str {
        match self {
            ServerEvent::TaskChanged { .. } => "task-changed",
            ServerEvent::FileChanged { .. } => "file-changed",
            ServerEvent::ClockChanged { .. } => "clock-changed",
            ServerEvent::ConfigChanged => "config-changed",
        }
    }
}

#[derive(Clone)]
pub struct EventBus {
    sender: broadcast::Sender<ServerEvent>,
}

impl EventBus {
    pub fn new() -> Self {
        let (sender, _) = broadcast::channel(256);
        Self { sender }
    }

    pub fn publish(&self, event: ServerEvent) {
        let _ = self.sender.send(event);
    }

    pub fn subscribe(&self) -> broadcast::Receiver<ServerEvent> {
        self.sender.subscribe()
    }
}

impl Default for EventBus {
    fn default() -> Self {
        Self::new()
    }
}
