//! MCP (Model Context Protocol) server for eavd.
//!
//! Exposes read + write org-agenda tools via the Streamable-HTTP transport on
//! its own TCP listener (default port 3003). Shares the live `AppState` directly
//! — no HTTP hop to port 3002.
//!
//! Architecture: rmcp's StreamableHttpService is a tower::Service; we mount it
//! on an axum 0.8 Router on a dedicated TcpListener. eav-server keeps axum 0.7
//! unchanged — the two Routers never merge. eav-mcp adds axum 0.8 as its own
//! direct dep, which Cargo's resolver allows because they have distinct semver.

use std::net::{IpAddr, SocketAddr};
use std::path::Path;
use std::sync::Arc;

use anyhow::Context as _;
use axum::routing::any_service;
use eav_agenda::{evaluate_day, evaluate_range};
use eav_core::RefileTarget;
use eav_server::AppState;
use rmcp::transport::streamable_http_server::{
    session::local::LocalSessionManager, StreamableHttpServerConfig, StreamableHttpService,
};
use rmcp::{
    handler::server::{router::tool::ToolRouter, wrapper::Parameters},
    model::{CallToolResult, Content, Implementation, ServerCapabilities, ServerInfo},
    tool, tool_handler, tool_router, ServerHandler,
};
use schemars::JsonSchema;
use serde::Deserialize;
use tokio::sync::oneshot;

// ----------------------------------------------------------------------------
// Argument structs
// ----------------------------------------------------------------------------

