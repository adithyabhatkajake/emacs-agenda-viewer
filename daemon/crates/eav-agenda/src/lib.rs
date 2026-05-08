//! Agenda-day / agenda-range evaluator.
//!
//! Given an in-memory task index and a target date, produce the list of
//! `AgendaEntry` records that org-agenda would surface — covering scheduled,
//! deadline (and within-warning-window upcoming-deadline), plain active
//! timestamps in the body, and detection of sexp/diary entries that need
//! Emacs proxying.
//!
//! Out of scope (per the plan): `org-agenda-skip-functions`, agenda custom
//! commands, habit consistency tracking. Sexp evaluation defers to Emacs.

pub mod timestamp;

pub use timestamp::{
    next_occurrence_on_or_after, occurs_on, time_of_day, ts_date, warning_days,
};

use chrono::NaiveDate;
use eav_core::{agenda_type, AgendaEntry, AgendaLevel, OrgTask, OrgTimestamp};

/// Output of `evaluate_day`. Sexp-bearing files are reported separately so the
/// HTTP layer can decide whether to proxy through the bridge.
#[derive(Debug, Clone, Default)]
pub struct DayEvaluation {
    pub entries: Vec<AgendaEntry>,
    /// Files that contain a `%%(...)` form anywhere in any task body. The
    /// caller should ask Emacs for sexp entries on this date and merge.
    pub needs_sexp_proxy: Vec<String>,
}

/// Configuration that influences agenda emission. Mirrors the relevant fields
/// of `eav-get-config`.
#[derive(Debug, Clone, Copy)]
pub struct AgendaConfig {
    pub deadline_warning_days: i32,
}

impl Default for AgendaConfig {
    fn default() -> Self {
        Self {
            deadline_warning_days: 14,
        }
    }
}

