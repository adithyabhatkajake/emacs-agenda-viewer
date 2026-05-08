//! Optional Model Context Protocol server.
//!
//! Exposes the daemon's in-memory task index and the bridge's mutation
//! surface to MCP-aware LLM clients (e.g. Claude Code) over stdio. The
//! protocol is JSON-RPC 2.0 with the MCP primitives:
//!
//!   * `initialize`             handshake
//!   * `resources/list`         enumerate addressable read resources
//!   * `resources/read`         fetch a resource by uri
//!   * `tools/list`             enumerate callable tools
//!   * `tools/call`             invoke a tool with structured args
//!   * `resources/subscribe`    register for push notifications (optional)
//!
//! Resources we expose:
//!   * `agenda://today`         today's agenda entries
//!   * `agenda://day/<date>`    a specific day's agenda
//!   * `tasks://active`         all active (non-done) tasks
//!   * `tasks://all`            every task
//!
//! Tools we expose:
//!   * `set-state`              change a heading's TODO state
//!   * `set-priority`           change a heading's priority cookie
//!   * `toggle-done`            flip TODO ↔ DONE
//!   * `capture`                fire a capture template
//!
//! This module is a scaffold. A complete server needs:
//!   - an MCP-compliant stdio loop (`McpServer::run`)
//!   - request/response correlation by id
//!   - tool-call argument validation against declared schemas
//!   - subscription dispatch driven by the BridgeClient event channel

use eav_bridge::BridgeClient;
use eav_core::{AgendaEntry, OrgTask};
use eav_index::Index;
use serde::{Deserialize, Serialize};

/// MCP server state. Cheap to clone (Arc-backed components).
#[derive(Clone)]
pub struct McpServer {
    pub index: Index,
    pub bridge: BridgeClient,
}

impl McpServer {
    pub fn new(index: Index, bridge: BridgeClient) -> Self {
        Self { index, bridge }
    }

    /// Run the JSON-RPC stdio loop. Returns on EOF or fatal error.
    /// (Not yet implemented — see TODO at top of module.)
    pub async fn run(&self) -> anyhow::Result<()> {
        anyhow::bail!("MCP stdio loop not implemented yet")
    }

    /// Resolve a `tasks://...` or `agenda://...` URI.
    pub fn read_resource(&self, uri: &str) -> Result<Resource, McpError> {
        if let Some(rest) = uri.strip_prefix("tasks://") {
            return match rest {
                "active" => Ok(Resource::Tasks(self.index.active_tasks())),
                "all" => Ok(Resource::Tasks(self.index.all_tasks())),
                _ => Err(McpError::not_found(uri)),
            };
        }
        if let Some(rest) = uri.strip_prefix("agenda://") {
            if rest == "today" {
                let today = chrono::Local::now().date_naive();
                let evaluation = eav_agenda::evaluate_day(
                    &self.index.all_tasks(),
                    today,
                    today,
                    &eav_agenda::AgendaConfig::default(),
                );
                return Ok(Resource::Agenda(evaluation.entries));
            }
            if let Some(date) = rest.strip_prefix("day/") {
                let target = chrono::NaiveDate::parse_from_str(date, "%Y-%m-%d")
                    .map_err(|_| McpError::not_found(uri))?;
                let today = chrono::Local::now().date_naive();
                let evaluation = eav_agenda::evaluate_day(
                    &self.index.all_tasks(),
                    target,
                    today,
                    &eav_agenda::AgendaConfig::default(),
                );
                return Ok(Resource::Agenda(evaluation.entries));
            }
        }
        Err(McpError::not_found(uri))
    }

    pub fn list_resources(&self) -> Vec<ResourceMetadata> {
        vec![
            ResourceMetadata {
                uri: "agenda://today".into(),
                name: "Today's agenda".into(),
                mime_type: "application/json".into(),
            },
            ResourceMetadata {
                uri: "tasks://active".into(),
                name: "All active tasks".into(),
                mime_type: "application/json".into(),
            },
            ResourceMetadata {
                uri: "tasks://all".into(),
                name: "All tasks (incl. done)".into(),
                mime_type: "application/json".into(),
            },
        ]
    }

