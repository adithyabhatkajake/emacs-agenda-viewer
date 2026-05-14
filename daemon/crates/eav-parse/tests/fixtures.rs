//! Fixture-driven parity tests, grounded in org-element.el.
//!
//! Reference: `org-element-timestamp-parser` in
//! `~/.config/emacs/.local/straight/repos/org/lisp/org-element.el:4385` (org
//! mode 9.7+). Quoted invariants we encode here:
//!
//!   * `:type` is `'diary` | `'active-range` | `'active` | `'inactive-range`
//!     | `'inactive`. Range only when there is a date-end OR a time-range.
//!   * `:range-type` is `'daterange` (date-end) | `'timerange` (time-range
//!     without date-end) | `nil`.
//!   * Repeater syntax: `(or "+" "++" ".+")(digits)([hdwmy])`.
//!     Maps to `'cumulate` / `'catch-up` / `'restart` and unit
//!     `'hour/day/week/month/year` (org-element.el:4438-4469).
//!   * Warning syntax: `(-)?-(\d+)([hdwmy])`. Two leading dashes ⇒
//!     `'first` (only first occurrence); single leading dash ⇒ `'all`.
//!     (org-element.el:4470-4478).
//!   * `:year-end`/`:month-end`/`:day-end` always populated; default to the
//!     start values (org-element.el:4493-4498).
//!
//! The fixtures live in `daemon/tests/fixtures/`.

use eav_core::OrgTask;
use eav_parse::extract_tasks_from_source;
use std::fs;
use std::path::{Path, PathBuf};

fn fixture_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("..")
        .join("tests")
        .join("fixtures")
}

fn load(fname: &str) -> (Vec<OrgTask>, String) {
    let path = fixture_dir().join(fname);
    let source = fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {path:?}: {e}"));
    let (tasks, _meta) = extract_tasks_from_source(&source, &path);
    (tasks, source)
}

fn by_title<'a>(tasks: &'a [OrgTask], title: &str) -> &'a OrgTask {
    tasks.iter().find(|t| t.title == title).unwrap_or_else(|| {
        panic!(
            "no task titled {title:?}; got {:?}",
            tasks.iter().map(|t| &t.title).collect::<Vec<_>>()
        )
    })
}

// -----------------------------------------------------------------------------
// timestamps.org
// -----------------------------------------------------------------------------

#[test]
fn ts_simple_active_has_start_and_default_end() {
    let (tasks, _) = load("timestamps.org");
    let t = by_title(&tasks, "simple-active");
    let s = t.scheduled.as_ref().unwrap();
    assert_eq!(s.ts_type.as_deref(), Some("active"));
    assert_eq!(s.start.year, 2026);
    assert_eq!(s.start.month, 5);
    assert_eq!(s.start.day, 7);
    assert!(s.start.hour.is_none());
    // Per org-element.el:4493-4498, end mirrors start when no date-end.
    let e = s.end.as_ref().unwrap();
    assert_eq!((e.year, e.month, e.day), (2026, 5, 7));
}

#[test]
fn ts_active_with_time_carries_minutes() {
    let (tasks, _) = load("timestamps.org");
    let t = by_title(&tasks, "active-with-time");
    let s = t.scheduled.as_ref().unwrap();
    assert_eq!(s.start.hour, Some(10));
    assert_eq!(s.start.minute, Some(0));
    assert_eq!(s.range_type, None);
}

#[test]
fn ts_time_range_marks_timerange() {
    let (tasks, _) = load("timestamps.org");
    let t = by_title(&tasks, "time-range");
    let s = t.scheduled.as_ref().unwrap();
    // Per org-element.el:4434-4437: range-type is `'timerange` when there's a
    // time-range but no separate date-end.
    assert_eq!(s.range_type.as_deref(), Some("timerange"));
    let e = s.end.as_ref().unwrap();
    assert_eq!(e.hour, Some(12));
    assert_eq!(e.year, 2026);
    assert_eq!(e.day, 7);
}

#[test]
fn ts_date_range_marks_daterange_and_active_range() {
    let (tasks, _) = load("timestamps.org");
    let t = by_title(&tasks, "date-range");
    let s = t.scheduled.as_ref().unwrap();
    // Per org-element.el:4429-4437.
    assert_eq!(s.ts_type.as_deref(), Some("active-range"));
    assert_eq!(s.range_type.as_deref(), Some("daterange"));
    let e = s.end.as_ref().unwrap();
    assert_eq!((e.year, e.month, e.day), (2026, 5, 10));
}