#[derive(Debug, Deserialize, JsonSchema)]
pub struct ListTasksArgs {
    /// "active" (non-done tasks) or "all" (every TODO-bearing heading)
    pub scope: Option<String>,
    /// Filter by tag — returns only tasks carrying this tag or inheriting it.
    pub tag: Option<String>,
    /// Filter by date (YYYY-MM-DD) — returns only tasks with a timestamp on that day.
    pub date: Option<String>,
    /// Filter by project — returns only tasks whose file path contains this substring (case-insensitive).
    pub project: Option<String>,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct SearchTasksArgs {
    /// Case-insensitive substring matched against the task title.
    pub query: String,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct GetTaskArgs {
    /// Stable task id (the `id` field on OrgTask).
    pub id: String,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct GetAgendaArgs {
    /// Date to evaluate (YYYY-MM-DD).
    pub date: String,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct GetAgendaRangeArgs {
    /// Start of the range inclusive (YYYY-MM-DD).
    pub start: String,
    /// End of the range inclusive (YYYY-MM-DD).
    pub end: String,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct CreateTaskArgs {
    /// Capture template key (e.g. "t" for task, "n" for note).
    pub template: String,
    /// Content to fill into the template.
    pub content: String,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct SetTaskStateArgs {
    /// Task id.
    pub id: String,
    /// New TODO state (e.g. "DONE", "TODO", "IN-PROGRESS").
    pub state: String,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct SetTaskScheduledArgs {
    /// Task id.
    pub id: String,
    /// Org timestamp string, or empty/absent to clear.
    pub timestamp: Option<String>,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct SetTaskDeadlineArgs {
    /// Task id.
    pub id: String,
    /// Org timestamp string, or empty/absent to clear.
    pub timestamp: Option<String>,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct SetTaskPriorityArgs {
    /// Task id.
    pub id: String,
    /// Priority letter ("A", "B", "C"), or absent to clear.
    pub priority: Option<String>,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct SetTaskTagsArgs {
    /// Task id.
    pub id: String,
    /// Complete replacement tag list.
    pub tags: Vec<String>,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct SetTaskNotesArgs {
    /// Task id.
    pub id: String,
    /// New notes body (replaces existing notes).
    pub notes: String,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct ListLocationsArgs {
    /// Case-insensitive substring filter against the heading path (e.g. "Inbox", "Paper").
    pub query: Option<String>,
    /// Case-insensitive substring filter against the file path or basename (e.g. "flexpay").
    pub project: Option<String>,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct AddTaskArgs {
    /// Task title (required).
    pub title: String,
    /// Project file name or path substring — used to resolve the target file.
    pub project: Option<String>,
    /// Exact location id ("file:pos") from list_locations — overrides project-only Inbox resolution.
    pub location_id: Option<String>,
    /// Existing task id — new task becomes a sub-task nested directly under it.
    pub parent_task_id: Option<String>,
    /// TODO keyword. Defaults to the first active keyword from config (usually "TODO").
    pub todo_state: Option<String>,
    /// Priority letter ("A", "B", "C").
    pub priority: Option<String>,
    /// Scheduled date (YYYY-MM-DD).
    pub scheduled: Option<String>,
    /// Deadline date (YYYY-MM-DD).
    pub deadline: Option<String>,
    /// Tags to attach.
    pub tags: Option<Vec<String>>,
    /// Additional body text appended after the heading (and planning line if any).
    pub body: Option<String>,
    /// Insert at the top of the target section rather than the bottom (default false).
    pub prepend: Option<bool>,
}

// ----------------------------------------------------------------------------
// Server struct
// ----------------------------------------------------------------------------

#[derive(Clone)]
pub struct EavMcpServer {
    state: AppState,
    tool_router: ToolRouter<Self>,
}

impl EavMcpServer {
    fn new(state: AppState) -> Self {
        Self {
            state,
            tool_router: Self::tool_router(),
        }
    }

    fn task_file_pos(&self, id: &str) -> Option<(String, u64)> {
        let task = self.state.index.task_by_id(id)?;
        Some((task.file, task.pos))
    }

    fn ok_json<T: serde::Serialize>(v: &T) -> CallToolResult {
        match serde_json::to_value(v) {
            Ok(val) => CallToolResult::structured(val),
            Err(e) => CallToolResult::error(vec![Content::text(format!("serialize error: {e}"))]),
        }
    }

    fn err_text(msg: impl std::fmt::Display) -> CallToolResult {
        CallToolResult::error(vec![Content::text(msg.to_string())])
    }

    /// Strip the leading "<basename>.org/" prefix from a refile target name and
    /// return the heading path with components joined by " / ".
    fn refile_heading_path(name: &str) -> String {
        // name is e.g. "flexpay.org/Inbox" or "==a01@@…foo.org/Outline/Sub"
        // Strip up to and including the first '/'.
        let path_part = match name.find('/') {
            Some(idx) => &name[idx + 1..],
            None => name,
        };
        // Replace internal '/' separators with " / " for readability.
        path_part.replace('/', " / ")
    }

    /// Parse "file:pos" location_id into (file_path, pos).
    fn parse_location_id(id: &str) -> Option<(String, u64)> {
        // id format: "<file>:<pos>" where file may contain colons (absolute path on macOS/Linux).
        // The pos is the last colon-separated segment that parses as u64.
        let last_colon = id.rfind(':')?;
        let pos: u64 = id[last_colon + 1..].parse().ok()?;
        let file = id[..last_colon].to_string();
        Some((file, pos))
    }

    /// Build a refile target id string from file + pos (mirrors parse_location_id).
    fn location_id(file: &str, pos: u64) -> String {
        format!("{file}:{pos}")
    }

    /// Default TODO keyword: first active keyword from config, fallback "TODO".
    fn default_todo_state(&self) -> String {
        self.state
            .cached_config
            .read()
            .keywords
            .as_ref()
            .and_then(|kw| kw.sequences.first())
            .and_then(|seq| seq.active.first())
            .cloned()
            .unwrap_or_else(|| "TODO".to_string())
    }

    /// Fetch all refile targets from the bridge.
    async fn fetch_refile_targets(&self) -> Result<Vec<RefileTarget>, String> {
        self.state
            .bridge
            .call::<Vec<RefileTarget>>("read.refile-targets", serde_json::json!({}))
            .await
            .map_err(|e| format!("bridge error fetching refile targets: {e}"))
    }

    /// Build the org heading text plus any planning/body lines.
    #[allow(clippy::too_many_arguments)]
    fn build_entry_text(
        stars: usize,
        state: &str,
        priority: Option<&str>,
        title: &str,
        tags: Option<&[String]>,
        scheduled: Option<&str>,
        deadline: Option<&str>,
        body: Option<&str>,
    ) -> String {
        let mut lines = Vec::new();

        // Heading line: "** TODO [#A] Title :tag1:tag2:"
        let mut heading = "*".repeat(stars);
        if !state.is_empty() {
            heading.push(' ');
            heading.push_str(state);
        }
        if let Some(p) = priority {
            let p = p.to_ascii_uppercase();
            heading.push_str(&format!(" [#{p}]"));
        }
        heading.push(' ');
        heading.push_str(title);
        if let Some(tags) = tags {
            if !tags.is_empty() {
                let tag_str = tags.join(":");
                heading.push_str(&format!(" :{tag_str}:"));
            }
        }
        lines.push(heading);

        // Planning line (immediately under heading, no blank line).
        let mut planning_parts = Vec::new();
        if let Some(s) = scheduled {
            planning_parts.push(format!("SCHEDULED: <{s}>"));
        }
        if let Some(d) = deadline {
            planning_parts.push(format!("DEADLINE: <{d}>"));
        }
        if !planning_parts.is_empty() {
            lines.push(planning_parts.join(" "));
        }

        // Body (blank line separator).
        if let Some(b) = body {
            if !b.is_empty() {
                lines.push(String::new());
                lines.push(b.to_string());
            }
        }

        lines.join("\n")
    }
}

// ----------------------------------------------------------------------------
// Tool implementations
// ----------------------------------------------------------------------------

#[tool_router]
impl EavMcpServer {
    #[tool(
        description = "List org-agenda tasks. scope: \"active\" (default) or \"all\". Optionally filter by tag, date (YYYY-MM-DD), or project (case-insensitive substring of the file path)."
    )]
    async fn list_tasks(&self, Parameters(args): Parameters<ListTasksArgs>) -> CallToolResult {
        let scope = args.scope.as_deref().unwrap_or("active");
        let mut tasks = if let Some(tag) = &args.tag {
            self.state.index.tasks_by_tag(tag)
        } else if let Some(date) = &args.date {
            self.state.index.tasks_by_date(date)
        } else if scope == "all" {
            self.state.index.all_tasks()
        } else {
            self.state.index.active_tasks()
        };
        if let Some(proj) = &args.project {
            let proj_lower = proj.to_ascii_lowercase();
            tasks.retain(|t| t.file.to_ascii_lowercase().contains(&proj_lower));
        }
        Self::ok_json(&tasks)
    }

    #[tool(description = "Case-insensitive title substring search across all tasks.")]
    async fn search_tasks(&self, Parameters(args): Parameters<SearchTasksArgs>) -> CallToolResult {
        let q = args.query.to_ascii_lowercase();
        let matches: Vec<_> = self
            .state
            .index
            .all_tasks()
            .into_iter()
            .filter(|t| t.title.to_ascii_lowercase().contains(&q))
            .collect();
        Self::ok_json(&matches)
    }

    #[tool(description = "Fetch a single task by id, including its notes from Emacs.")]
    async fn get_task(&self, Parameters(args): Parameters<GetTaskArgs>) -> CallToolResult {
        let Some(task) = self.state.index.task_by_id(&args.id) else {
            return Self::err_text(format!("task {} not found", args.id));
        };
        let notes: Option<serde_json::Value> = self
            .state
            .bridge
            .call(
                "read.notes",
                serde_json::json!({ "file": task.file, "pos": task.pos }),
            )
            .await
            .ok();
        let mut val = serde_json::to_value(&task).unwrap_or(serde_json::Value::Null);
        if let (Some(n), Some(obj)) = (notes, val.as_object_mut()) {
            obj.insert("notesDetail".to_string(), n);
        }
        CallToolResult::structured(val)
    }

    #[tool(description = "Get the org-agenda for a single day (YYYY-MM-DD).")]
    async fn get_agenda(&self, Parameters(args): Parameters<GetAgendaArgs>) -> CallToolResult {
        let target = match chrono::NaiveDate::parse_from_str(&args.date, "%Y-%m-%d") {
            Ok(d) => d,
            Err(_) => return Self::err_text("invalid date; expected YYYY-MM-DD"),
        };
        let today = chrono::Local::now().date_naive();
        let tasks = self.state.index.all_agenda_entries();
        let evaluation = evaluate_day(&tasks, target, today, &self.state.agenda_config);
        Self::ok_json(&evaluation.entries)
    }

    #[tool(
        description = "Get org-agenda entries for a date range [start, end] inclusive (YYYY-MM-DD)."
    )]
    async fn get_agenda_range(
        &self,
        Parameters(args): Parameters<GetAgendaRangeArgs>,
    ) -> CallToolResult {
        let s = match chrono::NaiveDate::parse_from_str(&args.start, "%Y-%m-%d") {
            Ok(d) => d,
            Err(_) => return Self::err_text("invalid start date; expected YYYY-MM-DD"),
        };
        let e = match chrono::NaiveDate::parse_from_str(&args.end, "%Y-%m-%d") {
            Ok(d) => d,
            Err(_) => return Self::err_text("invalid end date; expected YYYY-MM-DD"),
        };
        let today = chrono::Local::now().date_naive();
        let tasks = self.state.index.all_agenda_entries();
        let evaluation = evaluate_range(&tasks, s, e, today, &self.state.agenda_config);
        Self::ok_json(&evaluation.entries)
    }

    #[tool(description = "List available org capture templates.")]
    async fn list_capture_templates(&self) -> CallToolResult {
        match self
            .state
            .bridge
            .call::<serde_json::Value>("read.capture-templates", serde_json::json!({}))
            .await
        {
            Ok(v) => CallToolResult::structured(v),
            Err(e) => Self::err_text(format!("bridge error: {e}")),
        }
    }

    #[tool(description = "Create a new org task via a capture template.")]
    async fn create_task(&self, Parameters(args): Parameters<CreateTaskArgs>) -> CallToolResult {
        let body = serde_json::json!({ "template": args.template, "content": args.content });
        match self
            .state
            .bridge
            .call::<serde_json::Value>("write.capture", body.clone())
            .await
        {
            Ok(_) => {
                self.state.reindex_after_write(&body);
                CallToolResult::structured(serde_json::json!({ "success": true }))
            }
            Err(e) => Self::err_text(format!("bridge error: {e}")),
        }
    }

    #[tool(description = "Set the TODO state of a task (e.g. DONE, TODO, IN-PROGRESS).")]
    async fn set_task_state(
        &self,
        Parameters(args): Parameters<SetTaskStateArgs>,
    ) -> CallToolResult {
        let Some((file, pos)) = self.task_file_pos(&args.id) else {
            return Self::err_text(format!("task {} not found", args.id));
        };
        let body =
            serde_json::json!({ "file": file, "pos": pos, "state": args.state, "id": args.id });
        match self
            .state
            .bridge
            .call::<serde_json::Value>("write.set-state", body.clone())
            .await
        {
            Ok(resp) => {
                let success = resp
                    .get("success")
                    .and_then(|v| v.as_bool())
                    .unwrap_or(true);
                if success {
                    self.state.reindex_after_write(&body);
                    CallToolResult::structured(resp)
                } else {
                    let msg = resp
                        .get("error")
                        .and_then(|v| v.as_str())
                        .unwrap_or("state change refused")
                        .to_string();
                    Self::err_text(msg)
                }
            }
            Err(e) => Self::err_text(format!("bridge error: {e}")),
        }
    }

    #[tool(
        description = "Set or clear the SCHEDULED timestamp of a task. Pass empty string or omit timestamp to clear."
    )]
    async fn set_task_scheduled(
        &self,
        Parameters(args): Parameters<SetTaskScheduledArgs>,
    ) -> CallToolResult {
        let Some((file, pos)) = self.task_file_pos(&args.id) else {
            return Self::err_text(format!("task {} not found", args.id));
        };
        let ts = args.timestamp.as_deref().unwrap_or("");
        let body = serde_json::json!({ "file": file, "pos": pos, "scheduled": ts });
        match self
            .state
            .bridge
            .call::<serde_json::Value>("write.set-scheduled", body.clone())
            .await
        {
            Ok(_) => {
                self.state.reindex_after_write(&body);
                CallToolResult::structured(serde_json::json!({ "success": true }))
            }
            Err(e) => Self::err_text(format!("bridge error: {e}")),
        }
    }

    #[tool(
        description = "Set or clear the DEADLINE timestamp of a task. Pass empty string or omit timestamp to clear."
    )]
    async fn set_task_deadline(
        &self,
        Parameters(args): Parameters<SetTaskDeadlineArgs>,
    ) -> CallToolResult {
        let Some((file, pos)) = self.task_file_pos(&args.id) else {
            return Self::err_text(format!("task {} not found", args.id));
        };
        let ts = args.timestamp.as_deref().unwrap_or("");
        let body = serde_json::json!({ "file": file, "pos": pos, "deadline": ts });
        match self
            .state
            .bridge
            .call::<serde_json::Value>("write.set-deadline", body.clone())
            .await
        {
            Ok(_) => {
                self.state.reindex_after_write(&body);
                CallToolResult::structured(serde_json::json!({ "success": true }))
            }
            Err(e) => Self::err_text(format!("bridge error: {e}")),
        }
    }

    #[tool(
        description = "Set or clear the priority of a task (\"A\", \"B\", \"C\", or omit to clear)."
    )]
    async fn set_task_priority(
        &self,
        Parameters(args): Parameters<SetTaskPriorityArgs>,
    ) -> CallToolResult {
        let Some((file, pos)) = self.task_file_pos(&args.id) else {
            return Self::err_text(format!("task {} not found", args.id));
        };
        let priority = args.priority.as_deref().unwrap_or("");
        let body = serde_json::json!({ "file": file, "pos": pos, "priority": priority });
        match self
            .state
            .bridge
            .call::<serde_json::Value>("write.set-priority", body.clone())
            .await
        {
            Ok(_) => {
                self.state.reindex_after_write(&body);
                CallToolResult::structured(serde_json::json!({ "success": true }))
            }
            Err(e) => Self::err_text(format!("bridge error: {e}")),
        }
    }

    #[tool(description = "Replace the tag list of a task with the provided tags.")]
    async fn set_task_tags(&self, Parameters(args): Parameters<SetTaskTagsArgs>) -> CallToolResult {
        let Some((file, pos)) = self.task_file_pos(&args.id) else {
            return Self::err_text(format!("task {} not found", args.id));
        };
        let body = serde_json::json!({ "file": file, "pos": pos, "tags": args.tags });
        match self
            .state
            .bridge
            .call::<serde_json::Value>("write.set-tags", body.clone())
            .await
        {
            Ok(_) => {
                self.state.reindex_after_write(&body);
                CallToolResult::structured(serde_json::json!({ "success": true }))
            }
            Err(e) => Self::err_text(format!("bridge error: {e}")),
        }
    }

    #[tool(description = "Replace the notes (drawer body) of a task.")]
    async fn set_task_notes(
        &self,
        Parameters(args): Parameters<SetTaskNotesArgs>,
    ) -> CallToolResult {
        let Some((file, pos)) = self.task_file_pos(&args.id) else {
            return Self::err_text(format!("task {} not found", args.id));
        };
        let body = serde_json::json!({ "file": file, "pos": pos, "notes": args.notes });
        match self
            .state
            .bridge
            .call::<serde_json::Value>("write.set-notes", body.clone())
            .await
        {
            Ok(_) => {
                self.state.reindex_after_write(&body);
                CallToolResult::structured(serde_json::json!({ "success": true }))
            }
            Err(e) => Self::err_text(format!("bridge error: {e}")),
        }
    }

    // ------------------------------------------------------------------------
    // Project / location / add_task tools
    // ------------------------------------------------------------------------

    #[tool(
        description = "List all agenda files (projects) the agent can target. Returns [{name, category, path}]. \
        Per-paper project files live under paths matching '…/project notes/…__….org'."
    )]
    async fn list_projects(&self) -> CallToolResult {
        let files = self.state.cached_config.read().files.clone();
        Self::ok_json(&files)
    }

    #[tool(
        description = "List headings the agent can insert tasks under. Returns [{id, file, heading_path}] \
        where id is 'file:pos' for use with add_task's location_id. \
        Optionally filter by project (substring of file path) and/or query (substring of heading_path). \
        Capped at 200 results; truncated field in response when hit."
    )]
    async fn list_locations(
        &self,
        Parameters(args): Parameters<ListLocationsArgs>,
    ) -> CallToolResult {
        let targets = match self.fetch_refile_targets().await {
            Ok(t) => t,
            Err(e) => return Self::err_text(e),
        };

        const CAP: usize = 200;
        let proj_lower = args.project.as_deref().map(str::to_ascii_lowercase);
        let query_lower = args.query.as_deref().map(str::to_ascii_lowercase);

        let mut results = Vec::new();
        let mut truncated = false;

        for t in &targets {
            let heading_path = Self::refile_heading_path(&t.name);

            if let Some(ref p) = proj_lower {
                let file_lower = t.file.to_ascii_lowercase();
                let basename_lower = Path::new(&t.file)
                    .file_name()
                    .and_then(|s| s.to_str())
                    .unwrap_or("")
                    .to_ascii_lowercase();
                if !file_lower.contains(p.as_str()) && !basename_lower.contains(p.as_str()) {
                    continue;
                }
            }

            if let Some(ref q) = query_lower {
                if !heading_path.to_ascii_lowercase().contains(q.as_str()) {
                    continue;
                }
            }

            if results.len() >= CAP {
                truncated = true;
                break;
            }

            results.push(serde_json::json!({
                "id": Self::location_id(&t.file, t.pos),
                "file": t.file,
                "heading_path": heading_path,
            }));
        }

        Self::ok_json(&serde_json::json!({
            "locations": results,
            "truncated": truncated,
        }))
    }

    #[tool(description = "Insert a new task into a project file. \
        Exactly one of project / location_id / parent_task_id must be supplied to determine where to insert. \
        - project: resolves to the project's Inbox heading (error if ambiguous or Inbox not found). \
        - location_id: insert under the exact heading returned by list_locations. \
        - parent_task_id: insert as a direct sub-task of an existing task. \
        Returns {success, file, heading_path, child_level, title} and, if unambiguously found after reindex, the new task's id.")]
    async fn add_task(&self, Parameters(args): Parameters<AddTaskArgs>) -> CallToolResult {
        // --- Resolve target (file, olp, child_level) ---
        let (file, olp, child_level): (String, Vec<String>, usize);

        if let Some(parent_id) = &args.parent_task_id {
            // parent_task_id path: sub-task under an existing task.
            let Some(parent) = self.state.index.task_by_id(parent_id) else {
                return Self::err_text(format!(
                    "parent task '{parent_id}' not found in index; \
                    use list_tasks to find a valid task id"
                ));
            };
            let parent_file = parent.file.clone();
            let parent_pos = parent.pos;
            let parent_level = parent.level as usize;

            // outline-path returns ANCESTORS ONLY (not the heading itself).
            // We must append the parent's own title to get the full olp for insert-entry.
            let outline_result = self
                .state
                .bridge
                .call::<eav_core::OutlinePath>(
                    "read.outline-path",
                    serde_json::json!({ "file": parent_file, "pos": parent_pos }),
                )
                .await;

            let ancestors = match outline_result {
                Ok(op) => op.headings,
                Err(e) => {
                    return Self::err_text(format!(
                        "bridge error fetching outline-path for task '{parent_id}': {e}"
                    ));
                }
            };

            // olp for insert-entry = ancestors + parent heading title (include self).
            let mut full_olp = ancestors;
            full_olp.push(parent.title.clone());

            file = parent_file;
            olp = full_olp;
            child_level = parent_level + 1;
        } else if let Some(loc_id) = &args.location_id {
            // location_id path: insert under specific heading from list_locations.
            let Some((loc_file, loc_pos)) = Self::parse_location_id(loc_id) else {
                return Self::err_text(format!(
                    "invalid location_id '{loc_id}'; expected 'file:pos' from list_locations"
                ));
            };

            let targets = match self.fetch_refile_targets().await {
                Ok(t) => t,
                Err(e) => return Self::err_text(e),
            };

            let matched = targets
                .into_iter()
                .find(|t| t.file == loc_file && t.pos == loc_pos);

            let Some(target) = matched else {
                return Self::err_text(format!(
                    "location_id '{loc_id}' not found in current refile targets; \
                    call list_locations to get fresh ids"
                ));
            };

            // Parse the name into olp components (strip basename prefix, split on '/').
            let heading_path = Self::refile_heading_path(&target.name);
            let olp_parts: Vec<String> = heading_path.split(" / ").map(|s| s.to_string()).collect();

            file = target.file;
            olp = olp_parts.clone();
            child_level = olp_parts.len() + 1;
        } else if let Some(proj) = &args.project {
            // project path: resolve to Inbox heading.
            let proj_lower = proj.to_ascii_lowercase();
            let files = self.state.cached_config.read().files.clone();

            let matches: Vec<_> = files
                .iter()
                .filter(|f| {
                    f.path.to_ascii_lowercase().contains(&proj_lower)
                        || f.name.to_ascii_lowercase().contains(&proj_lower)
                })
                .collect();

            if matches.is_empty() {
                return Self::err_text(format!(
                    "no project file matches '{proj}'; call list_projects to see available files"
                ));
            }
            if matches.len() > 1 {
                let candidates: Vec<&str> = matches.iter().map(|f| f.path.as_str()).collect();
                return Self::err_text(format!(
                    "ambiguous project '{proj}' — {} files match: {}. \
                    Use a more specific substring or supply location_id instead.",
                    candidates.len(),
                    candidates.join(", ")
                ));
            }

            let proj_file = matches[0].path.clone();
            let proj_basename = Path::new(&proj_file)
                .file_name()
                .and_then(|s| s.to_str())
                .unwrap_or("")
                .to_ascii_lowercase();

            let targets = match self.fetch_refile_targets().await {
                Ok(t) => t,
                Err(e) => return Self::err_text(e),
            };

            // Find a top-level "Inbox" heading in this project file.
            let inbox = targets.into_iter().find(|t| {
                let t_lower = t.file.to_ascii_lowercase();
                let t_basename = Path::new(&t.file)
                    .file_name()
                    .and_then(|s| s.to_str())
                    .unwrap_or("")
                    .to_ascii_lowercase();
                (t_lower == proj_file.to_ascii_lowercase() || t_basename == proj_basename)
                    && Self::refile_heading_path(&t.name) == "Inbox"
            });

            let Some(_inbox_target) = inbox else {
                return Self::err_text(format!(
                    "project '{proj}' ({proj_file}) has no top-level 'Inbox' heading. \
                    Supply an explicit location_id from list_locations instead."
                ));
            };

            file = proj_file;
            olp = vec!["Inbox".to_string()];
            child_level = 2;
        } else {
            return Self::err_text(
                "supply at least one of: project, location_id, or parent_task_id".to_string(),
            );
        }

        // --- Resolve TODO state ---
        let state_str = args
            .todo_state
            .clone()
            .unwrap_or_else(|| self.default_todo_state());

        // --- Build entryText ---
        let entry_text = Self::build_entry_text(
            child_level,
            &state_str,
            args.priority.as_deref(),
            &args.title,
            args.tags.as_deref(),
            args.scheduled.as_deref(),
            args.deadline.as_deref(),
            args.body.as_deref(),
        );

        let prepend = args.prepend.unwrap_or(false);
        let heading_path = olp.join(" / ");

        // --- Call insert-entry ---
        let insert_body = serde_json::json!({
            "file": file,
            "targetType": "file+olp",
            "olp": olp,
            "entryText": entry_text,
            "prepend": prepend,
        });

        match self
            .state
            .bridge
            .call::<serde_json::Value>("write.insert-entry", insert_body.clone())
            .await
        {
            Ok(_) => {
                self.state
                    .reindex_after_write(&serde_json::json!({ "file": file }));

                // Best-effort id resolution: scan file for a task with matching title.
                let title = args.title.clone();
                let maybe_id = {
                    let in_file = self.state.index.tasks_in_file(Path::new(&file));
                    let mut matching: Vec<_> =
                        in_file.into_iter().filter(|t| t.title == title).collect();
                    if matching.len() == 1 {
                        Some(matching.remove(0).id)
                    } else {
                        None
                    }
                };

                let mut result = serde_json::json!({
                    "success": true,
                    "file": file,
                    "heading_path": heading_path,
                    "child_level": child_level,
                    "title": title,
                });
                if let Some(id) = maybe_id {
                    result["id"] = serde_json::Value::String(id);
                } else {
                    result["id_note"] = serde_json::Value::String(
                        "id not resolved (0 or >1 tasks with this title in file); \
                        use search_tasks or list_tasks with project filter to find it"
                            .to_string(),
                    );
                }
                CallToolResult::structured(result)
            }
            Err(e) => Self::err_text(format!("bridge error on insert-entry: {e}")),
        }
    }
}