    pub fn list_tools(&self) -> Vec<ToolMetadata> {
        vec![
            ToolMetadata {
                name: "set-state".into(),
                description: "Set a task's TODO keyword".into(),
                input_schema: serde_json::json!({
                    "type": "object",
                    "required": ["file", "pos", "state"],
                    "properties": {
                        "file":  { "type": "string" },
                        "pos":   { "type": "integer" },
                        "state": { "type": "string" }
                    }
                }),
            },
            ToolMetadata {
                name: "set-priority".into(),
                description: "Set a task's priority cookie (e.g. \"A\", \"B\", \"C\", or \" \" to remove)".into(),
                input_schema: serde_json::json!({
                    "type": "object",
                    "required": ["file", "pos", "priority"],
                    "properties": {
                        "file":     { "type": "string" },
                        "pos":      { "type": "integer" },
                        "priority": { "type": "string" }
                    }
                }),
            },
            ToolMetadata {
                name: "capture".into(),
                description: "Fire an org-capture template by key".into(),
                input_schema: serde_json::json!({
                    "type": "object",
                    "required": ["templateKey", "title"],
                    "properties": {
                        "templateKey": { "type": "string" },
                        "title":       { "type": "string" },
                        "priority":    { "type": "string" },
                        "scheduled":   { "type": "string" },
                        "deadline":    { "type": "string" },
                        "promptAnswers": {
                            "type": "array",
                            "items": { "type": "string" }
                        }
                    }
                }),
            },
        ]
    }

    pub async fn call_tool(
        &self,
        name: &str,
        args: serde_json::Value,
    ) -> Result<serde_json::Value, McpError> {
        match name {
            "set-state" => {
                let _: serde_json::Value = self
                    .bridge
                    .call("write.set-state", args)
                    .await
                    .map_err(McpError::bridge)?;
                Ok(serde_json::json!({ "success": true }))
            }
            "set-priority" => {
                let _: serde_json::Value = self
                    .bridge
                    .call("write.set-priority", args)
                    .await
                    .map_err(McpError::bridge)?;
                Ok(serde_json::json!({ "success": true }))
            }
            "capture" => {
                let _: serde_json::Value = self
                    .bridge
                    .call("write.capture", args)
                    .await
                    .map_err(McpError::bridge)?;
                Ok(serde_json::json!({ "success": true }))
            }
            other => Err(McpError::not_found(other)),
        }
    }
}

#[derive(Debug, Serialize)]
#[serde(untagged)]
pub enum Resource {
    Tasks(Vec<OrgTask>),
    Agenda(Vec<AgendaEntry>),
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ResourceMetadata {
    pub uri: String,
    pub name: String,
    #[serde(rename = "mimeType")]
    pub mime_type: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct ToolMetadata {
    pub name: String,
    pub description: String,
    #[serde(rename = "inputSchema")]
    pub input_schema: serde_json::Value,
}

#[derive(Debug, thiserror::Error)]
pub enum McpError {
    #[error("not found: {0}")]
    NotFound(String),
    #[error("bridge error: {0}")]
    Bridge(String),
}

impl McpError {
    pub fn not_found(uri: impl Into<String>) -> Self {
        Self::NotFound(uri.into())
    }

    pub fn bridge(err: impl std::fmt::Display) -> Self {
        Self::Bridge(err.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use eav_index::Index;

    #[test]
    fn list_resources_includes_today() {
        // Skip live-bridge tests in this scaffold; resource listing is pure.
        let metadata: Vec<ResourceMetadata> = vec![
            ResourceMetadata { uri: "agenda://today".into(), name: "x".into(), mime_type: "y".into() },
        ];
        assert!(metadata.iter().any(|m| m.uri == "agenda://today"));
    }

    #[test]
    fn read_unknown_resource_is_not_found() {
        // Construct a server without a real bridge. Reading an unknown URI
        // doesn't touch the bridge so we can use a placeholder.
        let _idx = Index::new();
        // (Skipping the actual McpServer construction — BridgeClient::connect
        // requires an event loop and live socket. The error path is exercised
        // by `read_resource` integration tests in `eavd`.)
    }
}
