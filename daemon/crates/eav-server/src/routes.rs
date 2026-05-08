//! HTTP route table.
//!
//! All paths are 1:1 with the existing Express server in
//! `server/index.ts:48-453`. Reads come from the in-memory index where
//! possible; otherwise we proxy through the bridge.

use crate::AppState;
use axum::extract::{Path as PathParam, Query, State};
use axum::http::StatusCode;
use axum::response::sse::{Event as SseEvent, KeepAlive, Sse};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, patch, post};
use axum::{Json, Router};
use eav_agenda::{evaluate_day, evaluate_range};
use eav_core::{
    AgendaEntry, AgendaFile, ClockStatus, HeadingNotes, OrgConfig, OrgListConfig,
    OrgPriorities, OrgTask, OutlinePath, RefileTarget, TodoKeywords,
};
use futures::stream::Stream;
use serde::Deserialize;
use std::convert::Infallible;
use tokio_stream::wrappers::BroadcastStream;
use tokio_stream::StreamExt;
use tower_http::cors::CorsLayer;

pub fn router(state: AppState) -> Router {
    Router::new()
        .route("/api/tasks", get(get_tasks))
        .route("/api/files", get(get_files))
        .route("/api/keywords", get(get_keywords))
        .route("/api/priorities", get(get_priorities))
        .route("/api/config", get(get_config))
        .route("/api/list-config", get(get_list_config))
        .route("/api/notes", get(get_notes).put(put_notes))
        .route("/api/outline", get(get_outline))
        .route("/api/clock", get(get_clock_status))
        .route("/api/clock/in", post(post_clock_in))
        .route("/api/clock/out", post(post_clock_out))
        .route("/api/clock/log", post(post_clock_log))
        .route("/api/clock/tidy", post(post_clock_tidy))
        .route("/api/agenda/day/:date", get(get_agenda_day))
        .route("/api/agenda/range", get(get_agenda_range))
        .route("/api/refile/targets", get(get_refile_targets))
        .route("/api/refile", post(post_refile))
        .route("/api/tasks/:id/title", patch(patch_title))
        .route("/api/tasks/:id/state", patch(patch_state))
        .route("/api/tasks/:id/priority", patch(patch_priority))
        .route("/api/tasks/:id/tags", patch(patch_tags))
        .route("/api/tasks/:id/scheduled", patch(patch_scheduled))
        .route("/api/tasks/:id/deadline", patch(patch_deadline))
        .route("/api/tasks/:id/property", patch(patch_property))
        .route("/api/tasks/:id/refile", post(post_refile_task))
        .route("/api/capture/templates", get(get_capture_templates))
        .route("/api/capture", post(post_capture))
        .route("/api/insert-entry", post(post_insert_entry))
        .route("/api/debug", get(get_debug))
        .route("/api/events", get(get_events))
        .layer(CorsLayer::permissive())
        .with_state(state)
}

// ----------------------------------------------------------------------------
// Error handling
// ----------------------------------------------------------------------------

struct ApiError {
    status: StatusCode,
    body: serde_json::Value,
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        (self.status, Json(self.body)).into_response()
    }
}

impl<E: std::fmt::Display> From<E> for ApiError {
    fn from(err: E) -> Self {
        Self {
            status: StatusCode::INTERNAL_SERVER_ERROR,
            body: serde_json::json!({ "error": err.to_string() }),
        }
    }
}

fn bad_request(msg: &str) -> ApiError {
    ApiError {
        status: StatusCode::BAD_REQUEST,
        body: serde_json::json!({ "error": msg }),
    }
}

// ----------------------------------------------------------------------------
// Reads served from the index
// ----------------------------------------------------------------------------

#[derive(Deserialize)]
struct TasksQuery {
    #[serde(default)]
    all: Option<String>,
}

async fn get_tasks(
    State(state): State<AppState>,
    Query(q): Query<TasksQuery>,
) -> Result<Json<Vec<OrgTask>>, ApiError> {
    let show_all = q.all.as_deref() == Some("true");
    let tasks = if show_all {
        state.index.all_tasks()
    } else {
        state.index.active_tasks()
    };
    Ok(Json(tasks))
}

#[derive(Deserialize)]
struct FilePosQuery {
    file: Option<String>,
    pos: Option<String>,
}