#[test]
fn ts_inactive_in_body_is_not_active() {
    let (tasks, _) = load("timestamps.org");
    let t = by_title(&tasks, "inactive-in-body");
    // Body-active extraction filters out [...] inactive timestamps.
    assert!(t.active_timestamps.as_ref().map_or(true, |v| v.is_empty()));
}

#[test]
fn ts_active_in_body_extracts_both() {
    let (tasks, _) = load("timestamps.org");
    let t = by_title(&tasks, "active-in-body");
    let stamps = t
        .active_timestamps
        .as_ref()
        .expect("body active timestamps missing");
    assert_eq!(stamps.len(), 2);
    assert_eq!(stamps[0].start.month, 6);
    assert_eq!(stamps[1].start.month, 7);
    assert_eq!(stamps[1].start.hour, Some(9));
}

#[test]
fn ts_repeater_cumulate_plus() {
    let (tasks, _) = load("timestamps.org");
    let t = by_title(&tasks, "repeater-cumulate");
    let r = t.scheduled.as_ref().unwrap().repeater.as_ref().unwrap();
    // org-element.el:4453-4456: "+" → cumulate.
    assert_eq!(r.kind, "+");
    assert_eq!(r.value, 1);
    assert_eq!(r.unit, "d");
}

#[test]
fn ts_repeater_catch_up_double_plus() {
    let (tasks, _) = load("timestamps.org");
    let t = by_title(&tasks, "repeater-catchup");
    let r = t.scheduled.as_ref().unwrap().repeater.as_ref().unwrap();
    assert_eq!(r.kind, "++");
    assert_eq!(r.value, 1);
    assert_eq!(r.unit, "w");
}

#[test]
fn ts_repeater_restart_dot_plus() {
    let (tasks, _) = load("timestamps.org");
    let t = by_title(&tasks, "repeater-restart");
    let r = t.scheduled.as_ref().unwrap().repeater.as_ref().unwrap();
    assert_eq!(r.kind, ".+");
    assert_eq!(r.unit, "m");
}

#[test]
fn ts_warning_only() {
    let (tasks, _) = load("timestamps.org");
    let t = by_title(&tasks, "warning-only");
    let d = t.deadline.as_ref().unwrap();
    let w = d.warning.as_ref().unwrap();
    // Single dash before digits: `'all` (org-element.el:4470-4478).
    assert_eq!(w.value, 3);
    assert_eq!(w.unit, "d");
    assert!(d.repeater.is_none());
}

#[test]
fn ts_repeater_and_warning() {
    let (tasks, _) = load("timestamps.org");
    let t = by_title(&tasks, "repeater-and-warning");
    let d = t.deadline.as_ref().unwrap();
    let r = d.repeater.as_ref().unwrap();
    let w = d.warning.as_ref().unwrap();
    assert_eq!((r.kind.as_str(), r.value, r.unit.as_str()), ("+", 1, "w"));
    assert_eq!((w.value, w.unit.as_str()), (1, "d"));
}

// -----------------------------------------------------------------------------
// keywords.org
// -----------------------------------------------------------------------------

#[test]
fn keyword_file_uses_local_sequence() {
    let (tasks, _) = load("keywords.org");
    let titles: Vec<&str> = tasks.iter().map(|t| t.title.as_str()).collect();
    // The file declares `NEXT/WAITING/DONE/CANCELLED`; "TODO" is not in scope.
    assert!(titles.contains(&"first task"));
    assert!(titles.contains(&"blocked task"));
    assert!(titles.contains(&"wrapped up"));
    assert!(titles.contains(&"dropped"));
    assert!(
        !titles.contains(&"not-a-keyword-here"),
        "TODO is not configured in this file"
    );
    assert!(
        !titles.contains(&"plain heading"),
        "no keyword ⇒ not a task"
    );
}

#[test]
fn keyword_done_states_filter_correctly() {
    use eav_parse::FileMeta;
    let path = fixture_dir().join("keywords.org");
    let source = std::fs::read_to_string(&path).unwrap();
    let meta = FileMeta::from_source(&source, &path);
    assert!(meta.is_done_keyword("DONE"));
    assert!(meta.is_done_keyword("CANCELLED"));
    assert!(!meta.is_done_keyword("NEXT"));
    assert!(!meta.is_done_keyword("WAITING"));
    // "TODO" is not configured in this file.
    assert!(!meta.is_task_keyword("TODO"));
}

