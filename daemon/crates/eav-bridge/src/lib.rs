//! Persistent UNIX-socket bridge to `eav-bridge.el`.
//!
//! Holds *one* tokio task that owns the socket; user-facing
//! [`BridgeClient`] handles spawn requests onto that task via an mpsc queue
//! and receive responses via per-call oneshot channels. Server-pushed events
//! flow into a broadcast channel that any subscriber can `subscribe()` to.
//!
//! On connection drop we automatically attempt to reconnect with a small
//! backoff, draining inflight requests with `BridgeError::Disconnected`.

pub mod protocol;

pub use protocol::{BridgeError, Event};

use anyhow::Context;
use parking_lot::Mutex as PlMutex;
use protocol::{Inbound, Request, Response, MAX_FRAME_BYTES};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;
use thiserror::Error;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UnixStream;
use tokio::sync::{broadcast, mpsc, oneshot};

#[derive(Debug, Error)]
pub enum CallError {
    #[error("bridge error: {code}: {message}")]
    Remote { code: String, message: String },
    #[error("bridge disconnected")]
    Disconnected,
    #[error("bridge timeout after {0:?}")]
    Timeout(Duration),
    #[error("encode/decode: {0}")]
    Codec(#[from] serde_json::Error),
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
    #[error(transparent)]
    Other(#[from] anyhow::Error),
}

/// Handle to the bridge. Cheap to clone (Arc).
#[derive(Clone)]
pub struct BridgeClient {
    inner: Arc<Inner>,
}

struct Inner {
    sender: mpsc::Sender<Outbound>,
    events: broadcast::Sender<Event>,
    next_id: AtomicU64,
    socket_path: PathBuf,
}

struct Outbound {
    request: serde_json::Value,
    id: u64,
    reply: oneshot::Sender<Result<serde_json::Value, CallError>>,
}

impl BridgeClient {
    /// Connect to the bridge at SOCK and start the I/O task.
    pub async fn connect<P: Into<PathBuf>>(sock: P) -> anyhow::Result<Self> {
        let socket_path = sock.into();
        let (sender, receiver) = mpsc::channel::<Outbound>(256);
        let (events_tx, _) = broadcast::channel::<Event>(256);

        let runtime = BridgeRuntime {
            socket_path: socket_path.clone(),
            outgoing: receiver,
            events: events_tx.clone(),
            inflight: Arc::new(PlMutex::new(HashMap::new())),
        };
        tokio::spawn(runtime.run());

        Ok(BridgeClient {
            inner: Arc::new(Inner {
                sender,
                events: events_tx,
                next_id: AtomicU64::new(1),
                socket_path,
            }),
        })
    }

    pub fn socket_path(&self) -> &Path {
        &self.inner.socket_path
    }

    /// Subscribe to server-pushed events.
    pub fn subscribe(&self) -> broadcast::Receiver<Event> {
        self.inner.events.subscribe()
    }

    /// Issue a request and wait for the response (default 30 s timeout).
    pub async fn call<T: serde::de::DeserializeOwned>(
        &self,
        method: &str,
        params: serde_json::Value,
    ) -> Result<T, CallError> {
        self.call_with_timeout(method, params, Duration::from_secs(30))
            .await
    }

    pub async fn call_with_timeout<T: serde::de::DeserializeOwned>(
        &self,
        method: &str,
        params: serde_json::Value,
        timeout: Duration,
    ) -> Result<T, CallError> {
        let id = self.inner.next_id.fetch_add(1, Ordering::SeqCst);
        let payload = serde_json::to_value(Request { id, method, params })?;
        let (reply_tx, reply_rx) = oneshot::channel();
        self.inner
            .sender
            .send(Outbound {
                request: payload,
                id,
                reply: reply_tx,
            })
            .await
            .map_err(|_| CallError::Disconnected)?;
        let result = match tokio::time::timeout(timeout, reply_rx).await {
            Ok(Ok(value)) => value,
            Ok(Err(_)) => Err(CallError::Disconnected),
            Err(_) => Err(CallError::Timeout(timeout)),
        }?;
        let typed = serde_json::from_value(result)?;
        Ok(typed)
    }
}

type Inflight = Arc<PlMutex<HashMap<u64, oneshot::Sender<Result<serde_json::Value, CallError>>>>>;

struct BridgeRuntime {
    socket_path: PathBuf,
    outgoing: mpsc::Receiver<Outbound>,
    events: broadcast::Sender<Event>,
    inflight: Inflight,
}

impl BridgeRuntime {
    async fn run(mut self) {
        loop {
            match UnixStream::connect(&self.socket_path).await {
                Ok(stream) => {
                    if let Err(e) = self.session(stream).await {
                        tracing::warn!(error = ?e, "bridge session ended");
                    }
                }
                Err(e) => {
                    tracing::debug!(error = ?e, "bridge connect failed");
                }
            }
            // Drain inflight on disconnect so callers don't hang forever.
            let drained: Vec<_> = {
                let mut map = self.inflight.lock();
                map.drain().collect()
            };
            for (_, tx) in drained {
                let _ = tx.send(Err(CallError::Disconnected));
            }
            // Backoff before reconnect attempt.
            tokio::time::sleep(Duration::from_millis(500)).await;
            if self.outgoing.is_closed() {
                break;
            }
        }
    }

    /// Run one bridge session. Reader and writer live on independent tasks
    /// so neither cancels the other's I/O. Earlier we had a single
    /// `tokio::select!` over `read_exact` and `outgoing.recv()`, which
    /// looked clean but bit us hard in production: `read_exact` is not
    /// cancellation-safe — when a write fired between bytes, the partial
    /// header was discarded and subsequent reads desynced. Symptom on
    /// `visa-nonsoe`: `read.config` would block forever despite the
    /// bridge's `eav-bridge--filter` actually replying. Splitting halves
    /// makes each I/O monotonic.
    async fn session(&mut self, stream: UnixStream) -> anyhow::Result<()> {
        let (mut read_half, mut write_half) = stream.into_split();
        let inflight = Arc::clone(&self.inflight);
        let events = self.events.clone();
        let mut outgoing = std::mem::replace(
            &mut self.outgoing,
            mpsc::channel(1).1, // tiny placeholder
        );

        // Reader task: owns read_half end-to-end, never cancelled.
        let reader = tokio::spawn(async move {
            let mut header = [0u8; 4];
            let mut payload = Vec::new();
            loop {
                if read_half.read_exact(&mut header).await.is_err() {
                    return;
                }
                let len = u32::from_be_bytes(header) as usize;
                if len > MAX_FRAME_BYTES {
                    tracing::error!(len, "bridge frame too large; closing");
                    return;
                }
                payload.resize(len, 0);
                if read_half.read_exact(&mut payload).await.is_err() {
                    return;
                }
                let parsed: Inbound = match serde_json::from_slice(&payload) {
                    Ok(p) => p,
                    Err(e) => {
                        tracing::warn!(error = %e, "bridge: parse error");
                        continue;
                    }
                };
                match parsed {
                    Inbound::Response(Response {
                        id,
                        ok,
                        result,
                        error,
                    }) => {
                        let tx = { inflight.lock().remove(&id) };
                        if let Some(tx) = tx {
                            let outcome = if ok {
                                Ok(result.unwrap_or(serde_json::Value::Null))
                            } else {
                                let err = error.unwrap_or(BridgeError {
                                    code: "unknown".into(),
                                    message: "no error payload".into(),
                                });
                                Err(CallError::Remote {
                                    code: err.code,
                                    message: err.message,
                                })
                            };
                            let _ = tx.send(outcome);
                        } else {
                            tracing::warn!(id, "unmatched bridge response");
                        }
                    }
                    Inbound::Event(ev) => {
                        let _ = events.send(ev);
                    }
                }
            }
        });

        // Writer task: serialise and frame outgoing requests.
        let inflight_w = Arc::clone(&self.inflight);
        let writer = tokio::spawn(async move {
            while let Some(req) = outgoing.recv().await {
                let bytes = match serde_json::to_vec(&req.request) {
                    Ok(b) => b,
                    Err(e) => {
                        let _ = req.reply.send(Err(CallError::Codec(e)));
                        continue;
                    }
                };
                let len = bytes.len() as u32;
                let mut frame = Vec::with_capacity(4 + bytes.len());
                frame.extend_from_slice(&len.to_be_bytes());
                frame.extend_from_slice(&bytes);
                inflight_w.lock().insert(req.id, req.reply);
                if let Err(e) = write_half.write_all(&frame).await {
                    let tx = { inflight_w.lock().remove(&req.id) };
                    if let Some(tx) = tx {
                        let _ = tx.send(Err(CallError::Io(e)));
                    }
                    return outgoing;
                }
            }
            outgoing
        });

        // Wait for either side to die. If the reader dies (socket EOF /
        // broken connection) the writer follows; we restore `outgoing` so
        // queued requests survive the reconnect.
        tokio::select! {
            _ = reader => {}
            recovered = writer => {
                if let Ok(rx) = recovered {
                    self.outgoing = rx;
                }
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// End-to-end test: connect to a running Emacs bridge if the socket
    /// exists. Skipped silently when the socket isn't there (CI / no-Emacs).
    #[tokio::test]
    async fn ping_round_trip() {
        let sock = std::env::var("XDG_RUNTIME_DIR")
            .ok()
            .map(std::path::PathBuf::from)
            .unwrap_or_else(|| std::env::temp_dir())
            .join(format!("eav-bridge-{}.sock", users_uid()));
        if !sock.exists() {
            eprintln!("bridge socket not present at {sock:?}; skipping live test");
            return;
        }
        let client = BridgeClient::connect(&sock).await.unwrap();
        let result: serde_json::Value = client.call("ping", serde_json::json!({})).await.unwrap();
        assert_eq!(result.get("pong"), Some(&serde_json::Value::Bool(true)));
    }

    fn users_uid() -> u32 {
        // SAFETY: getuid() is signal-safe and never returns an error.
        unsafe { libc::getuid() }
    }
}