async fn get_notes(
    State(state): State<AppState>,
    Query(q): Query<FilePosQuery>,
) -> Result<Json<HeadingNotes>, ApiError> {
    let file = q.file.ok_or_else(|| bad_request("file required"))?;
    let pos: u64 = q
        .pos
        .as_deref()
        .ok_or_else(|| bad_request("pos required"))?
        .parse()
        .map_err(|_| bad_request("pos must be integer"))?;
    let notes: HeadingNotes = state
        .bridge
        .call(
            "read.notes",
            serde_json::json!({ "file": file, "pos": pos }),
        )
        .await?;
    Ok(Json(notes))
}

async fn get_outline(
    State(state): State<AppState>,
    Query(q): Query<FilePosQuery>,
) -> Result<Json<OutlinePath>, ApiError> {
    let file = q.file.ok_or_else(|| bad_request("file required"))?;
    let pos: u64 = q
        .pos
        .as_deref()
        .ok_or_else(|| bad_request("pos required"))?
        .parse()
        .map_err(|_| bad_request("pos must be integer"))?;
    let outline: OutlinePath = state
        .bridge
        .call(
            "read.outline-path",
            serde_json::json!({ "file": file, "pos": pos }),
        )
        .await?;
    Ok(Json(outline))
}

// ----------------------------------------------------------------------------
// Bridge-cache reads
// ----------------------------------------------------------------------------

async fn get_files(State(state): State<AppState>) -> Result<Json<Vec<AgendaFile>>, ApiError> {
    let cached = state.cached_config.read().files.clone();
    if !cached.is_empty() {
        return Ok(Json(cached));
    }
    let v: Vec<AgendaFile> = state.bridge.call("read.config", serde_json::json!({}))
        .await
        .map(|r: serde_json::Value| {
            serde_json::from_value(r["files"].clone()).unwrap_or_default()
        })?;
    state.cached_config.write().files = v.clone();
    Ok(Json(v))
}

async fn get_keywords(
    State(state): State<AppState>,
) -> Result<Json<TodoKeywords>, ApiError> {
    if let Some(k) = state.cached_config.read().keywords.clone() {
        return Ok(Json(k));
    }
    let r: serde_json::Value = state
        .bridge
        .call("read.config", serde_json::json!({}))
        .await?;
    let k: TodoKeywords = serde_json::from_value(r["keywords"].clone())?;
    state.cached_config.write().keywords = Some(k.clone());
    Ok(Json(k))
}

async fn get_priorities(
    State(state): State<AppState>,
) -> Result<Json<OrgPriorities>, ApiError> {
    if let Some(p) = state.cached_config.read().priorities.clone() {
        return Ok(Json(p));
    }
    let r: serde_json::Value = state
        .bridge
        .call("read.config", serde_json::json!({}))
        .await?;
    let p: OrgPriorities = serde_json::from_value(r["priorities"].clone())?;
    state.cached_config.write().priorities = Some(p.clone());
    Ok(Json(p))
}

async fn get_config(
    State(state): State<AppState>,
) -> Result<Json<OrgConfig>, ApiError> {
    if let Some(c) = state.cached_config.read().config {
        return Ok(Json(c));
    }
    let r: serde_json::Value = state
        .bridge
        .call("read.config", serde_json::json!({}))
        .await?;
    let c: OrgConfig = serde_json::from_value(r["config"].clone())?;
    state.cached_config.write().config = Some(c);
    Ok(Json(c))
}

async fn get_list_config(
    State(state): State<AppState>,
) -> Result<Json<OrgListConfig>, ApiError> {
    if let Some(c) = state.cached_config.read().list_config {
        return Ok(Json(c));
    }
    let r: serde_json::Value = state
        .bridge
        .call("read.config", serde_json::json!({}))
        .await?;
    let c: OrgListConfig = serde_json::from_value(r["listConfig"].clone())?;
    state.cached_config.write().list_config = Some(c);
    Ok(Json(c))
}

async fn get_clock_status(
    State(state): State<AppState>,
) -> Result<Json<ClockStatus>, ApiError> {
    let c: ClockStatus = state
        .bridge
        .call("read.clock-status", serde_json::json!({}))
        .await?;
    Ok(Json(c))
}

