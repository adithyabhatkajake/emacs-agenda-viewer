//! Durable SQLite store for clocks and habit completions.
//!
//! This is NOT the snapshot cache (`snapshot.rs`). The snapshot is
//! disposable — its tables are wiped on any schema-version bump and
//! rebuilt from org files. Clock entries and habit completions recorded
//! here must survive daemon restarts, config changes, and schema bumps.
//!
//! # Migration contract
//!
//! Schema evolution MUST be additive. On a version bump, add new tables or
//! ALTER TABLE … ADD COLUMN. NEVER DROP, NEVER DELETE, NEVER recreate. The
//! store is the user's durable record. A future add might look like:
//!
//!   if stored < 3 {
//!       conn.execute_batch("ALTER TABLE clock ADD COLUMN project TEXT")?;
//!       conn.pragma_update(None, "user_version", 3)?;
//!   }
//!
//! # Exception: habit_completion re-key at version 2
//!
//! `habit_completion` was originally keyed by `task_id TEXT` (an org heading
//! id). At version 2, habits become first-class DB entities with their own
//! UUID primary key in the `habit` table. `habit_completion` is therefore
//! re-keyed to `habit_id TEXT` referencing `habit.id`.
//!
//! This is the single deliberate exception to the additive-only rule:
//! - There was no production data in `habit_completion` at the time of the
//!   migration (only test rows created during development).
//! - The column rename cannot be expressed as an additive ALTER; SQLite does
//!   not support DROP COLUMN on older versions and we want a clean schema
//!   with a real FK name, not a ghost `task_id` column.
//! - The migration is contained: only `habit_completion` is recreated.
//!   All other tables (`clock`, and any future tables) remain untouched.
//!
//! Any future change to `habit_completion` must follow the additive rule.

use parking_lot::Mutex;
use rusqlite::{params, Connection};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;

const SCHEMA_VERSION: i32 = 3;

const SCHEMA_SQL: &str = r#"
CREATE TABLE IF NOT EXISTS clock (
    id       INTEGER PRIMARY KEY,
    task_id  TEXT    NOT NULL,
    file     TEXT,
    title    TEXT,
    start    INTEGER NOT NULL,
    end      INTEGER,
    note     TEXT
);
CREATE INDEX IF NOT EXISTS idx_clock_task ON clock(task_id);
CREATE INDEX IF NOT EXISTS idx_clock_open ON clock(task_id) WHERE end IS NULL;

