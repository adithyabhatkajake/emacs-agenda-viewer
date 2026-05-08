//! Length-prefixed JSON frame format shared with `elisp/eav-bridge.el`.

use serde::{Deserialize, Serialize};

/// Outbound request to the Emacs bridge.
#[derive(Debug, Serialize)]
pub struct Request<'a> {
    pub id: u64,
    pub method: &'a str,
    pub params: serde_json::Value,
}

/// Inbound message from the bridge: either a response (id present) or a
/// pushed event (event field present, no id).
#[derive(Debug, Deserialize)]
#[serde(untagged)]
pub enum Inbound {
    Response(Response),
    Event(Event),
}

#[derive(Debug, Deserialize)]
pub struct Response {
    pub id: u64,
    pub ok: bool,
    #[serde(default)]
    pub result: Option<serde_json::Value>,
    #[serde(default)]
    pub error: Option<BridgeError>,
}

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct BridgeError {
    pub code: String,
    pub message: String,
}

#[derive(Debug, Deserialize, Clone)]
pub struct Event {
    pub event: String,
    #[serde(default)]
    pub params: serde_json::Value,
}

/// Maximum bridge frame payload size — keeps a single bad header from
/// getting us to allocate gigabytes. Bumped 32 MiB which comfortably fits
/// the largest org file dump we've seen (~200 KB).
pub const MAX_FRAME_BYTES: usize = 32 * 1024 * 1024;