// -----------------------------------------------------------------------------
// tags_and_categories.org
// -----------------------------------------------------------------------------

#[test]
fn tag_inheritance_and_category_override() {
    let (tasks, _) = load("tags_and_categories.org");
    let leaf = by_title(&tasks, "leaf-task");
    // Local tag stays on the heading.
    assert_eq!(leaf.tags, vec!["leaf"]);
    // Inherited tags are FILETAGS ∪ ancestor-local, in the order we walked.
    assert!(leaf.inherited_tags.contains(&"ft1".to_string()));
    assert!(leaf.inherited_tags.contains(&"ft2".to_string()));
    assert!(leaf.inherited_tags.contains(&"local1".to_string()));
    assert!(leaf.inherited_tags.contains(&"local2".to_string()));
    // Category resolution: nearest ancestor with :CATEGORY: drawer property
    // wins over #+CATEGORY.
    assert_eq!(leaf.category, "MidCategory");

    let root = by_title(&tasks, "root-task");
    assert_eq!(root.category, "ProjectRoot");
    assert_eq!(root.id, "root-id");

    let sibling = by_title(&tasks, "sibling");
    // No ancestor with :CATEGORY: → falls back to #+CATEGORY:.
    assert_eq!(sibling.category, "ProjectRoot");
}

// -----------------------------------------------------------------------------
// properties.org
// -----------------------------------------------------------------------------

#[test]
fn properties_surface_id_and_effort() {
    // Verified against `org-entry-properties nil 'standard`: keys arrive
    // upcased, with CATEGORY/ID/EFFORT stripped because we surface those on
    // the task struct itself.
    let (tasks, _) = load("properties.org");
    let t = by_title(&tasks, "with-effort");
    assert_eq!(t.id, "task-id-001");
    assert_eq!(t.effort.as_deref(), Some("0:30"));
    let props = t.properties.as_ref().unwrap();
    assert_eq!(
        props.get("CUSTOM_KEY").map(|s| s.as_str()),
        Some("custom-value")
    );
    assert!(props.get("ID").is_none());
    assert!(props.get("EFFORT").is_none());
    assert!(props.get("CATEGORY").is_none());
}

#[test]
fn properties_keys_uppercased_drawer_wins() {
    // `org-entry-properties` upcases keys, and `#+PROPERTY:` defaults are NOT
    // folded into per-heading output (verified via `emacsclient --eval`).
    let (tasks, _) = load("properties.org");
    let t = by_title(&tasks, "inherits-default");
    let props = t.properties.as_ref().unwrap();
    // Drawer key was `LocalKey`; org returns it as `LOCALKEY`.
    assert_eq!(
        props.get("LOCALKEY").map(|s| s.as_str()),
        Some("localValue")
    );
    // The file-level `#+PROPERTY: DefaultKey defaultValue` does NOT propagate
    // here — Emacs's standard properties view drops it.
    assert!(
        props.get("DEFAULTKEY").is_none() && props.get("DefaultKey").is_none(),
        "file-level #+PROPERTY: must not appear on per-heading output"
    );
}

#[test]
fn properties_no_drawer_means_no_properties_field() {
    let (tasks, _) = load("properties.org");
    let t = by_title(&tasks, "no-properties");
    // Without a :PROPERTIES: drawer there are no custom properties to emit.
    assert!(t.properties.is_none() || t.properties.as_ref().unwrap().is_empty());
}

// -----------------------------------------------------------------------------
// diary.org
// -----------------------------------------------------------------------------

#[test]
fn diary_sexp_in_body_is_preserved_in_notes() {
    let (tasks, _) = load("diary.org");
    let t = by_title(&tasks, "anniversary helper");
    // The body line `%%(diary-anniversary 1990 1 1) Birthday` must survive
    // verbatim so the agenda evaluator can detect the sexp marker.
    let body = t.notes.as_deref().unwrap_or("");
    assert!(body.contains("%%(diary-anniversary"));
}

// -----------------------------------------------------------------------------
// calendar.org
// -----------------------------------------------------------------------------

#[test]
fn calendar_non_todo_with_title_timestamp_still_indexed() {
    let (tasks, source) = load("calendar.org");
    // "Standup" has a body-line active timestamp — we treat the heading title
    // as part of the title text, but org-mode also indexes a heading whose
    // title carries an active timestamp. The extractor produces a record so
    // the agenda can surface it.
    let standup = tasks.iter().find(|t| t.title.contains("Standup"));
    assert!(
        standup.is_some(),
        "calendar headings (no TODO state, but with active timestamp) must \
         still be extractable for agenda; got {:?}",
        tasks.iter().map(|t| &t.title).collect::<Vec<_>>()
    );
    // Sanity: the source file is non-empty (guards against silent fixture loss)
    assert!(!source.is_empty());
}

