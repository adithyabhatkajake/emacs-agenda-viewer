//! Repeater + warning math for agenda queries.

use chrono::{Datelike, Duration, NaiveDate};
use eav_core::{OrgTimestamp, Repeater, Warning};

/// Convert an `OrgTimestamp` start component to a `NaiveDate`.
pub fn ts_date(ts: &OrgTimestamp) -> Option<NaiveDate> {
    NaiveDate::from_ymd_opt(ts.start.year, ts.start.month, ts.start.day)
}

/// True if TS represents an active occurrence (repeater-aware) on TARGET.
///
/// Mirrors the parts of `org-agenda-get-day-entries` that advance a repeater
/// to find any instance landing on the queried day. We support the documented
/// subset:
///   - `+1d`/`+1w`/`+1m`/`+1y`/`+Nh`           cumulate
///   - `++1d`/...                              catch-up
///   - `.+1d`/...                              restart
/// Habit tracking (cookies, consistency) is out of scope.
pub fn occurs_on(ts: &OrgTimestamp, target: NaiveDate, today: NaiveDate) -> bool {
    let Some(base) = ts_date(ts) else { return false };
    if let Some(rep) = ts.repeater.as_ref() {
        any_repeat_lands_on(base, rep, target, today)
    } else {
        base == target
    }
}

/// Returns the date ON or AFTER target on which TS next occurs (after applying
/// the repeater). Used for upcoming-deadline detection within a warning window.
pub fn next_occurrence_on_or_after(
    ts: &OrgTimestamp,
    target: NaiveDate,
    today: NaiveDate,
) -> Option<NaiveDate> {
    let base = ts_date(ts)?;
    let rep = match ts.repeater.as_ref() {
        Some(r) => r,
        None => return if base >= target { Some(base) } else { None },
    };
    advance_to(base, rep, target, today)
}

fn any_repeat_lands_on(
    base: NaiveDate,
    rep: &Repeater,
    target: NaiveDate,
    today: NaiveDate,
) -> bool {
    if let Some(d) = advance_to(base, rep, target, today) {
        d == target
    } else {
        false
    }
}

fn advance_to(
    base: NaiveDate,
    rep: &Repeater,
    target: NaiveDate,
    today: NaiveDate,
) -> Option<NaiveDate> {
    if base >= target {
        return Some(base);
    }
    let step = rep.value.max(1) as i64;
    // Cumulate: enumerate occurrences from base until ≥ target.
    if rep.kind == "+" || rep.kind == "++" || rep.kind == ".+" {
        // For cumulate (+) and catch-up (++) we step from `base` until ≥ target.
        // For restart (.+) the next instance after a "done" tick depends on the
        // last completion time; absent that information we degrade to cumulate.
        let _ = today;
        let mut cur = base;
        // Bound the loop generously — 200 years × 365 days = 73,000 to be safe.
        for _ in 0..1_000_000 {
            if cur >= target {
                return Some(cur);
            }
            cur = match step_unit(cur, step, &rep.unit)? {
                Some(d) => d,
                None => return None,
            };
        }
        None
    } else {
        None
    }
}

fn step_unit(d: NaiveDate, step: i64, unit: &str) -> Option<Option<NaiveDate>> {
    match unit {
        "d" => Some(d.checked_add_signed(Duration::days(step))),
        "w" => Some(d.checked_add_signed(Duration::weeks(step))),
        "h" => Some(d.checked_add_signed(Duration::hours(step))),
        "m" => Some(add_months(d, step)),
        "y" => Some(add_years(d, step)),
        _ => Some(None),
    }
}

pub fn add_months(d: NaiveDate, months: i64) -> Option<NaiveDate> {
    let total_months = d.month() as i64 - 1 + months;
    let new_year = d.year() as i64 + total_months.div_euclid(12);
    let new_month = total_months.rem_euclid(12) as u32 + 1;
    let mut day = d.day();
    // Clamp to last day of new month.
    loop {
        if let Some(out) = NaiveDate::from_ymd_opt(new_year as i32, new_month, day) {
            return Some(out);
        }
        if day == 0 {
            return None;
        }
        day -= 1;
    }
}