CREATE TABLE IF NOT EXISTS habit (
    id                          TEXT    PRIMARY KEY,
    title                       TEXT    NOT NULL,
    cadence_kind                TEXT    NOT NULL,
    cadence_value               INTEGER NOT NULL,
    cadence_unit                TEXT    NOT NULL,
    cadence_max_value           INTEGER,
    cadence_max_unit            TEXT,
    category                    TEXT,
    priority                    TEXT,
    tags                        TEXT,
    notes                       TEXT,
    anchor_date                 TEXT,
    active                      INTEGER NOT NULL DEFAULT 1,
    created_at                  INTEGER NOT NULL,
    reset_checklist_on_complete INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_habit_active ON habit(active);

CREATE TABLE IF NOT EXISTS habit_completion (
    id        INTEGER PRIMARY KEY,
    habit_id  TEXT    NOT NULL,
    ts        INTEGER NOT NULL,
    UNIQUE(habit_id, ts)
);
CREATE INDEX IF NOT EXISTS idx_hc_habit ON habit_completion(habit_id);
"#;

#[derive(Debug, Clone)]
pub struct ClockRow {
    pub id: i64,
    pub task_id: String,
    pub file: Option<String>,
    pub title: Option<String>,
    pub start: i64,
    pub end: Option<i64>,
    pub note: Option<String>,
}

/// A habit definition row.
///
/// `cadence_kind`: one of "+" (fixed interval from last completion),
/// "++" (fixed interval from scheduled date), ".+" (from completion,
/// up to cadence_max). Matches org-habit notation.
///
/// `tags`: stored as a JSON array string, e.g. `["exercise","health"]`.
/// Empty if none.
///
/// `anchor_date`: YYYY-MM-DD; optional reference date for cadence math.
///
/// `active`: 1 = active, 0 = archived. Soft-delete; completions are kept.
#[derive(Debug, Clone, PartialEq)]
pub struct HabitRow {
    pub id: String,
    pub title: String,
    /// "+" | "++" | ".+"
    pub cadence_kind: String,
    pub cadence_value: i64,
    /// "d" | "w" | "m" | "y"
    pub cadence_unit: String,
    pub cadence_max_value: Option<i64>,
    pub cadence_max_unit: Option<String>,
    pub category: Option<String>,
    pub priority: Option<String>,
    /// JSON array string, e.g. `["tag1","tag2"]` or `"[]"`.
    pub tags: String,
    pub notes: Option<String>,
    pub anchor_date: Option<String>,
    pub active: bool,
    /// Unix timestamp (seconds) when the row was created.
    pub created_at: i64,
    /// When true, completing this habit resets its notes checklist.
    pub reset_checklist_on_complete: bool,
}

/// Durable store for clock entries and habit completions.
///
/// `Clone` is cheap (Arc-shared). Safe to hand to axum handlers.
#[derive(Clone)]
pub struct Store {
    conn: Arc<Mutex<Connection>>,
}

impl Store {
    /// Open or create the store at PATH, running schema creation and any
    /// pending additive migrations.
    pub fn open(path: &Path) -> rusqlite::Result<Self> {
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let conn = Connection::open(path)?;
        // WAL mode: allows concurrent readers while the mutex-guarded writer
        // is active. Important once route handlers read while a clock-out
        // write is in flight.
        conn.pragma_update(None, "journal_mode", "WAL")?;
        Self::apply_migrations(conn)
    }

    /// Open an in-memory store (for tests or fallback when disk is unavailable).
    pub fn open_in_memory() -> rusqlite::Result<Self> {
        let conn = Connection::open_in_memory()?;
        Self::apply_migrations(conn)
    }

    fn apply_migrations(conn: Connection) -> rusqlite::Result<Self> {
        let stored: i32 = conn.pragma_query_value(None, "user_version", |r| r.get(0))?;

        // Version 2 re-keys habit_completion from task_id to habit_id.
        // This is permitted exactly once: there was no production data in
        // habit_completion at the time this migration was written. See the
        // module-level doc comment for the full rationale.
        if stored < 2 {
            conn.execute_batch("DROP TABLE IF EXISTS habit_completion;")?;
        }

        // Create/ensure all tables. Safe to run on both fresh and migrated DBs
        // because every statement is CREATE ... IF NOT EXISTS.
        conn.execute_batch(SCHEMA_SQL)?;

        // Version 3: add reset_checklist_on_complete to the habit table.
        // Only needed when upgrading from exactly version 2 — the `habit` table
        // exists but lacks the column. For stored < 2 the table was just created
        // by SCHEMA_SQL which already includes the column, so the ALTER is skipped.
        if stored == 2 {
            conn.execute_batch(
                "ALTER TABLE habit ADD COLUMN reset_checklist_on_complete INTEGER NOT NULL DEFAULT 0;",
            )?;
        }

        if stored < SCHEMA_VERSION {
            conn.pragma_update(None, "user_version", SCHEMA_VERSION)?;
        }
        Ok(Self {
            conn: Arc::new(Mutex::new(conn)),
        })
    }

    /// Default location: `$XDG_CACHE_HOME/eavd/data.sqlite`, fallback
    /// `~/Library/Caches/eavd/data.sqlite` (macOS) or `~/.cache/eavd` on Linux.
    /// Deliberately uses a filename different from `snapshot.sqlite`.
    pub fn default_path() -> PathBuf {
        if let Ok(xdg) = std::env::var("XDG_CACHE_HOME") {
            return PathBuf::from(xdg).join("eavd").join("data.sqlite");
        }
        if let Ok(home) = std::env::var("HOME") {
            #[cfg(target_os = "macos")]
            {
                return PathBuf::from(home)
                    .join("Library")
                    .join("Caches")
                    .join("eavd")
                    .join("data.sqlite");
            }
            #[cfg(not(target_os = "macos"))]
            {
                return PathBuf::from(home)
                    .join(".cache")
                    .join("eavd")
                    .join("data.sqlite");
            }
        }
        PathBuf::from("eavd-data.sqlite")
    }

    // -------------------------------------------------------------------------
    // Clock methods
    // -------------------------------------------------------------------------

    /// Insert an open clock row. Returns the new row id.
    pub fn clock_in(
        &self,
        task_id: &str,
        file: Option<&str>,
        title: Option<&str>,
        start: i64,
    ) -> rusqlite::Result<i64> {
        let conn = self.conn.lock();
        conn.execute(
            "INSERT INTO clock (task_id, file, title, start) VALUES (?1, ?2, ?3, ?4)",
            params![task_id, file, title, start],
        )?;
        Ok(conn.last_insert_rowid())
    }

    /// Close a specific clock row by id.
    pub fn clock_out(&self, id: i64, end: i64) -> rusqlite::Result<()> {
        let conn = self.conn.lock();
        conn.execute(
            "UPDATE clock SET end = ?1 WHERE id = ?2 AND end IS NULL",
            params![end, id],
        )?;
        Ok(())
    }

    /// Close all open clock rows for a task (end IS NULL).
    /// Returns the number of rows closed (0 if the task had no running clock).
    pub fn clock_out_task(&self, task_id: &str, end: i64) -> rusqlite::Result<usize> {
        let conn = self.conn.lock();
        let n = conn.execute(
            "UPDATE clock SET end = ?1 WHERE task_id = ?2 AND end IS NULL",
            params![end, task_id],
        )?;
        Ok(n)
    }

    /// All open (end IS NULL) clock rows across all tasks.
    pub fn active_clocks(&self) -> rusqlite::Result<Vec<ClockRow>> {
        let conn = self.conn.lock();
        let mut stmt = conn.prepare(
            "SELECT id, task_id, file, title, start, end, note \
             FROM clock WHERE end IS NULL ORDER BY start",
        )?;
        collect_clock_rows(&mut stmt, [])
    }

    /// All clock rows for a specific task, newest first.
    pub fn clocks_for_task(&self, task_id: &str) -> rusqlite::Result<Vec<ClockRow>> {
        let conn = self.conn.lock();
        let mut stmt = conn.prepare(
            "SELECT id, task_id, file, title, start, end, note \
             FROM clock WHERE task_id = ?1 ORDER BY start DESC",
        )?;
        collect_clock_rows(&mut stmt, params![task_id])
    }

    /// Delete a clock row by id (for corrections / undo).
    pub fn delete_clock(&self, id: i64) -> rusqlite::Result<()> {
        self.conn
            .lock()
            .execute("DELETE FROM clock WHERE id = ?1", params![id])?;
        Ok(())
    }

    /// Insert a completed (closed) clock interval directly. Used when a client
    /// records a past start→end range without going through clock_in/clock_out.
    /// Returns the new row id.
    pub fn add_interval(
        &self,
        task_id: &str,
        file: Option<&str>,
        title: Option<&str>,
        start: i64,
        end: i64,
    ) -> rusqlite::Result<i64> {
        let conn = self.conn.lock();
        conn.execute(
            "INSERT INTO clock (task_id, file, title, start, end) VALUES (?1, ?2, ?3, ?4, ?5)",
            params![task_id, file, title, start, end],
        )?;
        Ok(conn.last_insert_rowid())
    }

    // -------------------------------------------------------------------------
    // Habit definition methods
    // -------------------------------------------------------------------------

    /// Insert a new habit row. The caller supplies the UUID `id`.
    pub fn create_habit(&self, h: &HabitRow) -> rusqlite::Result<()> {
        self.conn.lock().execute(
            "INSERT INTO habit \
             (id, title, cadence_kind, cadence_value, cadence_unit, \
              cadence_max_value, cadence_max_unit, category, priority, \
              tags, notes, anchor_date, active, created_at, \
              reset_checklist_on_complete) \
             VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15)",
            params![
                h.id,
                h.title,
                h.cadence_kind,
                h.cadence_value,
                h.cadence_unit,
                h.cadence_max_value,
                h.cadence_max_unit,
                h.category,
                h.priority,
                h.tags,
                h.notes,
                h.anchor_date,
                h.active as i64,
                h.created_at,
                h.reset_checklist_on_complete as i64,
            ],
        )?;
        Ok(())
    }

    /// Fetch a single habit by id.
    pub fn get_habit(&self, id: &str) -> rusqlite::Result<Option<HabitRow>> {
        let conn = self.conn.lock();
        let mut stmt = conn.prepare(
            "SELECT id, title, cadence_kind, cadence_value, cadence_unit, \
             cadence_max_value, cadence_max_unit, category, priority, \
             tags, notes, anchor_date, active, created_at, \
             reset_checklist_on_complete \
             FROM habit WHERE id = ?1",
        )?;
        let mut rows = stmt.query_map(params![id], map_habit_row)?;
        match rows.next() {
            Some(r) => r.map(Some),
            None => Ok(None),
        }
    }

    /// List all habits, optionally including inactive (archived) ones.
    pub fn list_habits(&self, include_inactive: bool) -> rusqlite::Result<Vec<HabitRow>> {
        let conn = self.conn.lock();
        let sql = if include_inactive {
            "SELECT id, title, cadence_kind, cadence_value, cadence_unit, \
             cadence_max_value, cadence_max_unit, category, priority, \
             tags, notes, anchor_date, active, created_at, \
             reset_checklist_on_complete \
             FROM habit ORDER BY created_at"
        } else {
            "SELECT id, title, cadence_kind, cadence_value, cadence_unit, \
             cadence_max_value, cadence_max_unit, category, priority, \
             tags, notes, anchor_date, active, created_at, \
             reset_checklist_on_complete \
             FROM habit WHERE active = 1 ORDER BY created_at"
        };
        let mut stmt = conn.prepare(sql)?;
        let rows = stmt.query_map([], map_habit_row)?;
        rows.collect()
    }

    /// Full upsert by id (INSERT OR REPLACE). Replaces all fields.
    pub fn update_habit(&self, h: &HabitRow) -> rusqlite::Result<()> {
        self.conn.lock().execute(
            "INSERT OR REPLACE INTO habit \
             (id, title, cadence_kind, cadence_value, cadence_unit, \
              cadence_max_value, cadence_max_unit, category, priority, \
              tags, notes, anchor_date, active, created_at, \
              reset_checklist_on_complete) \
             VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15)",
            params![
                h.id,
                h.title,
                h.cadence_kind,
                h.cadence_value,
                h.cadence_unit,
                h.cadence_max_value,
                h.cadence_max_unit,
                h.category,
                h.priority,
                h.tags,
                h.notes,
                h.anchor_date,
                h.active as i64,
                h.created_at,
                h.reset_checklist_on_complete as i64,
            ],
        )?;
        Ok(())
    }

    /// Hard-delete a habit and its completions.
    pub fn delete_habit(&self, id: &str) -> rusqlite::Result<()> {
        let conn = self.conn.lock();
        conn.execute(
            "DELETE FROM habit_completion WHERE habit_id = ?1",
            params![id],
        )?;
        conn.execute("DELETE FROM habit WHERE id = ?1", params![id])?;
        Ok(())
    }

    /// Update only the `anchor_date` field for a habit.
    pub fn set_habit_anchor(&self, id: &str, anchor_date: Option<&str>) -> rusqlite::Result<()> {
        self.conn.lock().execute(
            "UPDATE habit SET anchor_date = ?1 WHERE id = ?2",
            params![anchor_date, id],
        )?;
        Ok(())
    }

    /// Flip the `active` flag without touching any other field.
    pub fn set_habit_active(&self, id: &str, active: bool) -> rusqlite::Result<()> {
        self.conn.lock().execute(
            "UPDATE habit SET active = ?1 WHERE id = ?2",
            params![active as i64, id],
        )?;
        Ok(())
    }

    // -------------------------------------------------------------------------
    // Habit completion methods
    // -------------------------------------------------------------------------

    /// Record a completion. Returns `true` if the row was inserted (new), `false`
    /// if it already existed (idempotent via UNIQUE(habit_id, ts)).
    pub fn add_completion(&self, habit_id: &str, ts: i64) -> rusqlite::Result<bool> {
        let conn = self.conn.lock();
        let n = conn.execute(
            "INSERT OR IGNORE INTO habit_completion (habit_id, ts) VALUES (?1, ?2)",
            params![habit_id, ts],
        )?;
        Ok(n > 0)
    }

    /// Remove a specific completion.
    pub fn remove_completion(&self, habit_id: &str, ts: i64) -> rusqlite::Result<()> {
        self.conn.lock().execute(
            "DELETE FROM habit_completion WHERE habit_id = ?1 AND ts = ?2",
            params![habit_id, ts],
        )?;
        Ok(())
    }

    /// All completion timestamps for a habit, ascending.
    pub fn completions_for(&self, habit_id: &str) -> rusqlite::Result<Vec<i64>> {
        let conn = self.conn.lock();
        let mut stmt =
            conn.prepare("SELECT ts FROM habit_completion WHERE habit_id = ?1 ORDER BY ts")?;
        let rows = stmt.query_map(params![habit_id], |r| r.get(0))?;
        rows.collect()
    }

    /// All completions keyed by habit_id. Used to bulk-enrich habits at route time.
    pub fn all_completions(&self) -> rusqlite::Result<HashMap<String, Vec<i64>>> {
        let conn = self.conn.lock();
        let mut stmt =
            conn.prepare("SELECT habit_id, ts FROM habit_completion ORDER BY habit_id, ts")?;
        let rows = stmt.query_map([], |r| {
            let habit_id: String = r.get(0)?;
            let ts: i64 = r.get(1)?;
            Ok((habit_id, ts))
        })?;
        let mut map: HashMap<String, Vec<i64>> = HashMap::new();
        for row in rows {
            let (habit_id, ts) = row?;
            map.entry(habit_id).or_default().push(ts);
        }
        Ok(map)
    }
}

/// Helper: map a rusqlite Row from the `habit` SELECT column list into a HabitRow.
fn map_habit_row(r: &rusqlite::Row<'_>) -> rusqlite::Result<HabitRow> {
    let active_int: i64 = r.get(12)?;
    let reset_int: i64 = r.get(14)?;
    Ok(HabitRow {
        id: r.get(0)?,
        title: r.get(1)?,
        cadence_kind: r.get(2)?,
        cadence_value: r.get(3)?,
        cadence_unit: r.get(4)?,
        cadence_max_value: r.get(5)?,
        cadence_max_unit: r.get(6)?,
        category: r.get(7)?,
        priority: r.get(8)?,
        tags: r.get(9)?,
        notes: r.get(10)?,
        anchor_date: r.get(11)?,
        active: active_int != 0,
        created_at: r.get(13)?,
        reset_checklist_on_complete: reset_int != 0,
    })
}

/// Helper: drain a prepared SELECT … FROM clock statement into a Vec<ClockRow>.
fn collect_clock_rows<P: rusqlite::Params>(
    stmt: &mut rusqlite::Statement<'_>,
    params: P,
) -> rusqlite::Result<Vec<ClockRow>> {
    let rows = stmt.query_map(params, |r| {
        Ok(ClockRow {
            id: r.get(0)?,
            task_id: r.get(1)?,
            file: r.get(2)?,
            title: r.get(3)?,
            start: r.get(4)?,
            end: r.get(5)?,
            note: r.get(6)?,
        })
    })?;
    rows.collect()
}

// =============================================================================
// Tests
// =============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    fn mem() -> Store {
        Store::open_in_memory().expect("in-memory store")
    }

    // -------------------------------------------------------------------------
    // Clock tests
    // -------------------------------------------------------------------------

    #[test]
    fn clock_in_out_round_trip() {
        let s = mem();
        let id = s
            .clock_in("task::1", Some("/tmp/a.org"), Some("My task"), 1000)
            .unwrap();
        assert!(id > 0);

        // Row is open.
        let active = s.active_clocks().unwrap();
        assert_eq!(active.len(), 1);
        assert_eq!(active[0].id, id);
        assert_eq!(active[0].task_id, "task::1");
        assert_eq!(active[0].start, 1000);
        assert!(active[0].end.is_none());

        s.clock_out(id, 2000).unwrap();

        // Row is now closed.
        let active = s.active_clocks().unwrap();
        assert!(active.is_empty());

        let rows = s.clocks_for_task("task::1").unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].end, Some(2000));
    }

    #[test]
    fn multiple_concurrent_open_rows() {
        let s = mem();
        let id1 = s.clock_in("task::1", None, None, 100).unwrap();
        let id2 = s.clock_in("task::2", None, None, 200).unwrap();
        let id3 = s.clock_in("task::1", None, None, 300).unwrap();

        let active = s.active_clocks().unwrap();
        assert_eq!(active.len(), 3);

        // Close just task::1 rows.
        s.clock_out_task("task::1", 999).unwrap();

        let active = s.active_clocks().unwrap();
        assert_eq!(active.len(), 1);
        assert_eq!(active[0].id, id2);

        // The two task::1 rows are now closed.
        let rows = s.clocks_for_task("task::1").unwrap();
        assert_eq!(rows.len(), 2);
        for r in &rows {
            assert!(r.end.is_some());
        }

        // Close id2 explicitly.
        s.clock_out(id2, 1001).unwrap();
        assert!(s.active_clocks().unwrap().is_empty());

        // Suppress unused-variable warnings.
        let _ = (id1, id3);
    }

    #[test]
    fn active_clocks_filtering() {
        let s = mem();
        s.clock_in("t1", None, None, 1).unwrap();
        let id2 = s.clock_in("t2", None, None, 2).unwrap();
        s.clock_in("t3", None, None, 3).unwrap();

        // Close the middle one.
        s.clock_out(id2, 10).unwrap();

        let active = s.active_clocks().unwrap();
        assert_eq!(active.len(), 2);
        let ids: Vec<&str> = active.iter().map(|r| r.task_id.as_str()).collect();
        assert!(ids.contains(&"t1"));
        assert!(ids.contains(&"t3"));
        assert!(!ids.contains(&"t2"));
    }

    #[test]
    fn delete_clock() {
        let s = mem();
        let id = s.clock_in("task::1", None, None, 500).unwrap();
        assert_eq!(s.active_clocks().unwrap().len(), 1);
        s.delete_clock(id).unwrap();
        assert!(s.active_clocks().unwrap().is_empty());
        assert!(s.clocks_for_task("task::1").unwrap().is_empty());
    }

    #[test]
    fn add_interval_inserts_closed_row() {
        let s = mem();
        let id = s
            .add_interval("task::1", Some("/tmp/a.org"), Some("My task"), 1000, 2000)
            .unwrap();
        assert!(id > 0);

        // Must not appear in active clocks.
        assert!(s.active_clocks().unwrap().is_empty());

        let rows = s.clocks_for_task("task::1").unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].id, id);
        assert_eq!(rows[0].start, 1000);
        assert_eq!(rows[0].end, Some(2000));
        assert_eq!(rows[0].file.as_deref(), Some("/tmp/a.org"));
        assert_eq!(rows[0].title.as_deref(), Some("My task"));
    }

    #[test]
    fn add_interval_coexists_with_open_row() {
        let s = mem();
        // Open clock.
        let open_id = s.clock_in("task::1", None, None, 500).unwrap();
        // Closed interval for same task.
        s.add_interval("task::1", None, None, 100, 200).unwrap();

        let active = s.active_clocks().unwrap();
        assert_eq!(active.len(), 1);
        assert_eq!(active[0].id, open_id);

        let all = s.clocks_for_task("task::1").unwrap();
        assert_eq!(all.len(), 2);
    }

    // -------------------------------------------------------------------------
    // Habit completion tests (keyed by habit_id)
    // -------------------------------------------------------------------------

    #[test]
    fn add_completion_idempotency() {
        let s = mem();
        let inserted = s.add_completion("habit-uuid-1", 1000).unwrap();
        assert!(inserted);

        // Second call with same (habit_id, ts) must return false — not an error.
        let inserted_again = s.add_completion("habit-uuid-1", 1000).unwrap();
        assert!(!inserted_again);

        // Different ts on same habit still inserts.
        let second = s.add_completion("habit-uuid-1", 2000).unwrap();
        assert!(second);

        let completions = s.completions_for("habit-uuid-1").unwrap();
        assert_eq!(completions, vec![1000_i64, 2000_i64]);
    }

    #[test]
    fn remove_completion() {
        let s = mem();
        s.add_completion("hid-1", 10).unwrap();
        s.add_completion("hid-1", 20).unwrap();
        s.remove_completion("hid-1", 10).unwrap();
        let remaining = s.completions_for("hid-1").unwrap();
        assert_eq!(remaining, vec![20_i64]);
    }

    #[test]
    fn completions_for_returns_ascending() {
        let s = mem();
        s.add_completion("hid-1", 300).unwrap();
        s.add_completion("hid-1", 100).unwrap();
        s.add_completion("hid-1", 200).unwrap();
        let ts = s.completions_for("hid-1").unwrap();
        assert_eq!(ts, vec![100_i64, 200, 300]);
    }

    #[test]
    fn all_completions_bulk() {
        let s = mem();
        s.add_completion("uuid-a", 1).unwrap();
        s.add_completion("uuid-a", 2).unwrap();
        s.add_completion("uuid-b", 5).unwrap();

        let map = s.all_completions().unwrap();
        assert_eq!(map.len(), 2);
        assert_eq!(map["uuid-a"], vec![1_i64, 2]);
        assert_eq!(map["uuid-b"], vec![5_i64]);
    }

    #[test]
    fn all_completions_empty() {
        let s = mem();
        let map = s.all_completions().unwrap();
        assert!(map.is_empty());
    }

    // -------------------------------------------------------------------------
    // Habit definition CRUD tests
    // -------------------------------------------------------------------------

    fn sample_habit(id: &str) -> HabitRow {
        HabitRow {
            id: id.to_string(),
            title: "Daily exercise".to_string(),
            cadence_kind: "+".to_string(),
            cadence_value: 1,
            cadence_unit: "d".to_string(),
            cadence_max_value: None,
            cadence_max_unit: None,
            category: Some("health".to_string()),
            priority: Some("A".to_string()),
            tags: r#"["exercise","health"]"#.to_string(),
            notes: Some("30 min minimum".to_string()),
            anchor_date: Some("2026-01-01".to_string()),
            active: true,
            created_at: 1_700_000_000,
            reset_checklist_on_complete: false,
        }
    }

    #[test]
    fn habit_create_and_get() {
        let s = mem();
        let h = sample_habit("uuid-h1");
        s.create_habit(&h).unwrap();

        let got = s.get_habit("uuid-h1").unwrap().expect("should exist");
        assert_eq!(got, h);
    }

    #[test]
    fn get_habit_missing_returns_none() {
        let s = mem();
        assert!(s.get_habit("no-such-id").unwrap().is_none());
    }

    #[test]
    fn habit_list_active_filter() {
        let s = mem();
        let h1 = sample_habit("uuid-h1");
        let mut h2 = sample_habit("uuid-h2");
        h2.title = "Weekly review".to_string();
        h2.active = false;
        s.create_habit(&h1).unwrap();
        s.create_habit(&h2).unwrap();

        // Only active by default.
        let active = s.list_habits(false).unwrap();
        assert_eq!(active.len(), 1);
        assert_eq!(active[0].id, "uuid-h1");

        // All including inactive.
        let all = s.list_habits(true).unwrap();
        assert_eq!(all.len(), 2);
    }

    #[test]
    fn habit_update_full_upsert() {
        let s = mem();
        let h = sample_habit("uuid-h1");
        s.create_habit(&h).unwrap();

        let mut updated = h.clone();
        updated.title = "Morning run".to_string();
        updated.cadence_value = 2;
        s.update_habit(&updated).unwrap();

        let got = s.get_habit("uuid-h1").unwrap().unwrap();
        assert_eq!(got.title, "Morning run");
        assert_eq!(got.cadence_value, 2);
        // Other fields preserved.
        assert_eq!(got.cadence_unit, "d");
    }

    #[test]
    fn habit_delete_removes_row_and_completions() {
        let s = mem();
        let h = sample_habit("uuid-h1");
        s.create_habit(&h).unwrap();
        s.add_completion("uuid-h1", 1000).unwrap();
        s.add_completion("uuid-h1", 2000).unwrap();

        s.delete_habit("uuid-h1").unwrap();

        assert!(s.get_habit("uuid-h1").unwrap().is_none());
        assert!(s.completions_for("uuid-h1").unwrap().is_empty());
    }

    #[test]
    fn set_habit_active_toggle() {
        let s = mem();
        let h = sample_habit("uuid-h1");
        s.create_habit(&h).unwrap();
        assert!(h.active);

        s.set_habit_active("uuid-h1", false).unwrap();
        let got = s.get_habit("uuid-h1").unwrap().unwrap();
        assert!(!got.active);

        s.set_habit_active("uuid-h1", true).unwrap();
        let got = s.get_habit("uuid-h1").unwrap().unwrap();
        assert!(got.active);
    }

    #[test]
    fn habit_completions_keyed_by_habit_id() {
        let s = mem();
        let h1 = sample_habit("uuid-h1");
        let mut h2 = sample_habit("uuid-h2");
        h2.title = "Meditate".to_string();
        s.create_habit(&h1).unwrap();
        s.create_habit(&h2).unwrap();

        s.add_completion("uuid-h1", 100).unwrap();
        s.add_completion("uuid-h1", 200).unwrap();
        s.add_completion("uuid-h2", 300).unwrap();

        let c1 = s.completions_for("uuid-h1").unwrap();
        assert_eq!(c1, vec![100_i64, 200]);

        let c2 = s.completions_for("uuid-h2").unwrap();
        assert_eq!(c2, vec![300_i64]);

        let map = s.all_completions().unwrap();
        assert_eq!(map["uuid-h1"], vec![100_i64, 200]);
        assert_eq!(map["uuid-h2"], vec![300_i64]);
    }

    #[test]
    fn habit_optional_fields_roundtrip() {
        let s = mem();
        // All optional fields absent.
        let h = HabitRow {
            id: "uuid-minimal".to_string(),
            title: "Stretch".to_string(),
            cadence_kind: ".+".to_string(),
            cadence_value: 1,
            cadence_unit: "d".to_string(),
            cadence_max_value: None,
            cadence_max_unit: None,
            category: None,
            priority: None,
            tags: "[]".to_string(),
            notes: None,
            anchor_date: None,
            active: true,
            created_at: 1_700_000_001,
            reset_checklist_on_complete: false,
        };
        s.create_habit(&h).unwrap();
        let got = s.get_habit("uuid-minimal").unwrap().unwrap();
        assert_eq!(got, h);
    }

    #[test]
    fn habit_max_cadence_roundtrip() {
        let s = mem();
        let h = HabitRow {
            id: "uuid-range".to_string(),
            title: "Walk".to_string(),
            cadence_kind: ".+".to_string(),
            cadence_value: 1,
            cadence_unit: "d".to_string(),
            cadence_max_value: Some(3),
            cadence_max_unit: Some("d".to_string()),
            category: None,
            priority: None,
            tags: "[]".to_string(),
            notes: None,
            anchor_date: None,
            active: true,
            created_at: 1_700_000_002,
            reset_checklist_on_complete: false,
        };
        s.create_habit(&h).unwrap();
        let got = s.get_habit("uuid-range").unwrap().unwrap();
        assert_eq!(got.cadence_max_value, Some(3));
        assert_eq!(got.cadence_max_unit.as_deref(), Some("d"));
    }

    /// Verify the version-2 migration: if a database contains the old
    /// `habit_completion` schema (with `task_id`), opening it via Store
    /// drops and recreates the table with `habit_id`.
    #[test]
    fn migration_v1_habit_completion_rekey() {
        use std::sync::atomic::{AtomicUsize, Ordering};
        static N: AtomicUsize = AtomicUsize::new(0);
        let n = N.fetch_add(1, Ordering::SeqCst);
        let dir =
            std::env::temp_dir().join(format!("eavd-migration-test-{}-{}", std::process::id(), n));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("data.sqlite");

        // Simulate a version-1 DB with old schema and a row in habit_completion.
        {
            let conn = Connection::open(&path).unwrap();
            conn.execute_batch(
                "CREATE TABLE clock (
                    id INTEGER PRIMARY KEY, task_id TEXT NOT NULL,
                    file TEXT, title TEXT, start INTEGER NOT NULL,
                    end INTEGER, note TEXT
                );
                CREATE TABLE habit_completion (
                    id INTEGER PRIMARY KEY,
                    task_id TEXT NOT NULL,
                    ts INTEGER NOT NULL,
                    UNIQUE(task_id, ts)
                );
                INSERT INTO habit_completion (task_id, ts) VALUES ('old-task-id', 42);",
            )
            .unwrap();
            // Leave user_version at 0 (default) to trigger the migration.
        }

        // Opening via Store must succeed and apply the migration.
        let s = Store::open(&path).unwrap();

        // The new schema uses habit_id; old rows were dropped. No panic.
        let map = s.all_completions().unwrap();
        assert!(
            map.is_empty(),
            "old task_id rows should be gone after re-key"
        );

        // New completions work with the new schema.
        s.add_completion("new-habit-uuid", 99).unwrap();
        assert_eq!(s.completions_for("new-habit-uuid").unwrap(), vec![99_i64]);

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Verify that a version-2 database (missing reset_checklist_on_complete)
    /// is upgraded additively: the column is added with DEFAULT 0, and an
    /// existing habit row survives the migration with the field set to false.
    #[test]
    fn migration_v2_add_reset_checklist_column() {
        use std::sync::atomic::{AtomicUsize, Ordering};
        static N: AtomicUsize = AtomicUsize::new(0);
        let n = N.fetch_add(1, Ordering::SeqCst);
        let dir = std::env::temp_dir().join(format!(
            "eavd-migration-v3-test-{}-{}",
            std::process::id(),
            n
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("data.sqlite");

        // Simulate a version-2 DB: correct habit_id schema but no reset column.
        {
            let conn = Connection::open(&path).unwrap();
            conn.execute_batch(
                "CREATE TABLE habit (
                    id TEXT PRIMARY KEY,
                    title TEXT NOT NULL,
                    cadence_kind TEXT NOT NULL,
                    cadence_value INTEGER NOT NULL,
                    cadence_unit TEXT NOT NULL,
                    cadence_max_value INTEGER,
                    cadence_max_unit TEXT,
                    category TEXT,
                    priority TEXT,
                    tags TEXT,
                    notes TEXT,
                    anchor_date TEXT,
                    active INTEGER NOT NULL DEFAULT 1,
                    created_at INTEGER NOT NULL
                );
                CREATE TABLE habit_completion (
                    id INTEGER PRIMARY KEY,
                    habit_id TEXT NOT NULL,
                    ts INTEGER NOT NULL,
                    UNIQUE(habit_id, ts)
                );
                CREATE TABLE clock (
                    id INTEGER PRIMARY KEY, task_id TEXT NOT NULL,
                    file TEXT, title TEXT, start INTEGER NOT NULL,
                    end INTEGER, note TEXT
                );
                INSERT INTO habit (id, title, cadence_kind, cadence_value, cadence_unit, tags, active, created_at)
                VALUES ('existing-habit', 'Run', '+', 1, 'd', '[]', 1, 1700000000);",
            )
            .unwrap();
            conn.pragma_update(None, "user_version", 2i32).unwrap();
        }

        // Opening via Store must add the column without wiping existing data.
        let s = Store::open(&path).unwrap();

        let got = s
            .get_habit("existing-habit")
            .unwrap()
            .expect("existing habit must survive migration");
        assert_eq!(got.title, "Run");
        // Default is false (was 0 in the DB).
        assert!(!got.reset_checklist_on_complete);

        // A new habit with the flag set round-trips correctly.
        let mut new_h = sample_habit("new-habit");
        new_h.reset_checklist_on_complete = true;
        s.create_habit(&new_h).unwrap();
        let got_new = s.get_habit("new-habit").unwrap().unwrap();
        assert!(got_new.reset_checklist_on_complete);

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn open_persistent_store() {
        use std::sync::atomic::{AtomicUsize, Ordering};
        static N: AtomicUsize = AtomicUsize::new(0);
        let n = N.fetch_add(1, Ordering::SeqCst);
        let dir =
            std::env::temp_dir().join(format!("eavd-store-test-{}-{}", std::process::id(), n));
        let _ = std::fs::remove_dir_all(&dir);

        let path = dir.join("data.sqlite");
        {
            let s = Store::open(&path).unwrap();
            s.clock_in("t", None, None, 42).unwrap();
            let h = sample_habit("uuid-persist");
            s.create_habit(&h).unwrap();
            s.add_completion("uuid-persist", 99).unwrap();
        }
        // Reopen and verify data survived.
        {
            let s = Store::open(&path).unwrap();
            assert_eq!(s.active_clocks().unwrap().len(), 1);
            let habits = s.list_habits(false).unwrap();
            assert_eq!(habits.len(), 1);
            assert_eq!(habits[0].id, "uuid-persist");
            let map = s.all_completions().unwrap();
            assert_eq!(map["uuid-persist"], vec![99_i64]);
        }
        let _ = std::fs::remove_dir_all(&dir);
    }
}