/// Build the agenda for TARGET (relative to TODAY for repeater context).
/// `tasks` is a snapshot of all tasks the daemon knows about.
pub fn evaluate_day(
    tasks: &[OrgTask],
    target: NaiveDate,
    today: NaiveDate,
    config: &AgendaConfig,
) -> DayEvaluation {
    let mut out = DayEvaluation::default();
    let display_date = format_ymd(target);
    let mut sexp_files = std::collections::BTreeSet::<String>::new();

    for task in tasks {
        // Sexp detection.
        if let Some(notes) = task.notes.as_deref() {
            if has_sexp_marker(notes) {
                sexp_files.insert(task.file.clone());
            }
        }

        // 1. SCHEDULED — repeater-aware.
        //
        // `org-agenda-skip-scheduled-if-done` (default-on in this user's
        // config; matches the express output) suppresses the scheduled entry
        // for tasks already in a done state.
        if let Some(sched) = &task.scheduled {
            let is_done_task = task
                .todo_state
                .as_deref()
                .map(is_done_state)
                .unwrap_or(false);
            if !is_done_task && occurs_on(sched, target, today) {
                out.entries
                    .push(make_entry(task, target, sched, agenda_type::SCHEDULED, &display_date, "Scheduled:"));
            }
        }

        // 2. DEADLINE.
        if let Some(deadline) = &task.deadline {
            if occurs_on(deadline, target, today) {
                out.entries.push(make_entry(
                    task,
                    target,
                    deadline,
                    agenda_type::DEADLINE,
                    &display_date,
                    "Deadline:",
                ));
            } else if target == today {
                // Per org-agenda-get-deadlines (org-agenda.el:6423-6428):
                //   ((not today?) (throw :skip nil))
                // Upcoming-deadline entries only appear when we're querying
                // *today's* agenda; querying an arbitrary future day shows
                // deadlines that fall ON that day, not deadlines previewed
                // ahead of it.
                if let Some(actual) = next_occurrence_on_or_after(deadline, target, today) {
                    let warn = warning_days(deadline.warning.as_ref(), config.deadline_warning_days);
                    let delta = actual.signed_duration_since(target).num_days();
                    let is_done_task = task
                        .todo_state
                        .as_deref()
                        .map(is_done_state)
                        .unwrap_or(false);
                    // org-agenda-get-deadlines:6430 — `(when (> diff warning-days) skip)`
                    // i.e. include while diff <= warning-days.
                    if !is_done_task && delta > 0 && delta <= warn as i64 {
                        let extra = format!("In {delta} d.:");
                        out.entries.push(make_entry_with_extra(
                            task,
                            actual,
                            deadline,
                            agenda_type::UPCOMING_DEADLINE,
                            &display_date,
                            &extra,
                        ));
                    }
                }
            }
        }

        // 3. Plain active timestamps in the body / title.
        //
        // Per `org-agenda-get-blocks` (org-agenda.el:6772-6900) and
        // `org-agenda-get-timestamps` (org-agenda.el:5803): a date-range
        // (`<a>--<b>` with start_day != end_day) emits ONE `block` entry on
        // every day in `[a, b]` inclusive, with `extra` = `(N/M):` where N is
        // the position in the range. Single-day timestamps emit a
        // `timestamp` entry on their day (and only their day).
        if let Some(stamps) = &task.active_timestamps {
            for ts in stamps {
                let start_d = NaiveDate::from_ymd_opt(
                    ts.start.year,
                    ts.start.month,
                    ts.start.day,
                );
                let end_d = ts
                    .end
                    .as_ref()
                    .and_then(|e| NaiveDate::from_ymd_opt(e.year, e.month, e.day));
                let is_range = matches!((start_d, end_d), (Some(s), Some(e)) if s != e);

                if is_range {
                    let s = start_d.unwrap();
                    let e = end_d.unwrap();
                    if target >= s && target <= e {
                        let n = (target - s).num_days() + 1;
                        let m = (e - s).num_days() + 1;
                        let extra = format!("({n}/{m}):");
                        out.entries.push(make_entry(
                            task,
                            target,
                            ts,
                            agenda_type::BLOCK,
                            &display_date,
                            &extra,
                        ));
                    }
                } else if body_timestamp_lands_on(ts, target, today) {
                    out.entries.push(make_entry(
                        task,
                        target,
                        ts,
                        agenda_type::TIMESTAMP,
                        &display_date,
                        "",
                    ));
                }
            }
        }
    }

    // Stable sort: time-of-day, then category, then priority — matching
    // org-agenda's default `org-agenda-sorting-strategy`.
    out.entries.sort_by(|a, b| {
        let aa = a.time_of_day.as_deref().unwrap_or("");
        let bb = b.time_of_day.as_deref().unwrap_or("");
        aa.cmp(bb)
            .then_with(|| a.category.cmp(&b.category))
            .then_with(|| {
                priority_rank(a.priority.as_deref())
                    .cmp(&priority_rank(b.priority.as_deref()))
            })
            .then_with(|| a.title.cmp(&b.title))
    });

    out.needs_sexp_proxy = sexp_files.into_iter().collect();
    out
}

/// Range query: day-by-day across [start, end] inclusive.
pub fn evaluate_range(
    tasks: &[OrgTask],
    start: NaiveDate,
    end: NaiveDate,
    today: NaiveDate,
    config: &AgendaConfig,
) -> DayEvaluation {
    let mut all = DayEvaluation::default();
    let mut cur = start;
    while cur <= end {
        let day = evaluate_day(tasks, cur, today, config);
        all.entries.extend(day.entries);
        for f in day.needs_sexp_proxy {
            if !all.needs_sexp_proxy.contains(&f) {
                all.needs_sexp_proxy.push(f);
            }
        }
        cur = match cur.succ_opt() {
            Some(n) => n,
            None => break,
        };
    }
    all
}