async fn get_capture_templates(
    State(state): State<AppState>,
) -> Result<Json<Vec<eav_core::CaptureTemplate>>, ApiError> {
    let v: Vec<eav_core::CaptureTemplate> = state
        .bridge
        .call("read.capture-templates", serde_json::json!({}))
        .await?;
    Ok(Json(v))
}

async fn get_refile_targets(
    State(state): State<AppState>,
) -> Result<Json<Vec<RefileTarget>>, ApiError> {
    let v: Vec<RefileTarget> = state
        .bridge
        .call("read.refile-targets", serde_json::json!({}))
        .await?;
    Ok(Json(v))
}

// ----------------------------------------------------------------------------
// Agenda
// ----------------------------------------------------------------------------

#[derive(Deserialize)]
struct RangeQuery {
    start: Option<String>,
    end: Option<String>,
}

async fn get_agenda_day(
    State(state): State<AppState>,
    PathParam(date): PathParam<String>,
) -> Result<Json<Vec<AgendaEntry>>, ApiError> {
    let target = chrono::NaiveDate::parse_from_str(&date, "%Y-%m-%d")
        .map_err(|_| bad_request("invalid date; expected YYYY-MM-DD"))?;
    let today = chrono::Local::now().date_naive();
    let tasks = state.index.all_agenda_entries();
    let mut evaluation = evaluate_day(&tasks, target, today, &state.agenda_config);
    if !evaluation.needs_sexp_proxy.is_empty() {
        if let Ok(sexp) = state
            .bridge
            .call::<Vec<AgendaEntry>>(
                "read.sexp-entries",
                serde_json::json!({ "date": date }),
            )
            .await
        {
            evaluation.entries.extend(sexp);
        }
    }
    Ok(Json(evaluation.entries))
}

async fn get_agenda_range(
    State(state): State<AppState>,
    Query(q): Query<RangeQuery>,
) -> Result<Json<Vec<AgendaEntry>>, ApiError> {
    let start = q.start.ok_or_else(|| bad_request("start required"))?;
    let end = q.end.ok_or_else(|| bad_request("end required"))?;
    let s = chrono::NaiveDate::parse_from_str(&start, "%Y-%m-%d")
        .map_err(|_| bad_request("invalid start"))?;
    let e = chrono::NaiveDate::parse_from_str(&end, "%Y-%m-%d")
        .map_err(|_| bad_request("invalid end"))?;
    let today = chrono::Local::now().date_naive();
    let tasks = state.index.all_agenda_entries();
    let evaluation = evaluate_range(&tasks, s, e, today, &state.agenda_config);
    Ok(Json(evaluation.entries))
}

// ----------------------------------------------------------------------------
// Mutations (proxied through the bridge)
// ----------------------------------------------------------------------------

async fn put_notes(
    State(state): State<AppState>,
    Json(body): Json<serde_json::Value>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let _: serde_json::Value = state
        .bridge
        .call("write.set-notes", body)
        .await?;
    Ok(Json(serde_json::json!({ "success": true })))
}

async fn post_clock_in(
    State(state): State<AppState>,
    Json(body): Json<serde_json::Value>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let _: serde_json::Value = state.bridge.call("write.clock-in", body).await?;
    Ok(Json(serde_json::json!({ "success": true })))
}

async fn post_clock_out(
    State(state): State<AppState>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let _: serde_json::Value = state
        .bridge
        .call("write.clock-out", serde_json::json!({}))
        .await?;
    Ok(Json(serde_json::json!({ "success": true })))
}

async fn post_clock_log(
    State(state): State<AppState>,
    Json(body): Json<serde_json::Value>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let _: serde_json::Value = state.bridge.call("write.clock-log", body).await?;
    Ok(Json(serde_json::json!({ "success": true })))
}

async fn post_clock_tidy(
    State(state): State<AppState>,
    Json(body): Json<serde_json::Value>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let r: serde_json::Value = state.bridge.call("write.clock-tidy", body).await?;
    Ok(Json(r))
}

async fn post_refile(
    State(state): State<AppState>,
    Json(body): Json<serde_json::Value>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let _: serde_json::Value = state.bridge.call("write.refile", body).await?;
    Ok(Json(serde_json::json!({ "success": true })))
}