pub fn add_years(d: NaiveDate, years: i64) -> Option<NaiveDate> {
    let new_year = d.year() as i64 + years;
    NaiveDate::from_ymd_opt(new_year as i32, d.month(), d.day())
        .or_else(|| NaiveDate::from_ymd_opt(new_year as i32, d.month(), 28))
}

/// Number of days in the warning window for a deadline.
/// `warning` overrides the global `deadline_warning_days` if present (per
/// org's documented `-Nd` syntax).
pub fn warning_days(warning: Option<&Warning>, default_days: i32) -> i32 {
    match warning {
        Some(w) => match w.unit.as_str() {
            "d" => w.value,
            "w" => w.value * 7,
            "m" => w.value * 30,
            "y" => w.value * 365,
            _ => default_days,
        },
        None => default_days,
    }
}

/// Format an `OrgTimestamp` start component's HH:MM as the `timeOfDay` field.
pub fn time_of_day(ts: &OrgTimestamp) -> Option<String> {
    let h = ts.start.hour?;
    let m = ts.start.minute.unwrap_or(0);
    Some(format!("{h:02}:{m:02}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use eav_core::OrgTimestampComponent;

    fn ts(year: i32, month: u32, day: u32, repeater: Option<(&str, i32, &str)>) -> OrgTimestamp {
        OrgTimestamp {
            raw: "<>".into(),
            date: "<>".into(),
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
            repeater: repeater.map(|(k, v, u)| Repeater {
                kind: k.into(),
                value: v,
                unit: u.into(),
            }),
            warning: None,
        }
    }

    #[test]
    fn no_repeater_exact_match() {
        let t = ts(2026, 5, 7, None);
        let target = NaiveDate::from_ymd_opt(2026, 5, 7).unwrap();
        let today = NaiveDate::from_ymd_opt(2026, 5, 7).unwrap();
        assert!(occurs_on(&t, target, today));
        assert!(!occurs_on(
            &t,
            NaiveDate::from_ymd_opt(2026, 5, 8).unwrap(),
            today
        ));
    }

    #[test]
    fn weekly_repeater() {
        let t = ts(2026, 5, 1, Some(("+", 1, "w")));
        let today = NaiveDate::from_ymd_opt(2026, 6, 1).unwrap();
        for &day in &[1u32, 8, 15, 22, 29] {
            assert!(occurs_on(
                &t,
                NaiveDate::from_ymd_opt(2026, 5, day).unwrap(),
                today
            ));
        }
        assert!(!occurs_on(
            &t,
            NaiveDate::from_ymd_opt(2026, 5, 2).unwrap(),
            today
        ));
    }

    #[test]
    fn monthly_repeater_clamps_short_months() {
        let t = ts(2026, 1, 31, Some(("+", 1, "m")));
        let today = NaiveDate::from_ymd_opt(2026, 5, 1).unwrap();
        // Feb has no 31, so steps to 28th in non-leap year.
        assert!(occurs_on(
            &t,
            NaiveDate::from_ymd_opt(2026, 2, 28).unwrap(),
            today
        ));
        // March keeps stepping from the (clamped) 28th — org's behaviour is to
        // keep stepping by the original "month" semantics from the *clamped*
        // date.
        assert!(occurs_on(
            &t,
            NaiveDate::from_ymd_opt(2026, 3, 28).unwrap(),
            today
        ));
    }

    #[test]
    fn yearly_repeater() {
        let t = ts(2020, 6, 15, Some(("+", 1, "y")));
        let today = NaiveDate::from_ymd_opt(2026, 1, 1).unwrap();
        assert!(occurs_on(
            &t,
            NaiveDate::from_ymd_opt(2026, 6, 15).unwrap(),
            today
        ));
    }

    #[test]
    fn warning_days_uses_default_when_none() {
        assert_eq!(warning_days(None, 14), 14);
        let w = Warning {
            value: 3,
            unit: "d".into(),
        };
        assert_eq!(warning_days(Some(&w), 14), 3);
    }

    #[test]
    fn time_of_day_format() {
        let mut t = ts(2026, 5, 7, None);
        t.start.hour = Some(9);
        t.start.minute = Some(5);
        assert_eq!(time_of_day(&t).as_deref(), Some("09:05"));
    }
}