fn make_entry(
    task: &OrgTask,
    target: NaiveDate,
    ts: &OrgTimestamp,
    agenda_type: &str,
    display_date: &str,
    extra: &str,
) -> AgendaEntry {
    let extra = if extra.is_empty() { None } else { Some(extra.to_string()) };
    let display_date = display_date.to_string();
    let level = AgendaLevel::Spaces(" ".repeat(task.level as usize));
    AgendaEntry {
        id: task.id.clone(),
        title: task.title.clone(),
        agenda_type: agenda_type.to_string(),
        todo_state: task.todo_state.clone(),
        priority: task.priority.clone(),
        tags: task.tags.clone(),
        inherited_tags: task.inherited_tags.clone(),
        scheduled: task.scheduled.clone(),
        deadline: task.deadline.clone(),
        category: task.category.clone(),
        level,
        file: task.file.clone(),
        pos: task.pos,
        effort: task.effort.clone(),
        warntime: ts
            .warning
            .as_ref()
            .map(|w| format!("-{}{}", w.value, w.unit)),
        time_of_day: time_of_day(ts),
        extra,
        ts_date: Some(format_ymd(target)),
        display_date: Some(display_date),
    }
}

fn make_entry_with_extra(
    task: &OrgTask,
    occurrence: NaiveDate,
    ts: &OrgTimestamp,
    agenda_type: &str,
    display_date: &str,
    extra: &str,
) -> AgendaEntry {
    AgendaEntry {
        ts_date: Some(format_ymd(occurrence)),
        ..make_entry(task, occurrence, ts, agenda_type, display_date, extra)
    }
}

/// True if a body active timestamp emits on TARGET. Mirrors the Express
/// regex behaviour: `org-agenda-get-timestamps` (org-agenda.el:5825-5834)
/// builds a regex that catches either today's literal `<YYYY-MM-DD` prefix
/// OR a repeater pattern `<...+Nu>` *with no trailing characters before
/// `>`*. So a repeating timestamp like `<2026-05-13 Wed ++1w -0d>` (warning
/// after repeater) only matches on its base date — the repeater isn't
/// advanced by org's body-timestamp scanner.
fn body_timestamp_lands_on(ts: &OrgTimestamp, target: NaiveDate, today: NaiveDate) -> bool {
    let Some(base) = NaiveDate::from_ymd_opt(ts.start.year, ts.start.month, ts.start.day) else {
        return false;
    };
    if base == target {
        return true;
    }
    // No repeater → no further advancement.
    let Some(_rep) = ts.repeater.as_ref() else {
        return false;
    };
    // A trailing warning suppresses the repeater regex match (Express
    // emits only on the base date in that case).
    if ts.warning.is_some() {
        return false;
    }
    occurs_on(ts, target, today)
}

fn priority_rank(p: Option<&str>) -> i32 {
    match p {
        Some(s) if !s.is_empty() => {
            let c = s.chars().next().unwrap();
            c as i32
        }
        _ => 1000,
    }
}

/// True if STATE is a "done" keyword. Mirrors org's documented set
/// (`org-done-keywords`); we extend it with `KILL`/`CANCELLED` because the
/// user's config emits those as terminal states, and `org-agenda-skip-...`
/// uses the same set the file declares. Without per-task file-meta wiring
/// (deferred), we use a static superset matching the project's TODO config.
fn is_done_state(state: &str) -> bool {
    matches!(
        state.to_uppercase().as_str(),
        "DONE" | "KILL" | "CANCELLED" | "CANCELED"
    )
}

fn has_sexp_marker(text: &str) -> bool {
    text.lines().any(|l| l.trim_start().starts_with("%%("))
}

