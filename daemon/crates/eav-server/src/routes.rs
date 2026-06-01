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
use axum::routing::{delete, get, patch, post};
use axum::{Json, Router};
use eav_agenda::{evaluate_day, evaluate_range};
use eav_core::{
    AgendaEntry, AgendaFile, Clock, ClockStatus, Habit, HabitCadenceSpec, HeadingNotes, OrgConfig,
    OrgListConfig, OrgPriorities, OrgTask, OutlinePath, RefileTarget, TodoKeywords,
};
use eav_index::{advance_anchor, compute_due, ClockRow, HabitRow};
use futures::stream::Stream;
use serde::Deserialize;
use std::convert::Infallible;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};
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
        .route("/api/clock/active", get(get_active_clocks))
        .route("/api/clock/in", post(post_clock_in))
        .route("/api/clock/out", post(post_clock_out))
        .route("/api/clock/log", post(post_clock_log))
        .route("/api/clock/tidy", post(post_clock_tidy))
        .route("/api/clock/:id", delete(delete_clock))
        .route("/api/clocks", get(get_clocks_for_task))
        .route("/api/habits", get(get_habits).post(post_habit_create))
        .route("/api/habits/:id", patch(patch_habit).delete(delete_habit))
        .route("/api/habits/:id/complete", post(post_habit_complete))
        .route("/api/habits/:id/uncomplete", post(post_habit_uncomplete))
        .route("/api/habits/:id/skip", post(post_habit_skip))
        .route("/api/habits/:id/reschedule", post(post_habit_reschedule))
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
        .route("/api/tasks/:id/archive", post(post_archive_task))
        .route("/api/capture/templates", get(get_capture_templates))
        .route("/api/capture", post(post_capture))
        .route("/api/insert-entry", post(post_insert_entry))
        .route("/api/debug", get(get_debug))
        .route("/api/shutdown", post(post_shutdown))
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
    let v: Vec<AgendaFile> = state
        .bridge
        .call("read.config", serde_json::json!({}))
        .await
        .map(|r: serde_json::Value| {
            serde_json::from_value(r["files"].clone()).unwrap_or_default()
        })?;
    state.cached_config.write().files = v.clone();
    Ok(Json(v))
}