// -----------------------------------------------------------------------------
// Whole-file invariants
// -----------------------------------------------------------------------------

#[test]
fn every_fixture_file_parses_without_panic() {
    let dir = fixture_dir();
    let mut count = 0;
    for entry in fs::read_dir(&dir).expect("read fixtures") {
        let path = entry.unwrap().path();
        if path.extension().and_then(|e| e.to_str()) != Some("org") {
            continue;
        }
        let source = fs::read_to_string(&path).unwrap();
        let _ = extract_tasks_from_source(&source, &path);
        count += 1;
    }
    assert!(count >= 5, "expected ≥5 fixtures, got {count}");
}

#[test]
fn pos_is_one_based_character_index() {
    // Org's `point` is 1-based and counts characters, not bytes. With a UTF-8
    // emoji in the title, byte offset and char count diverge; verify the pos
    // we emit aligns with where Emacs would land.
    let path = fixture_dir().join("calendar.org");
    let source = fs::read_to_string(&path).unwrap();
    let (tasks, _) = extract_tasks_from_source(&source, &path);
    for t in &tasks {
        // pos must point at a `*` in the source (heading marker).
        let p = t.pos as usize;
        let prefix: String = source.chars().take(p - 1).collect();
        let rest: String = source.chars().skip(p - 1).collect();
        assert!(
            rest.starts_with('*'),
            "pos {p} for {title:?}: prefix ends {prefix_tail:?}, rest starts {rest_head:?}",
            title = t.title,
            prefix_tail = prefix
                .chars()
                .rev()
                .take(20)
                .collect::<String>()
                .chars()
                .rev()
                .collect::<String>(),
            rest_head = rest.chars().take(40).collect::<String>()
        );
    }
}

// -----------------------------------------------------------------------------
// repeat_deadline.org — orgize alpha rejects `+Nu/Mu`; we fall back parse.
// Reference: org-element.el:4445-4448 (`:repeater-deadline-value/unit`).
// -----------------------------------------------------------------------------

#[test]
fn deadline_with_repeater_deadline_suffix_still_parses() {
    let (tasks, _) = load("repeat_deadline.org");
    let t = by_title(&tasks, "Clean Bathroom");
    let d = t
        .deadline
        .as_ref()
        .expect("deadline must parse via fallback");
    assert_eq!(d.start.year, 2026);
    assert_eq!(d.start.month, 5);
    let r = d.repeater.as_ref().unwrap();
    assert_eq!(r.kind, "+");
    assert_eq!(r.value, 1);
    assert_eq!(r.unit, "w");
    let w = d.warning.as_ref().unwrap();
    assert_eq!((w.value, w.unit.as_str()), (0, "d"));
    // The deadline-repeater suffix is preserved in `raw` for round-trip.
    assert!(d.raw.contains("/2w"));
}

#[test]
fn properties_drawer_after_unparseable_planning_line() {
    let (tasks, _) = load("repeat_deadline.org");
    let t = by_title(&tasks, "Clean Bathroom");
    let props = t.properties.as_ref().expect("properties via fallback");
    assert_eq!(
        props.get("LAST_REPEAT").map(|s| s.as_str()),
        Some("[2026-04-30 Thu 20:32]")
    );
    assert_eq!(props.get("STYLE").map(|s| s.as_str()), Some("habit"));
    // EFFORT is upcased and stripped from custom properties (it's surfaced
    // on `task.effort`).
    assert!(props.get("EFFORT").is_none());
    assert_eq!(t.effort.as_deref(), Some("0:15"));
}

#[test]
fn scheduled_with_repeater_deadline_suffix() {
    let (tasks, _) = load("repeat_deadline.org");
    let t = by_title(&tasks, "Read Papers");
    let s = t.scheduled.as_ref().unwrap();
    let r = s.repeater.as_ref().unwrap();
    assert_eq!((r.kind.as_str(), r.value, r.unit.as_str()), ("+", 2, "m"));
    assert!(s.raw.contains("/4m"));

    let t = by_title(&tasks, "Catch-up monthly");
    let s = t.scheduled.as_ref().unwrap();
    let r = s.repeater.as_ref().unwrap();
    assert_eq!(r.kind, "++");
}