fn format_ymd(d: NaiveDate) -> String {
    d.format("%Y-%m-%d").to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use eav_core::{OrgTimestamp, OrgTimestampComponent, Repeater};

    fn ts(year: i32, month: u32, day: u32) -> OrgTimestamp {
        OrgTimestamp {
            raw: format!("<{year:04}-{month:02}-{day:02}>"),
            date: format!("<{year:04}-{month:02}-{day:02}>"),
            ts_type: Some("active".into()),
            range_type: None,
            start: OrgTimestampComponent {
                year,
                month,
                day,
                hour: None,
                minute: None,
            },
            end: None,
            repeater: None,
            warning: None,
        }
    }

    fn task(id: &str, title: &str) -> OrgTask {
        OrgTask {
            id: id.into(),
            title: title.into(),
            todo_state: Some("TODO".into()),
            priority: None,
            tags: vec![],
            inherited_tags: vec![],
            scheduled: None,
            deadline: None,
            closed: None,
            category: "Inbox".into(),
            level: 1,
            file: "/tmp/x.org".into(),
            pos: 1,
            parent_id: None,
            effort: None,
            notes: None,
            active_timestamps: None,
            properties: None,
        }
    }

    #[test]
    fn scheduled_lands_on_target() {
        let mut t = task("a", "x");
        t.scheduled = Some(ts(2026, 5, 7));
        let day = evaluate_day(
            &[t],
            NaiveDate::from_ymd_opt(2026, 5, 7).unwrap(),
            NaiveDate::from_ymd_opt(2026, 5, 7).unwrap(),
            &AgendaConfig::default(),
        );
        assert_eq!(day.entries.len(), 1);
        assert_eq!(day.entries[0].agenda_type, "scheduled");
    }

    #[test]
    fn upcoming_deadline_within_warning_window() {
        let mut t = task("d", "deadline soon");
        t.deadline = Some(ts(2026, 5, 14));
        let day = evaluate_day(
            &[t],
            NaiveDate::from_ymd_opt(2026, 5, 7).unwrap(),
            NaiveDate::from_ymd_opt(2026, 5, 7).unwrap(),
            &AgendaConfig::default(),
        );
        assert_eq!(day.entries.len(), 1);
        assert_eq!(day.entries[0].agenda_type, "upcoming-deadline");
        assert_eq!(day.entries[0].extra.as_deref(), Some("In 7 d.:"));
    }

    #[test]
    fn no_upcoming_when_outside_warning_window() {
        let mut t = task("d", "far away");
        t.deadline = Some(ts(2026, 8, 1));
        let day = evaluate_day(
            &[t],
            NaiveDate::from_ymd_opt(2026, 5, 7).unwrap(),
            NaiveDate::from_ymd_opt(2026, 5, 7).unwrap(),
            &AgendaConfig::default(),
        );
        assert!(day.entries.is_empty());
    }

    #[test]
    fn body_active_timestamp_makes_timestamp_entry() {
        let mut t = task("b", "meeting");
        t.active_timestamps = Some(vec![ts(2026, 5, 7)]);
        let day = evaluate_day(
            &[t],
            NaiveDate::from_ymd_opt(2026, 5, 7).unwrap(),
            NaiveDate::from_ymd_opt(2026, 5, 7).unwrap(),
            &AgendaConfig::default(),
        );
        assert_eq!(day.entries.len(), 1);
        assert_eq!(day.entries[0].agenda_type, "timestamp");
    }

    #[test]
    fn weekly_repeater_occurs_a_week_later() {
        let mut t = task("r", "weekly review");
        let mut s = ts(2026, 5, 7);
        s.repeater = Some(Repeater {
            kind: "+".into(),
            value: 1,
            unit: "w".into(),
        });
        t.scheduled = Some(s);
        let day = evaluate_day(
            &[t],
            NaiveDate::from_ymd_opt(2026, 5, 14).unwrap(),
            NaiveDate::from_ymd_opt(2026, 5, 14).unwrap(),
            &AgendaConfig::default(),
        );
        assert_eq!(day.entries.len(), 1);
    }

    #[test]
    fn sexp_files_reported_for_proxy() {
        let mut t = task("s", "anniversary helper");
        t.notes = Some("%%(diary-anniversary 1990 1 1) Birthday".into());
        let day = evaluate_day(
            &[t],
            NaiveDate::from_ymd_opt(2026, 5, 7).unwrap(),
            NaiveDate::from_ymd_opt(2026, 5, 7).unwrap(),
            &AgendaConfig::default(),
        );
        assert_eq!(day.needs_sexp_proxy, vec!["/tmp/x.org".to_string()]);
    }
}