#[tool_handler(router = self.tool_router)]
impl ServerHandler for EavMcpServer {
    fn get_info(&self) -> ServerInfo {
        ServerInfo::new(ServerCapabilities::builder().enable_tools().build())
            .with_server_info(Implementation::new("eav-mcp", env!("CARGO_PKG_VERSION")))
    }
}

// ----------------------------------------------------------------------------
// Entry point
// ----------------------------------------------------------------------------

/// Serve the MCP endpoint on `bind`. Resolves when `shutdown` fires.
///
/// Builds a fresh axum 0.8 router (separate from eav-server's axum 0.7 router)
/// and mounts the MCP service at `/mcp`. The two HTTP listeners never share a
/// Router, which sidesteps the axum 0.7/0.8 router-type incompatibility.
pub async fn serve(
    state: AppState,
    bind: SocketAddr,
    shutdown: oneshot::Receiver<()>,
) -> anyhow::Result<()> {
    let session_manager = Arc::new(LocalSessionManager::default());

    // When the operator binds to a non-loopback address they have explicitly
    // opted into remote exposure (same trust model as eavd's HTTP API, which
    // binds 0.0.0.0 with no auth). In that case clear allowed_hosts so any
    // Host header is accepted — necessary for Tailscale/LAN IP access.
    // For loopback binds we keep the protective default (localhost/127.0.0.1/::1
    // only) to prevent DNS-rebinding attacks against locally running servers.
    let is_loopback = match bind.ip() {
        IpAddr::V4(ip) => ip.is_loopback(),
        IpAddr::V6(ip) => ip.is_loopback(),
    };
    let mcp_config = if is_loopback {
        StreamableHttpServerConfig::default()
    } else {
        StreamableHttpServerConfig::default().disable_allowed_hosts()
    };

    let mcp_service = StreamableHttpService::new(
        move || Ok(EavMcpServer::new(state.clone())),
        session_manager,
        mcp_config,
    );

    // axum 0.8 in this crate (not eav-server's axum 0.7)
    let router = axum::Router::new().route("/mcp", any_service(mcp_service));

    tracing::info!(?bind, "eavd MCP listening");
    let listener = tokio::net::TcpListener::bind(bind)
        .await
        .with_context(|| format!("MCP listener bind failed on {bind}"))?;

    axum::serve(listener, router)
        .with_graceful_shutdown(async move {
            let _ = shutdown.await;
            tracing::info!("MCP graceful shutdown requested");
        })
        .await
        .context("MCP server error")?;

    Ok(())
}