async fn get_keywords(State(state): State<AppState>) -> Result<Json<TodoKeywords>, ApiError> {
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

async fn get_priorities(State(state): State<AppState>) -> Result<Json<OrgPriorities>, ApiError> {
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

async fn get_config(State(state): State<AppState>) -> Result<Json<OrgConfig>, ApiError> {
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

async fn get_list_config(State(state): State<AppState>) -> Result<Json<OrgListConfig>, ApiError> {
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

async fn get_clock_status(State(state): State<AppState>) -> Result<Json<ClockStatus>, ApiError> {
    let c: ClockStatus = state
        .bridge
        .call("read.clock-status", serde_json::json!({}))
        .await?;
    Ok(Json(c))
}

// ----------------------------------------------------------------------------
// DB-backed clock routes
// ----------------------------------------------------------------------------

fn row_to_clock(r: ClockRow) -> Clock {
    Clock {
        id: r.id,
        task_id: r.task_id,
        file: r.file,
        title: r.title,
        start: r.start,
        end: r.end,
        note: r.note,
    }
}

fn now_epoch() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}

/// Format an epoch-seconds timestamp as the local-time string the clients
/// expect: `"YYYY-MM-DD Www HH:MM"`, e.g. `"2026-05-11 Mon 14:32"`.
///
/// Matches the format that eav.el produces from LOGBOOK `- State "DONE"` lines;
/// clients only strictly require the leading `YYYY-MM-DD`, but the full form is
/// produced here for parity.
fn format_completion(epoch: i64) -> String {
    use chrono::TimeZone as _;
    match chrono::Local.timestamp_opt(epoch, 0) {
        chrono::LocalResult::Single(dt) | chrono::LocalResult::Ambiguous(dt, _) => {
            dt.format("%Y-%m-%d %a %H:%M").to_string()
        }
        chrono::LocalResult::None => {
            // Epoch is out of range for the local timezone — fall back to UTC
            // string so the client at least receives something parseable.
            chrono::DateTime::from_timestamp(epoch, 0)
                .map(|dt| dt.format("%Y-%m-%d %a %H:%M").to_string())
                .unwrap_or_else(|| epoch.to_string())
        }
    }
}

/// Resolve a `ts` field (from a request body) to an epoch-seconds i64.
///
/// Accepted forms:
/// - JSON number → its i64 value directly.
/// - JSON string with org format `"%Y-%m-%d %a %H:%M"` → parsed as local time.
/// - JSON string with date-only `"%Y-%m-%d"` → midnight in local time.
/// - JSON string as RFC 3339 / ISO-8601 → converted to epoch seconds.
/// - `None` / JSON null / any unparseable string → `now_epoch()`.
fn resolve_ts(v: Option<&serde_json::Value>) -> i64 {
    use chrono::{NaiveDate, TimeZone as _};

    match v {
        Some(serde_json::Value::Number(n)) => n.as_i64().unwrap_or_else(now_epoch),
        Some(serde_json::Value::String(s)) => {
            // Try org full form: "YYYY-MM-DD Www HH:MM"
            if let Ok(ndt) = chrono::NaiveDateTime::parse_from_str(s, "%Y-%m-%d %a %H:%M") {
                if let chrono::LocalResult::Single(dt) | chrono::LocalResult::Ambiguous(dt, _) =
                    chrono::Local.from_local_datetime(&ndt)
                {
                    return dt.timestamp();
                }
            }
            // Try date-only: "YYYY-MM-DD" → local midnight
            if let Ok(nd) = NaiveDate::parse_from_str(s, "%Y-%m-%d") {
                if let Some(ndt) = nd.and_hms_opt(0, 0, 0) {
                    if let chrono::LocalResult::Single(dt) | chrono::LocalResult::Ambiguous(dt, _) =
                        chrono::Local.from_local_datetime(&ndt)
                    {
                        return dt.timestamp();
                    }
                }
            }
            // Try RFC 3339 / ISO-8601
            if let Ok(dt) = chrono::DateTime::parse_from_rfc3339(s) {
                return dt.timestamp();
            }
            // Unrecognised — treat as now
            now_epoch()
        }
        _ => now_epoch(),
    }
}

// ----------------------------------------------------------------------------
// DB-backed habit routes (id-based)
// ----------------------------------------------------------------------------

/// Generate a simple time+counter UUID-like identifier that is unique within
/// the lifetime of this process and across fast concurrent calls. Does not
/// require the `uuid` crate.
fn new_id() -> String {
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let ts = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_micros() as u64;
    let seq = COUNTER.fetch_add(1, Ordering::Relaxed);
    format!("{ts:016x}{seq:08x}")
}

/// Reset all checked/partial checklist markers in a notes string.
///
/// Replaces `- [X]`, `- [x]`, and `- [-]` with `- [ ]` on every line.
/// Preserves indentation, surrounding text, and lines without checklist markers.
fn reset_checklist(notes: &str) -> String {
    use std::sync::OnceLock;
    static RE: OnceLock<regex::Regex> = OnceLock::new();
    let re = RE.get_or_init(|| {
        // Optional leading whitespace, a list bullet (- + *), space, then a
        // checked/partial marker. Captures the `[` prefix and `]` suffix so we
        // can substitute only the inner character with a space.
        regex::Regex::new(r"(?m)^(\s*[-+*] \[)[xX\-](\])").unwrap()
    });
    re.replace_all(notes, "${1} ${2}").into_owned()
}

/// Map a `HabitRow` + its completion timestamps to the wire `Habit` type.
///
/// `next_due` and `state` are derived solely from `anchor_date` (which IS
/// the effective next-due date). Completions are kept for streak/graph use
/// but do not influence scheduling state.
fn row_to_habit(row: &HabitRow, completions_ts: &[i64], today: chrono::NaiveDate) -> Habit {
    let cadence = HabitCadenceSpec {
        kind: row.cadence_kind.clone(),
        value: row.cadence_value,
        unit: row.cadence_unit.clone(),
        max_value: row.cadence_max_value,
        max_unit: row.cadence_max_unit.clone(),
    };

    let anchor = row
        .anchor_date
        .as_deref()
        .and_then(|s| chrono::NaiveDate::parse_from_str(s, "%Y-%m-%d").ok());

    let result = compute_due(&cadence, anchor, today);
    let next_due = result.next_due.format("%Y-%m-%d").to_string();
    let state = result.state.to_string();

    // Format completions newest-first as "YYYY-MM-DD Www HH:MM" (local time).
    let mut formatted_completions: Vec<String> = completions_ts
        .iter()
        .map(|&ts| format_completion(ts))
        .collect();
    formatted_completions.sort_unstable_by(|a, b| b.cmp(a));

    // Parse tags JSON array back to Vec<String>.
    let tags: Vec<String> = serde_json::from_str(&row.tags).unwrap_or_default();

    Habit {
        id: row.id.clone(),
        title: row.title.clone(),
        cadence,
        category: row.category.clone(),
        priority: row.priority.clone(),
        tags,
        notes: row.notes.clone(),
        anchor_date: row.anchor_date.clone(),
        active: row.active,
        reset_checklist_on_complete: row.reset_checklist_on_complete,
        completions: formatted_completions,
        next_due: Some(next_due),
        state: Some(state),
    }
}

#[derive(Deserialize)]
struct HabitsQuery {
    inactive: Option<String>,
}

async fn get_habits(
    State(state): State<AppState>,
    Query(q): Query<HabitsQuery>,
) -> Result<Json<Vec<Habit>>, ApiError> {
    let include_inactive = q.inactive.as_deref() == Some("true");
    let rows = state.store.list_habits(include_inactive)?;
    let all_completions = state.store.all_completions()?;
    let today = chrono::Local::now().date_naive();

    let habits: Vec<Habit> = rows
        .iter()
        .map(|row| {
            let empty = vec![];
            let ts = all_completions.get(&row.id).unwrap_or(&empty);
            row_to_habit(row, ts, today)
        })
        .collect();

    Ok(Json(habits))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CreateHabitBody {
    title: String,
    cadence: HabitCadenceSpec,
    category: Option<String>,
    priority: Option<String>,
    #[serde(default)]
    tags: Vec<String>,
    notes: Option<String>,
    anchor_date: Option<String>,
    #[serde(default)]
    reset_checklist_on_complete: bool,
}

async fn post_habit_create(
    State(state): State<AppState>,
    Json(body): Json<CreateHabitBody>,
) -> Result<Json<Habit>, ApiError> {
    let id = new_id();
    let now = now_epoch();
    let today_str = chrono::Local::now()
        .date_naive()
        .format("%Y-%m-%d")
        .to_string();
    let anchor_date = body.anchor_date.or(Some(today_str));

    let tags_json = serde_json::to_string(&body.tags).unwrap_or_else(|_| "[]".to_string());

    let row = HabitRow {
        id: id.clone(),
        title: body.title,
        cadence_kind: body.cadence.kind,
        cadence_value: body.cadence.value,
        cadence_unit: body.cadence.unit,
        cadence_max_value: body.cadence.max_value,
        cadence_max_unit: body.cadence.max_unit,
        category: body.category,
        priority: body.priority,
        tags: tags_json,
        notes: body.notes,
        anchor_date,
        active: true,
        created_at: now,
        reset_checklist_on_complete: body.reset_checklist_on_complete,
    };

    state.store.create_habit(&row)?;

    let today = chrono::Local::now().date_naive();
    let habit = row_to_habit(&row, &[], today);

    state.events.publish(crate::ServerEvent::HabitsChanged);

    Ok(Json(habit))
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase")]
struct PatchHabitBody {
    title: Option<String>,
    cadence: Option<HabitCadenceSpec>,
    category: Option<serde_json::Value>, // allows explicit null to clear
    priority: Option<serde_json::Value>,
    tags: Option<Vec<String>>,
    notes: Option<serde_json::Value>,
    anchor_date: Option<serde_json::Value>,
    active: Option<bool>,
    reset_checklist_on_complete: Option<bool>,
}

async fn patch_habit(
    State(state): State<AppState>,
    PathParam(id): PathParam<String>,
    Json(body): Json<PatchHabitBody>,
) -> Result<Json<Habit>, ApiError> {
    let mut row = state.store.get_habit(&id)?.ok_or_else(|| ApiError {
        status: StatusCode::NOT_FOUND,
        body: serde_json::json!({ "error": "habit not found" }),
    })?;

    if let Some(title) = body.title {
        row.title = title;
    }
    if let Some(cadence) = body.cadence {
        row.cadence_kind = cadence.kind;
        row.cadence_value = cadence.value;
        row.cadence_unit = cadence.unit;
        row.cadence_max_value = cadence.max_value;
        row.cadence_max_unit = cadence.max_unit;
    }
    if let Some(v) = body.category {
        row.category = if v.is_null() {
            None
        } else {
            v.as_str().map(|s| s.to_string())
        };
    }
    if let Some(v) = body.priority {
        row.priority = if v.is_null() {
            None
        } else {
            v.as_str().map(|s| s.to_string())
        };
    }
    if let Some(tags) = body.tags {
        row.tags = serde_json::to_string(&tags).unwrap_or_else(|_| "[]".to_string());
    }
    if let Some(v) = body.notes {
        row.notes = if v.is_null() {
            None
        } else {
            v.as_str().map(|s| s.to_string())
        };
    }
    if let Some(v) = body.anchor_date {
        row.anchor_date = if v.is_null() {
            None
        } else {
            v.as_str().map(|s| s.to_string())
        };
    }
    if let Some(active) = body.active {
        row.active = active;
    }
    if let Some(v) = body.reset_checklist_on_complete {
        row.reset_checklist_on_complete = v;
    }

    state.store.update_habit(&row)?;

    let completions_ts = state.store.completions_for(&id)?;
    let today = chrono::Local::now().date_naive();
    let habit = row_to_habit(&row, &completions_ts, today);

    state.events.publish(crate::ServerEvent::HabitsChanged);

    Ok(Json(habit))
}

async fn delete_habit(
    State(state): State<AppState>,
    PathParam(id): PathParam<String>,
) -> Result<Json<serde_json::Value>, ApiError> {
    state.store.delete_habit(&id)?;
    state.events.publish(crate::ServerEvent::HabitsChanged);
    Ok(Json(serde_json::json!({ "success": true })))
}

#[derive(Deserialize)]
struct HabitCompleteBody {
    ts: Option<serde_json::Value>,
}

async fn post_habit_complete(
    State(state): State<AppState>,
    PathParam(id): PathParam<String>,
    Json(body): Json<HabitCompleteBody>,
) -> Result<Json<Habit>, ApiError> {
    let mut row = state.store.get_habit(&id)?.ok_or_else(|| ApiError {
        status: StatusCode::NOT_FOUND,
        body: serde_json::json!({ "error": "habit not found" }),
    })?;

    let ts = resolve_ts(body.ts.as_ref());
    state.store.add_completion(&id, ts)?;

    // Advance anchor to the next due date after this completion.
    let today = chrono::Local::now().date_naive();
    let cadence = eav_core::HabitCadenceSpec {
        kind: row.cadence_kind.clone(),
        value: row.cadence_value,
        unit: row.cadence_unit.clone(),
        max_value: row.cadence_max_value,
        max_unit: row.cadence_max_unit.clone(),
    };
    let current_anchor = row
        .anchor_date
        .as_deref()
        .and_then(|s| chrono::NaiveDate::parse_from_str(s, "%Y-%m-%d").ok());
    let new_anchor = advance_anchor(&cadence, current_anchor, today);
    let new_anchor_str = new_anchor.format("%Y-%m-%d").to_string();
    state.store.set_habit_anchor(&id, Some(&new_anchor_str))?;
    row.anchor_date = Some(new_anchor_str);

    // If the reset flag is set, uncheck all checklist items in notes.
    if row.reset_checklist_on_complete {
        if let Some(ref notes) = row.notes.clone() {
            let reset = reset_checklist(notes);
            if reset != *notes {
                row.notes = Some(reset);
                state.store.update_habit(&row)?;
            }
        }
    }

    let completions_ts = state.store.completions_for(&id)?;
    let habit = row_to_habit(&row, &completions_ts, today);

    state.events.publish(crate::ServerEvent::HabitsChanged);

    // Close any running clock for this habit (id is the clock task_id for habits).
    let closed = state.store.clock_out_task(&id, now_epoch())?;
    if closed > 0 {
        state.events.publish(crate::ServerEvent::ClockChanged {
            file: None,
            pos: None,
            clocking: false,
        });
    }

    Ok(Json(habit))
}

#[derive(Deserialize)]
struct HabitUncompleteBody {
    ts: serde_json::Value,
}

async fn post_habit_uncomplete(
    State(state): State<AppState>,
    PathParam(id): PathParam<String>,
    Json(body): Json<HabitUncompleteBody>,
) -> Result<Json<Habit>, ApiError> {
    let mut row = state.store.get_habit(&id)?.ok_or_else(|| ApiError {
        status: StatusCode::NOT_FOUND,
        body: serde_json::json!({ "error": "habit not found" }),
    })?;

    // Resolve which stored epoch to remove.
    //
    // The Swift client only has the minute-precision formatted string
    // (`format_completion` output) — it never stores the raw epoch.
    // Matching by label is therefore the only reliable key.
    match &body.ts {
        serde_json::Value::Number(n) => {
            if let Some(epoch) = n.as_i64() {
                state.store.remove_completion(&id, epoch)?;
            }
        }
        serde_json::Value::String(s) => {
            let stored = state.store.completions_for(&id)?;
            if let Some(&epoch) = stored.iter().find(|&&e| format_completion(e) == *s) {
                state.store.remove_completion(&id, epoch)?;
            }
            // No match → no-op; the client will reconcile from the returned habit.
        }
        _ => {} // null or other unexpected type → no-op
    }

    // Reset anchor to today so the habit becomes due again.
    let today = chrono::Local::now().date_naive();
    let today_str = today.format("%Y-%m-%d").to_string();
    state.store.set_habit_anchor(&id, Some(&today_str))?;
    row.anchor_date = Some(today_str);

    let completions_ts = state.store.completions_for(&id)?;
    let habit = row_to_habit(&row, &completions_ts, today);

    state.events.publish(crate::ServerEvent::HabitsChanged);
    Ok(Json(habit))
}

#[derive(Deserialize)]
struct HabitRescheduleBody {
    date: String,
}

async fn post_habit_skip(
    State(state): State<AppState>,
    PathParam(id): PathParam<String>,
) -> Result<Json<Habit>, ApiError> {
    let mut row = state.store.get_habit(&id)?.ok_or_else(|| ApiError {
        status: StatusCode::NOT_FOUND,
        body: serde_json::json!({ "error": "habit not found" }),
    })?;

    let today = chrono::Local::now().date_naive();
    let cadence = eav_core::HabitCadenceSpec {
        kind: row.cadence_kind.clone(),
        value: row.cadence_value,
        unit: row.cadence_unit.clone(),
        max_value: row.cadence_max_value,
        max_unit: row.cadence_max_unit.clone(),
    };
    let current_anchor = row
        .anchor_date
        .as_deref()
        .and_then(|s| chrono::NaiveDate::parse_from_str(s, "%Y-%m-%d").ok());
    let new_anchor = advance_anchor(&cadence, current_anchor, today);
    let new_anchor_str = new_anchor.format("%Y-%m-%d").to_string();
    state.store.set_habit_anchor(&id, Some(&new_anchor_str))?;
    row.anchor_date = Some(new_anchor_str);

    let completions_ts = state.store.completions_for(&id)?;
    let habit = row_to_habit(&row, &completions_ts, today);

    state.events.publish(crate::ServerEvent::HabitsChanged);
    Ok(Json(habit))
}

async fn post_habit_reschedule(
    State(state): State<AppState>,
    PathParam(id): PathParam<String>,
    Json(body): Json<HabitRescheduleBody>,
) -> Result<Json<Habit>, ApiError> {
    // Validate the date.
    chrono::NaiveDate::parse_from_str(&body.date, "%Y-%m-%d")
        .map_err(|_| bad_request("date must be YYYY-MM-DD"))?;

    let mut row = state.store.get_habit(&id)?.ok_or_else(|| ApiError {
        status: StatusCode::NOT_FOUND,
        body: serde_json::json!({ "error": "habit not found" }),
    })?;

    state.store.set_habit_anchor(&id, Some(&body.date))?;
    row.anchor_date = Some(body.date);

    let today = chrono::Local::now().date_naive();
    let completions_ts = state.store.completions_for(&id)?;
    let habit = row_to_habit(&row, &completions_ts, today);

    state.events.publish(crate::ServerEvent::HabitsChanged);
    Ok(Json(habit))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ClockInBody {
    // file+pos path: resolve a stable id via the bridge
    file: Option<String>,
    pos: Option<u64>,
    // direct-id path: habit uuids and any other pre-keyed ids
    task_id: Option<String>,
    title: Option<String>,
}

async fn post_clock_in(
    State(state): State<AppState>,
    Json(body): Json<ClockInBody>,
) -> Result<Json<Clock>, ApiError> {
    let now = now_epoch();

    let (task_id, file_for_sse, pos_for_sse) = if let Some(tid) = body.task_id {
        // Direct-id path: no bridge call needed.
        (tid, None, None)
    } else {
        let file = body
            .file
            .ok_or_else(|| bad_request("taskId or file+pos required"))?;
        let pos = body
            .pos
            .ok_or_else(|| bad_request("pos required when file is provided"))?;
        let id_resp: serde_json::Value = state
            .bridge
            .call(
                "write.ensure-id",
                serde_json::json!({ "file": file, "pos": pos }),
            )
            .await?;
        let tid = id_resp["id"]
            .as_str()
            .ok_or_else(|| bad_request("ensure-id returned no id"))?
            .to_string();
        (tid, Some(file), Some(pos))
    };

    let row_id = state.store.clock_in(
        &task_id,
        file_for_sse.as_deref(),
        body.title.as_deref(),
        now,
    )?;

    let rows = state.store.clocks_for_task(&task_id)?;
    let row = rows
        .into_iter()
        .find(|r| r.id == row_id)
        .ok_or_else(|| bad_request("clock row not found after insert"))?;

    state.events.publish(crate::ServerEvent::ClockChanged {
        file: file_for_sse,
        pos: pos_for_sse,
        clocking: true,
    });

    Ok(Json(row_to_clock(row)))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ClockOutBody {
    id: Option<i64>,
    task_id: Option<String>,
}

async fn post_clock_out(
    State(state): State<AppState>,
    Json(body): Json<ClockOutBody>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let now = now_epoch();
    match (body.id, body.task_id) {
        (Some(id), _) => state.store.clock_out(id, now)?,
        (None, Some(ref task_id)) => {
            let _ = state.store.clock_out_task(task_id, now)?;
        }
        (None, None) => return Err(bad_request("id or taskId required")),
    }

    state.events.publish(crate::ServerEvent::ClockChanged {
        file: None,
        pos: None,
        clocking: false,
    });

    Ok(Json(serde_json::json!({ "success": true })))
}

async fn get_active_clocks(State(state): State<AppState>) -> Result<Json<Vec<Clock>>, ApiError> {
    let rows = state.store.active_clocks()?;
    Ok(Json(rows.into_iter().map(row_to_clock).collect()))
}

#[derive(Deserialize)]
struct ClocksQuery {
    task: Option<String>,
}

async fn get_clocks_for_task(
    State(state): State<AppState>,
    Query(q): Query<ClocksQuery>,
) -> Result<Json<Vec<Clock>>, ApiError> {
    let task_id = q
        .task
        .ok_or_else(|| bad_request("task query param required"))?;
    let rows = state.store.clocks_for_task(&task_id)?;
    Ok(Json(rows.into_iter().map(row_to_clock).collect()))
}

async fn delete_clock(
    State(state): State<AppState>,
    PathParam(id): PathParam<i64>,
) -> Result<Json<serde_json::Value>, ApiError> {
    state.store.delete_clock(id)?;
    Ok(Json(serde_json::json!({ "success": true })))
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
            .call::<Vec<AgendaEntry>>("read.sexp-entries", serde_json::json!({ "date": date }))
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
    let _: serde_json::Value = state.bridge.call("write.set-notes", body.clone()).await?;
    state.reindex_after_write(&body);
    Ok(Json(serde_json::json!({ "success": true })))
}

/// Record a completed clock interval in the store.
///
/// Body shape: `{file, pos, start, end}` (epoch seconds). Resolves the
/// stable task id via `write.ensure-id` so the row is keyed to the heading
/// rather than the positional synthetic id. Does NOT write a CLOCK: line to
/// the org file.
#[derive(Deserialize)]
struct ClockLogBody {
    file: String,
    pos: u64,
    title: Option<String>,
    start: i64,
    end: i64,
}

async fn post_clock_log(
    State(state): State<AppState>,
    Json(body): Json<ClockLogBody>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let id_resp: serde_json::Value = state
        .bridge
        .call(
            "write.ensure-id",
            serde_json::json!({ "file": body.file, "pos": body.pos }),
        )
        .await?;
    let task_id = id_resp["id"]
        .as_str()
        .ok_or_else(|| bad_request("ensure-id returned no id"))?
        .to_string();

    state.store.add_interval(
        &task_id,
        Some(&body.file),
        body.title.as_deref(),
        body.start,
        body.end,
    )?;

    Ok(Json(serde_json::json!({ "success": true })))
}

async fn post_clock_tidy(
    State(state): State<AppState>,
    Json(body): Json<serde_json::Value>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let r: serde_json::Value = state.bridge.call("write.clock-tidy", body.clone()).await?;
    state.reindex_after_write(&body);
    Ok(Json(r))
}

async fn post_refile(
    State(state): State<AppState>,
    Json(body): Json<serde_json::Value>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let _: serde_json::Value = state.bridge.call("write.refile", body.clone()).await?;
    state.reindex_after_write(&body);
    Ok(Json(serde_json::json!({ "success": true })))
}

async fn post_refile_task(
    State(state): State<AppState>,
    PathParam(_id): PathParam<String>,
    Json(body): Json<serde_json::Value>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let _: serde_json::Value = state.bridge.call("write.refile", body.clone()).await?;
    state.reindex_after_write(&body);
    Ok(Json(serde_json::json!({ "success": true })))
}

async fn post_archive_task(
    State(state): State<AppState>,
    PathParam(_id): PathParam<String>,
    Json(body): Json<serde_json::Value>,
) -> Result<Json<serde_json::Value>, ApiError> {
    // org-archive-subtree both removes the heading from the source file and
    // appends it to the archive file. Both writes are picked up by the
    // file watcher, so we don't need to invalidate the index by hand.
    let _: serde_json::Value = state.bridge.call("write.archive", body.clone()).await?;
    // Re-index the source file (the heading was removed from it); the
    // `.org_archive` destination isn't indexed, so reindex_after_write skips it.
    state.reindex_after_write(&body);
    Ok(Json(serde_json::json!({ "success": true })))
}

async fn patch_title(
    State(state): State<AppState>,
    PathParam(_id): PathParam<String>,
    Json(body): Json<serde_json::Value>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let _: serde_json::Value = state.bridge.call("write.set-title", body.clone()).await?;
    state.reindex_after_write(&body);
    Ok(Json(serde_json::json!({ "success": true })))
}

async fn patch_state(
    State(state): State<AppState>,
    PathParam(_id): PathParam<String>,
    Json(body): Json<serde_json::Value>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let resp: serde_json::Value = state.bridge.call("write.set-state", body.clone()).await?;
    // The elisp side reports `{"success": false, "error": "..."}` when
    // `org-todo` silently refused the transition (e.g. blocked by
    // unfinished sub-tasks with `org-enforce-todo-dependencies` enabled).
    // Promote that to an HTTP error so the client surfaces a meaningful
    // message instead of cheerfully reporting success.
    let success = resp
        .get("success")
        .and_then(|v| v.as_bool())
        .unwrap_or(true);
    if !success {
        let err = resp
            .get("error")
            .and_then(|v| v.as_str())
            .unwrap_or("state change refused by org-mode")
            .to_string();
        return Err(bad_request(&err));
    }
    // Only reindex once org accepted the transition (after the success gate),
    // so a refused state change doesn't trigger a needless re-read.
    state.reindex_after_write(&body);

    // Auto-close any running clock when the task transitions to a done state.
    // The reindex above has already updated the index, so done_task_at reflects
    // the new state. Guard on both file and pos being present; missing either
    // means we can't look up the task and we silently skip (no-op).
    if let (Some(file), Some(pos)) = (
        body.get("file").and_then(|v| v.as_str()),
        body.get("pos").and_then(|v| v.as_u64()),
    ) {
        if let Some(task) = state.index.done_task_at(std::path::Path::new(file), pos) {
            let closed = state.store.clock_out_task(&task.id, now_epoch())?;
            if closed > 0 {
                state.events.publish(crate::ServerEvent::ClockChanged {
                    file: None,
                    pos: None,
                    clocking: false,
                });
            }
        }
    }

    Ok(Json(resp))
}

async fn patch_priority(
    State(state): State<AppState>,
    PathParam(_id): PathParam<String>,
    Json(body): Json<serde_json::Value>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let _: serde_json::Value = state
        .bridge
        .call("write.set-priority", body.clone())
        .await?;
    state.reindex_after_write(&body);
    Ok(Json(serde_json::json!({ "success": true })))
}

async fn patch_tags(
    State(state): State<AppState>,
    PathParam(_id): PathParam<String>,
    Json(body): Json<serde_json::Value>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let _: serde_json::Value = state.bridge.call("write.set-tags", body.clone()).await?;
    state.reindex_after_write(&body);
    Ok(Json(serde_json::json!({ "success": true })))
}

async fn patch_scheduled(
    State(state): State<AppState>,
    PathParam(_id): PathParam<String>,
    Json(body): Json<serde_json::Value>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let _: serde_json::Value = state
        .bridge
        .call("write.set-scheduled", body.clone())
        .await?;
    state.reindex_after_write(&body);
    Ok(Json(serde_json::json!({ "success": true })))
}

async fn patch_deadline(
    State(state): State<AppState>,
    PathParam(_id): PathParam<String>,
    Json(body): Json<serde_json::Value>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let _: serde_json::Value = state
        .bridge
        .call("write.set-deadline", body.clone())
        .await?;
    state.reindex_after_write(&body);
    Ok(Json(serde_json::json!({ "success": true })))
}

async fn patch_property(
    State(state): State<AppState>,
    PathParam(_id): PathParam<String>,
    Json(body): Json<serde_json::Value>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let _: serde_json::Value = state
        .bridge
        .call("write.set-property", body.clone())
        .await?;
    state.reindex_after_write(&body);
    Ok(Json(serde_json::json!({ "success": true })))
}

async fn post_capture(
    State(state): State<AppState>,
    Json(body): Json<serde_json::Value>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let _: serde_json::Value = state.bridge.call("write.capture", body.clone()).await?;
    // Capture's destination is template-resolved and may not be in the body;
    // when absent, reindex_after_write no-ops and the after-save path covers it.
    state.reindex_after_write(&body);
    Ok(Json(serde_json::json!({ "success": true })))
}

async fn post_insert_entry(
    State(state): State<AppState>,
    Json(body): Json<serde_json::Value>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let _: serde_json::Value = state
        .bridge
        .call("write.insert-entry", body.clone())
        .await?;
    state.reindex_after_write(&body);
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
        // The Mac app reads this on startup to decide whether the existing
        // daemon matches the bundled binary, and replaces it if not — the
        // version-handshake half of the lifecycle plan.
        "version": env!("CARGO_PKG_VERSION"),
    })))
}

/// Trigger axum's graceful shutdown. Used by the Mac app when it detects
/// a version mismatch against the currently-running daemon, and by the dev
/// loop / installers that want a clean stop (final snapshot save included).
/// 127.0.0.1-only by default; no auth, same threat model as the other writes.
async fn post_shutdown(State(state): State<AppState>) -> Json<serde_json::Value> {
    if let Some(tx) = state.shutdown_tx.lock().take() {
        let _ = tx.send(());
        Json(serde_json::json!({ "ok": true, "shuttingDown": true }))
    } else {
        // Already triggered — idempotent so concurrent clients don't 500.
        Json(serde_json::json!({ "ok": true, "shuttingDown": true, "alreadyTriggered": true }))
    }
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

// =============================================================================
// Tests
// =============================================================================

#[cfg(test)]
mod tests {
    use super::*;
    use eav_index::HabitRow;

    /// format_completion must produce "YYYY-MM-DD Www HH:MM" in local time.
    /// We test against a known UTC epoch and verify the shape rather than the
    /// exact local string (timezone is CI-dependent).
    ///
    /// "YYYY-MM-DD Www HH:MM" is 20 characters:
    ///   4  + 1 + 2 + 1 + 2 + 1 + 3 + 1 + 5  = 20
    ///   YYYY  -  MM  -  DD     Www    HH:MM
    #[test]
    fn format_completion_shape() {
        // 2026-05-11 14:32:00 UTC
        let epoch: i64 = 1_747_053_120;
        let s = format_completion(epoch);
        // Shape: "YYYY-MM-DD Www HH:MM" — 20 chars
        assert_eq!(s.len(), 20, "unexpected length: {s:?}");
        // Year prefix
        assert!(s.starts_with("202"), "unexpected year: {s:?}");
        // Day-of-week abbreviation is three letters at index 11..14
        let dow = &s[11..14];
        let valid_days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
        assert!(
            valid_days.contains(&dow),
            "unexpected day-of-week {dow:?} in {s:?}"
        );
        // Space at index 14, then HH:MM
        assert_eq!(&s[14..15], " ", "expected space before time in {s:?}");
        let time_part = &s[15..];
        assert_eq!(
            time_part.len(),
            5,
            "expected HH:MM (5 chars), got {time_part:?}"
        );
        assert!(
            time_part.contains(':'),
            "expected HH:MM time part, got {time_part:?}"
        );
    }

    /// new_id must produce unique values across rapid consecutive calls.
    #[test]
    fn new_id_is_unique() {
        let ids: Vec<String> = (0..50).map(|_| new_id()).collect();
        let unique: std::collections::HashSet<&String> = ids.iter().collect();
        assert_eq!(ids.len(), unique.len(), "duplicate ids found");
    }

    /// row_to_habit derives next_due/state from anchor_date only; completions
    /// are carried through for streak/graph but do not influence state.
    #[test]
    fn row_to_habit_anchor_determines_state() {
        // ".+" habit with anchor = 2026-06-01 (future) → state "ok"
        let row = HabitRow {
            id: "hid-1".to_string(),
            title: "Exercise".to_string(),
            cadence_kind: ".+".to_string(),
            cadence_value: 1,
            cadence_unit: "d".to_string(),
            cadence_max_value: None,
            cadence_max_unit: None,
            category: Some("health".to_string()),
            priority: None,
            tags: r#"["exercise"]"#.to_string(),
            notes: None,
            anchor_date: Some("2026-06-01".to_string()),
            active: true,
            created_at: 0,
            reset_checklist_on_complete: false,
        };

        // Two completions are present but must NOT change the state.
        let ts_20 = 1_747_612_800_i64;
        let ts_25 = 1_748_044_800_i64;

        // today: 2026-05-28 (before the anchor)
        let today = chrono::NaiveDate::from_ymd_opt(2026, 5, 28).unwrap();
        let habit = row_to_habit(&row, &[ts_20, ts_25], today);

        assert_eq!(habit.id, "hid-1");
        assert_eq!(habit.title, "Exercise");
        assert_eq!(habit.tags, vec!["exercise"]);
        assert!(habit.active);

        // Anchor is in the future → "ok"
        assert_eq!(habit.state.as_deref(), Some("ok"));
        assert_eq!(habit.next_due.as_deref(), Some("2026-06-01"));

        // Completions must be sorted newest-first and preserved.
        let comps = &habit.completions;
        assert_eq!(comps.len(), 2);
        assert!(
            comps[0] >= comps[1],
            "completions not newest-first: {:?}",
            comps
        );
    }

    /// Anchor in the past → "overdue" for a non-relaxed cadence.
    #[test]
    fn row_to_habit_past_anchor_is_due() {
        let row = HabitRow {
            id: "hid-2".to_string(),
            title: "Walk".to_string(),
            cadence_kind: "+".to_string(),
            cadence_value: 7,
            cadence_unit: "d".to_string(),
            cadence_max_value: None,
            cadence_max_unit: None,
            category: None,
            priority: None,
            tags: "[]".to_string(),
            notes: None,
            anchor_date: Some("2026-05-20".to_string()),
            active: true,
            created_at: 0,
            reset_checklist_on_complete: false,
        };
        let today = chrono::NaiveDate::from_ymd_opt(2026, 5, 28).unwrap();
        let habit = row_to_habit(&row, &[], today);
        assert_eq!(habit.next_due.as_deref(), Some("2026-05-20"));
        assert_eq!(habit.state.as_deref(), Some("overdue"));
    }

    /// clock-in with {taskId, title} must create an open clock row keyed by
    /// that uuid without touching the bridge (no file/pos supplied).
    #[tokio::test]
    async fn clock_in_by_task_id_no_bridge() {
        use axum::body::Body;
        use axum::http::{Request, StatusCode};
        use tower::ServiceExt as _;

        let store = eav_index::Store::open_in_memory().expect("in-memory store");
        let bridge =
            eav_bridge::BridgeClient::connect(std::env::temp_dir().join("nope-clock-in.sock"))
                .await
                .unwrap();
        let state = crate::AppState::new(eav_index::Index::new(), bridge, store.clone());
        let app = crate::build_router(state);

        let habit_uuid = "11111111-2222-3333-4444-555555555555";
        let req = Request::builder()
            .method("POST")
            .uri("/api/clock/in")
            .header("content-type", "application/json")
            .body(Body::from(
                serde_json::json!({ "taskId": habit_uuid, "title": "Morning run" }).to_string(),
            ))
            .unwrap();

        let resp = app.oneshot(req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::OK, "expected 200 from clock-in");

        let body_bytes = axum::body::to_bytes(resp.into_body(), 65536).await.unwrap();
        let clock: serde_json::Value = serde_json::from_slice(&body_bytes).unwrap();

        assert_eq!(
            clock["taskId"].as_str(),
            Some(habit_uuid),
            "taskId must be the habit uuid"
        );
        assert_eq!(
            clock["title"].as_str(),
            Some("Morning run"),
            "title must be preserved"
        );
        assert!(clock["end"].is_null(), "clock must be open (end = null)");

        // Verify the row landed in the store under the right key.
        let active = store.active_clocks().expect("active_clocks");
        assert_eq!(active.len(), 1);
        assert_eq!(active[0].task_id, habit_uuid);
        assert_eq!(active[0].title.as_deref(), Some("Morning run"));
        assert!(
            active[0].file.is_none(),
            "file must be None for id-only clock-in"
        );
    }

    /// A habit with no anchor: next_due = today, state "due".
    #[test]
    fn row_to_habit_no_anchor_is_due_today() {
        let row = HabitRow {
            id: "hid-3".to_string(),
            title: "Meditate".to_string(),
            cadence_kind: ".+".to_string(),
            cadence_value: 7,
            cadence_unit: "d".to_string(),
            cadence_max_value: None,
            cadence_max_unit: None,
            category: None,
            priority: None,
            tags: "[]".to_string(),
            notes: None,
            anchor_date: None,
            active: true,
            created_at: 0,
            reset_checklist_on_complete: false,
        };
        let today = chrono::NaiveDate::from_ymd_opt(2026, 5, 28).unwrap();
        let habit = row_to_habit(&row, &[], today);
        assert_eq!(habit.next_due.as_deref(), Some("2026-05-28"));
        assert_eq!(habit.state.as_deref(), Some("due"));
        assert!(habit.completions.is_empty());
    }

    // -------------------------------------------------------------------------
    // reset_checklist helper
    // -------------------------------------------------------------------------

    #[test]
    fn reset_checklist_unchecks_all_markers() {
        let input = "Steps:\n- [X] First\n- [x] Second\n- [-] Third\n- [ ] Already clear\n- plain line\n  - [X] Indented";
        let got = reset_checklist(input);
        assert_eq!(
            got,
            "Steps:\n- [ ] First\n- [ ] Second\n- [ ] Third\n- [ ] Already clear\n- plain line\n  - [ ] Indented"
        );
    }

    #[test]
    fn reset_checklist_no_op_when_nothing_checked() {
        let input = "- [ ] Not checked\n- [ ] Also clear";
        let got = reset_checklist(input);
        assert_eq!(got, input);
    }

    // -------------------------------------------------------------------------
    // POST /api/habits/:id/complete — checklist reset
    // -------------------------------------------------------------------------

    async fn make_app() -> (axum::Router, eav_index::Store) {
        let store = eav_index::Store::open_in_memory().expect("in-memory store");
        let bridge =
            eav_bridge::BridgeClient::connect(std::env::temp_dir().join("nope-complete.sock"))
                .await
                .unwrap();
        let state = crate::AppState::new(eav_index::Index::new(), bridge, store.clone());
        (crate::build_router(state), store)
    }

    fn checklist_habit(id: &str, reset: bool) -> HabitRow {
        HabitRow {
            id: id.to_string(),
            title: "Morning routine".to_string(),
            cadence_kind: "+".to_string(),
            cadence_value: 1,
            cadence_unit: "d".to_string(),
            cadence_max_value: None,
            cadence_max_unit: None,
            category: None,
            priority: None,
            tags: "[]".to_string(),
            notes: Some("- [X] Wake up\n- [x] Stretch\n- [-] Meditate\n- [ ] Coffee".to_string()),
            anchor_date: Some("2026-05-30".to_string()),
            active: true,
            created_at: 1_700_000_000,
            reset_checklist_on_complete: reset,
        }
    }

    /// complete with reset_checklist_on_complete=true: notes get unchecked,
    /// anchor advances, completion is logged.
    #[tokio::test]
    async fn complete_with_reset_flag_resets_checklist() {
        use axum::body::Body;
        use axum::http::{Request, StatusCode};
        use tower::ServiceExt as _;

        let (app, store) = make_app().await;
        let h = checklist_habit("habit-reset", true);
        store.create_habit(&h).unwrap();

        let req = Request::builder()
            .method("POST")
            .uri("/api/habits/habit-reset/complete")
            .header("content-type", "application/json")
            .body(Body::from(
                serde_json::json!({ "ts": 1_748_044_800_i64 }).to_string(),
            ))
            .unwrap();

        let resp = app.oneshot(req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::OK);

        let bytes = axum::body::to_bytes(resp.into_body(), 65536).await.unwrap();
        let habit: serde_json::Value = serde_json::from_slice(&bytes).unwrap();

        // Checklist must be fully unchecked.
        let notes = habit["notes"].as_str().expect("notes must be present");
        assert!(
            !notes.contains("[X]") && !notes.contains("[x]") && !notes.contains("[-]"),
            "checked markers remain after reset: {notes:?}"
        );
        assert!(
            notes.contains("- [ ] Wake up"),
            "expected unchecked items in notes: {notes:?}"
        );
        // Unchecked item must be preserved as-is.
        assert!(
            notes.contains("- [ ] Coffee"),
            "unchanged item gone: {notes:?}"
        );

        // Anchor must have advanced past 2026-05-30.
        let anchor = habit["anchorDate"].as_str().expect("anchorDate present");
        assert!(anchor > "2026-05-30", "anchor did not advance: {anchor:?}");

        // Completion must be recorded.
        assert_eq!(habit["completions"].as_array().unwrap().len(), 1);

        // Verify store persisted the reset notes.
        let stored = store.get_habit("habit-reset").unwrap().unwrap();
        assert!(
            stored
                .notes
                .as_deref()
                .unwrap_or("")
                .contains("- [ ] Wake up"),
            "store did not persist reset notes"
        );
    }

    /// complete with reset_checklist_on_complete=false: notes unchanged.
    #[tokio::test]
    async fn complete_without_reset_flag_keeps_checklist() {
        use axum::body::Body;
        use axum::http::{Request, StatusCode};
        use tower::ServiceExt as _;

        let (app, store) = make_app().await;
        let h = checklist_habit("habit-no-reset", false);
        store.create_habit(&h).unwrap();

        let req = Request::builder()
            .method("POST")
            .uri("/api/habits/habit-no-reset/complete")
            .header("content-type", "application/json")
            .body(Body::from(
                serde_json::json!({ "ts": 1_748_044_800_i64 }).to_string(),
            ))
            .unwrap();

        let resp = app.oneshot(req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::OK);

        let bytes = axum::body::to_bytes(resp.into_body(), 65536).await.unwrap();
        let habit: serde_json::Value = serde_json::from_slice(&bytes).unwrap();

        // Notes must keep the checked markers.
        let notes = habit["notes"].as_str().expect("notes must be present");
        assert!(
            notes.contains("[X]") || notes.contains("[x]") || notes.contains("[-]"),
            "checked markers were cleared but flag was false: {notes:?}"
        );

        // Anchor advanced, completion logged.
        let anchor = habit["anchorDate"].as_str().expect("anchorDate present");
        assert!(anchor > "2026-05-30", "anchor did not advance: {anchor:?}");
        assert_eq!(habit["completions"].as_array().unwrap().len(), 1);
    }

    // -------------------------------------------------------------------------
    // resolve_ts
    // -------------------------------------------------------------------------

    #[test]
    fn resolve_ts_number() {
        let v = serde_json::json!(1_748_044_800_i64);
        assert_eq!(resolve_ts(Some(&v)), 1_748_044_800_i64);
    }

    #[test]
    fn resolve_ts_org_string() {
        // "2026-05-23 Sat 14:32" — parse must produce a timestamp whose
        // format_completion round-trips back to the same string.
        let s = "2026-05-23 Sat 14:32";
        let v = serde_json::json!(s);
        let epoch = resolve_ts(Some(&v));
        // The epoch must round-trip through format_completion to the same minute.
        let formatted = format_completion(epoch);
        assert_eq!(formatted, s, "org-string did not round-trip: epoch={epoch}");
    }

    #[test]
    fn resolve_ts_date_only_string() {
        let v = serde_json::json!("2026-05-23");
        let epoch = resolve_ts(Some(&v));
        // Should be a positive epoch (well after 1970) and format as 2026-05-23 xx:xx.
        assert!(epoch > 0, "expected positive epoch, got {epoch}");
        let formatted = format_completion(epoch);
        assert!(
            formatted.starts_with("2026-05-23"),
            "date-only did not land on the right day: {formatted:?}"
        );
    }

    #[test]
    fn resolve_ts_iso8601_string() {
        // 2026-05-23T14:32:00Z
        let v = serde_json::json!("2026-05-23T14:32:00Z");
        let epoch = resolve_ts(Some(&v));
        // 2026-05-23 14:32:00 UTC = 1779546720
        assert_eq!(epoch, 1_779_546_720_i64, "ISO-8601 UTC parse mismatch");
    }

    #[test]
    fn resolve_ts_garbage_falls_back_to_now() {
        let before = now_epoch();
        let v = serde_json::json!("not-a-date");
        let epoch = resolve_ts(Some(&v));
        let after = now_epoch();
        assert!(
            epoch >= before && epoch <= after,
            "garbage string should fall back to now, got {epoch}"
        );
    }

    #[test]
    fn resolve_ts_none_falls_back_to_now() {
        let before = now_epoch();
        let epoch = resolve_ts(None);
        let after = now_epoch();
        assert!(
            epoch >= before && epoch <= after,
            "None should fall back to now, got {epoch}"
        );
    }

    // -------------------------------------------------------------------------
    // POST /api/habits/:id/complete — org-string ts accepted
    // -------------------------------------------------------------------------

    #[tokio::test]
    async fn complete_with_org_string_ts() {
        use axum::body::Body;
        use axum::http::{Request, StatusCode};
        use tower::ServiceExt as _;

        let (app, store) = make_app().await;
        let h = checklist_habit("habit-str-ts", false);
        store.create_habit(&h).unwrap();

        let req = Request::builder()
            .method("POST")
            .uri("/api/habits/habit-str-ts/complete")
            .header("content-type", "application/json")
            .body(Body::from(
                serde_json::json!({ "ts": "2026-05-31 Sun 14:32" }).to_string(),
            ))
            .unwrap();

        let resp = app.oneshot(req).await.unwrap();
        assert_eq!(
            resp.status(),
            StatusCode::OK,
            "org-string ts must be accepted (not 422)"
        );

        let bytes = axum::body::to_bytes(resp.into_body(), 65536).await.unwrap();
        let habit: serde_json::Value = serde_json::from_slice(&bytes).unwrap();

        let comps = habit["completions"].as_array().unwrap();
        assert_eq!(comps.len(), 1, "completion must be recorded");
        // The stored completion should round-trip to the same minute string.
        assert_eq!(
            comps[0].as_str(),
            Some("2026-05-31 Sun 14:32"),
            "stored completion label mismatch"
        );
    }

    // -------------------------------------------------------------------------
    // POST /api/habits/:id/uncomplete — string label match
    // -------------------------------------------------------------------------

    #[tokio::test]
    async fn uncomplete_by_string_label() {
        use axum::body::Body;
        use axum::http::{Request, StatusCode};
        use tower::ServiceExt as _;

        let (app, store) = make_app().await;

        // Insert a bare-bones habit (checklist reset off so notes are unchanged).
        let h = checklist_habit("habit-unc", false);
        store.create_habit(&h).unwrap();

        // Complete it with a known epoch whose org-label we can predict.
        // 2026-05-23 Sat 14:32 UTC+0 — but format_completion uses Local.
        // Use resolve_ts to get the canonical epoch for the org string.
        let label = "2026-05-23 Sat 14:32";
        let epoch = resolve_ts(Some(&serde_json::json!(label)));
        store.add_completion("habit-unc", epoch).unwrap();

        // Sanity: the label round-trips.
        assert_eq!(format_completion(epoch), label);

        // Now uncomplete by the string label.
        let req = Request::builder()
            .method("POST")
            .uri("/api/habits/habit-unc/uncomplete")
            .header("content-type", "application/json")
            .body(Body::from(serde_json::json!({ "ts": label }).to_string()))
            .unwrap();

        let resp = app.oneshot(req).await.unwrap();
        assert_eq!(
            resp.status(),
            StatusCode::OK,
            "uncomplete by string must succeed"
        );

        let bytes = axum::body::to_bytes(resp.into_body(), 65536).await.unwrap();
        let habit: serde_json::Value = serde_json::from_slice(&bytes).unwrap();

        assert!(
            habit["completions"].as_array().unwrap().is_empty(),
            "completion must be removed by label match"
        );
    }

    #[tokio::test]
    async fn uncomplete_by_number_epoch() {
        use axum::body::Body;
        use axum::http::{Request, StatusCode};
        use tower::ServiceExt as _;

        let (app, store) = make_app().await;
        let h = checklist_habit("habit-unc-num", false);
        store.create_habit(&h).unwrap();

        let epoch: i64 = 1_748_044_800;
        store.add_completion("habit-unc-num", epoch).unwrap();

        let req = Request::builder()
            .method("POST")
            .uri("/api/habits/habit-unc-num/uncomplete")
            .header("content-type", "application/json")
            .body(Body::from(serde_json::json!({ "ts": epoch }).to_string()))
            .unwrap();

        let resp = app.oneshot(req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::OK);

        let bytes = axum::body::to_bytes(resp.into_body(), 65536).await.unwrap();
        let habit: serde_json::Value = serde_json::from_slice(&bytes).unwrap();

        assert!(
            habit["completions"].as_array().unwrap().is_empty(),
            "completion must be removed by epoch number"
        );
    }

    #[tokio::test]
    async fn uncomplete_no_match_is_noop() {
        use axum::body::Body;
        use axum::http::{Request, StatusCode};
        use tower::ServiceExt as _;

        let (app, store) = make_app().await;
        let h = checklist_habit("habit-unc-noop", false);
        store.create_habit(&h).unwrap();

        let epoch: i64 = 1_748_044_800;
        store.add_completion("habit-unc-noop", epoch).unwrap();

        // Send a label that doesn't match any stored completion.
        let req = Request::builder()
            .method("POST")
            .uri("/api/habits/habit-unc-noop/uncomplete")
            .header("content-type", "application/json")
            .body(Body::from(
                serde_json::json!({ "ts": "1999-01-01 Fri 00:00" }).to_string(),
            ))
            .unwrap();

        let resp = app.oneshot(req).await.unwrap();
        // Must still be 200 — no match is a no-op, not an error.
        assert_eq!(
            resp.status(),
            StatusCode::OK,
            "no-match must be a no-op 200"
        );

        let bytes = axum::body::to_bytes(resp.into_body(), 65536).await.unwrap();
        let habit: serde_json::Value = serde_json::from_slice(&bytes).unwrap();

        // The original completion must still be there.
        assert_eq!(
            habit["completions"].as_array().unwrap().len(),
            1,
            "existing completion must survive a no-match uncomplete"
        );
    }
}