async fn post_refile_task(
    State(state): State<AppState>,
    PathParam(_id): PathParam<String>,
    Json(body): Json<serde_json::Value>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let _: serde_json::Value = state.bridge.call("write.refile", body).await?;
    Ok(Json(serde_json::json!({ "success": true })))
}

async fn patch_title(
    State(state): State<AppState>,
    PathParam(_id): PathParam<String>,
    Json(body): Json<serde_json::Value>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let _: serde_json::Value = state.bridge.call("write.set-title", body).await?;
    Ok(Json(serde_json::json!({ "success": true })))
}

async fn patch_state(
    State(state): State<AppState>,
    PathParam(_id): PathParam<String>,
    Json(body): Json<serde_json::Value>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let _: serde_json::Value = state.bridge.call("write.set-state", body).await?;
    Ok(Json(serde_json::json!({ "success": true })))
}

async fn patch_priority(
    State(state): State<AppState>,
    PathParam(_id): PathParam<String>,
    Json(body): Json<serde_json::Value>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let _: serde_json::Value = state.bridge.call("write.set-priority", body).await?;
    Ok(Json(serde_json::json!({ "success": true })))
}

async fn patch_tags(
    State(state): State<AppState>,
    PathParam(_id): PathParam<String>,
    Json(body): Json<serde_json::Value>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let _: serde_json::Value = state.bridge.call("write.set-tags", body).await?;
    Ok(Json(serde_json::json!({ "success": true })))
}

async fn patch_scheduled(
    State(state): State<AppState>,
    PathParam(_id): PathParam<String>,
    Json(body): Json<serde_json::Value>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let _: serde_json::Value = state.bridge.call("write.set-scheduled", body).await?;
    Ok(Json(serde_json::json!({ "success": true })))
}

async fn patch_deadline(
    State(state): State<AppState>,
    PathParam(_id): PathParam<String>,
    Json(body): Json<serde_json::Value>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let _: serde_json::Value = state.bridge.call("write.set-deadline", body).await?;
    Ok(Json(serde_json::json!({ "success": true })))
}

async fn patch_property(
    State(state): State<AppState>,
    PathParam(_id): PathParam<String>,
    Json(body): Json<serde_json::Value>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let _: serde_json::Value = state.bridge.call("write.set-property", body).await?;
    Ok(Json(serde_json::json!({ "success": true })))
}

async fn post_capture(
    State(state): State<AppState>,
    Json(body): Json<serde_json::Value>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let _: serde_json::Value = state.bridge.call("write.capture", body).await?;
    Ok(Json(serde_json::json!({ "success": true })))
}

async fn post_insert_entry(
    State(state): State<AppState>,
    Json(body): Json<serde_json::Value>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let _: serde_json::Value = state.bridge.call("write.insert-entry", body).await?;
    Ok(Json(serde_json::json!({ "success": true })))
}

// ----------------------------------------------------------------------------
// Debug / SSE
// ----------------------------------------------------------------------------

async fn get_debug(State(state): State<AppState>) -> Result<Json<serde_json::Value>, ApiError> {
    let pid = std::process::id();
    let bridge_path = state.bridge.socket_path().to_string_lossy().into_owned();
    let task_count = state.index.task_count();
    Ok(Json(serde_json::json!({
        "pid": pid,
        "bridgeSocket": bridge_path,
        "taskCount": task_count,
        "platform": std::env::consts::OS,
        "arch": std::env::consts::ARCH,
        "rustVersion": option_env!("CARGO_PKG_RUST_VERSION").unwrap_or("unknown"),
    })))
}

async fn get_events(
    State(state): State<AppState>,
) -> Sse<impl Stream<Item = Result<SseEvent, Infallible>>> {
    let receiver = state.subscribe_events();
    let stream = BroadcastStream::new(receiver).filter_map(|res| match res {
        Ok(event) => {
            let name = event.event_name().to_string();
            let payload = serde_json::to_string(&event).unwrap_or_else(|_| "{}".to_string());
            Some(Ok(SseEvent::default().event(name).data(payload)))
        }
        Err(_lagged) => None,
    });
    Sse::new(stream).keep_alive(KeepAlive::default())
}

