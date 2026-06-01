//! Cadence parsing and due-date engine for DB-backed habits.
//!
//! # Grammar
//!
//! A cadence token has the form `KIND VALUE UNIT [ / MAX_VALUE MAX_UNIT ]`
//! where KIND is one of `+`, `++`, `.+` and UNIT is one of `d`, `w`, `m`, `y`.
//!
//! Examples:
//!   ".+3d"      → {".+", 3, "d", None, None}
//!   ".+1w/2w"   → {".+", 1, "w", Some(2), Some("w")}
//!   "++2w/4w"   → {"++", 2, "w", Some(4), Some("w")}
//!   "+5d/3w"    → {"+",  5, "d", Some(3), Some("w")}
//!
//! A full org timestamp like `<2026-05-28 Thu .+3d -0d>` is also accepted;
//! the repeater token is extracted and the warning part is ignored.
//!
//! # Due/state engine
//!
//! `compute(cadence, anchor, today)` → `(next_due, state)`.
//!
//! `anchor` IS the habit's effective next-due date. The state is derived
//! solely from comparing today to anchor:
//!   - today < anchor  → "ok"
//!   - today == anchor → "due"
//!   - today > anchor:
//!     - non-relaxed (no max): → "overdue"
//!     - relaxed (has max): `today <= anchor + grace` → "due"
//!       `today > anchor + grace` → "overdue", where `grace = max_interval - min_interval`
//!
//! Interval arithmetic uses chrono. `w` = 7 days; `m` and `y` use
//! chrono's `checked_add_months`.
//!
//! # Advance semantics
//!
//! `advance(cadence, anchor, today)` computes the next anchor after a
//! complete or skip action:
//!   - ".+" (restart)  → today + min_interval
//!   - "+"  (cumulate) → first `anchor + k*min_interval` strictly after today
//!   - "++" (catch-up) → first `anchor + k*min_interval` strictly after today

use chrono::{Duration, NaiveDate};
use eav_core::HabitCadenceSpec;

// ---------------------------------------------------------------------------
// Interval add helper
// ---------------------------------------------------------------------------

/// Add (value, unit) to a date. `w` = 7 days; `m`/`y` use calendar arithmetic.
/// Panics are impossible for sane values; returns None on overflow/underflow.
pub fn add_interval(date: NaiveDate, value: i64, unit: &str) -> Option<NaiveDate> {
    match unit {
        "d" => date.checked_add_signed(Duration::days(value)),
        "w" => date.checked_add_signed(Duration::weeks(value)),
        "m" => {
            // chrono Month add: shift by `value` months, clamping day to end
            // of month if necessary.
            use chrono::Months;
            if value >= 0 {
                date.checked_add_months(Months::new(value as u32))
            } else {
                date.checked_sub_months(Months::new((-value) as u32))
            }
        }
        "y" => {
            use chrono::Months;
            let months = value.unsigned_abs() * 12;
            if value >= 0 {
                date.checked_add_months(Months::new(months as u32))
            } else {
                date.checked_sub_months(Months::new(months as u32))
            }
        }
        _ => None,
    }
}

// ---------------------------------------------------------------------------
// Parser
// ---------------------------------------------------------------------------

/// Parse an org-style repeater token (possibly embedded in a full timestamp).
///
/// Accepted inputs:
///   - Bare token:     `.+3d`, `++2w/4w`, `+5d/3w`
///   - Full timestamp: `<2026-05-28 Thu .+3d -0d>`  (warning part ignored)
///
/// Returns `None` if the input contains no recognisable repeater.
pub fn parse_cadence(input: &str) -> Option<HabitCadenceSpec> {
    // If input looks like a full org timestamp bracket, extract the repeater
    // token from inside it. A repeater starts with `.+`, `++`, or `+` (not
    // `+-` which would be a warning). We scan word boundaries inside the
    // brackets and skip warning tokens (leading `-`).
    let token: &str = if input.starts_with('<') || input.starts_with('[') {
        // Extract content between the outer brackets.
        let inner = input.trim_matches(|c| c == '<' || c == '>' || c == '[' || c == ']');
        // Split on whitespace and find the repeater token.
        inner.split_whitespace().find(|t| {
            t.starts_with(".+")
                || t.starts_with("++")
                || (t.starts_with('+') && !t.starts_with("+-"))
        })?
    } else {
        input.trim()
    };

    parse_token(token)
}

/// Parse a bare repeater token string.
fn parse_token(token: &str) -> Option<HabitCadenceSpec> {
    // Determine kind prefix (longest first to avoid `+` matching `++`/`.+`).
    let (kind, rest) = if let Some(r) = token.strip_prefix(".+") {
        (".+", r)
    } else if let Some(r) = token.strip_prefix("++") {
        ("++", r)
    } else if let Some(r) = token.strip_prefix('+') {
        ("+", r)
    } else {
        return None;
    };

    // rest is now like "3d" or "1w/2w" or "5d/3w"
    // Split at optional "/" to get base and max parts.
    let (base_part, max_part) = match rest.split_once('/') {
        Some((b, m)) => (b, Some(m)),
        None => (rest, None),
    };

    let (value, unit) = parse_value_unit(base_part)?;

    let (max_value, max_unit) = if let Some(mp) = max_part {
        let (mv, mu) = parse_value_unit(mp)?;
        (Some(mv), Some(mu.to_string()))
    } else {
        (None, None)
    };

    Some(HabitCadenceSpec {
        kind: kind.to_string(),
        value,
        unit: unit.to_string(),
        max_value,
        max_unit,
    })
}

/// Parse "3d" → (3, "d"), "12w" → (12, "w"), etc.
fn parse_value_unit(s: &str) -> Option<(i64, &str)> {
    // Unit is the last character.
    let (num_part, unit) = s.split_at(s.len().checked_sub(1)?);
    if !matches!(unit, "d" | "w" | "m" | "y") {
        return None;
    }
    let value: i64 = num_part.parse().ok()?;
    if value <= 0 {
        return None;
    }
    Some((value, unit))
}

// ---------------------------------------------------------------------------
// Due/state engine
// ---------------------------------------------------------------------------

/// Output of the cadence engine for a habit today.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DueResult {
    /// YYYY-MM-DD
    pub next_due: NaiveDate,
    /// "ok" | "due" | "overdue"
    pub state: &'static str,
}

/// Compute next_due and state for a habit.
///
/// `anchor` IS the effective next-due date. Falls back to `today` if `None`.
///
/// State rules:
///   - today < anchor                                          → "ok"
///   - today == anchor                                         → "due"
///   - today > anchor, non-relaxed (no max)                   → "overdue"
///   - today > anchor, relaxed (has max):
///     `today <= anchor + grace` → "due", where `grace = max_interval - min_interval`
///     `today > anchor + grace`  → "overdue"
pub fn compute(
    cadence: &HabitCadenceSpec,
    anchor: Option<NaiveDate>,
    today: NaiveDate,
) -> DueResult {
    let next_due = anchor.unwrap_or(today);

    // Grace window for relaxed cadences: [next_due, next_due + (max - min)).
    // If today falls past the grace window, it's overdue.
    let state = if let (Some(mv), Some(mu)) = (cadence.max_value, cadence.max_unit.as_deref()) {
        let v = cadence.value;
        let u = cadence.unit.as_str();
        // grace_end = next_due + (max_interval - min_interval)
        // Compute min_interval and max_interval from next_due as a reference.
        let grace_end = {
            let max_date = add_interval(next_due, mv, mu).unwrap_or(next_due);
            let min_date = add_interval(next_due, v, u).unwrap_or(next_due);
            // grace length = max - min in days
            let grace_days = (max_date - min_date).num_days().max(0);
            next_due + Duration::days(grace_days)
        };
        if today > grace_end {
            "overdue"
        } else if today >= next_due {
            "due"
        } else {
            "ok"
        }
    } else if today > next_due {
        "overdue"
    } else if today == next_due {
        "due"
    } else {
        "ok"
    };

    DueResult { next_due, state }
}

/// Compute the next anchor date after a complete or skip action.
///
/// - `.+` (restart):  today + min_interval
/// - `+`  (cumulate): first `anchor + k*min_interval` strictly after today
/// - `++` (catch-up): first `anchor + k*min_interval` strictly after today
///
/// Falls back to today + min_interval when no valid next point can be found.
pub fn advance(
    cadence: &HabitCadenceSpec,
    anchor: Option<NaiveDate>,
    today: NaiveDate,
) -> NaiveDate {
    let v = cadence.value;
    let u = cadence.unit.as_str();

    match cadence.kind.as_str() {
        ".+" => {
            // Restart from today.
            add_interval(today, v, u).unwrap_or(today)
        }
        "+" | "++" => {
            // Fixed grid: anchor + k*interval, first point strictly after today.
            let base = anchor.unwrap_or(today);
            grid_strictly_after(base, v, u, today)
        }
        _ => add_interval(today, v, u).unwrap_or(today),
    }
}

/// Earliest date on the grid `base + k*(v,u)` that is strictly after `after`.
fn grid_strictly_after(base: NaiveDate, v: i64, u: &str, after: NaiveDate) -> NaiveDate {
    // Find the smallest k >= 1 such that base + k*(v,u) > after.
    // We walk forward from k=1; for reasonable cadences this is ≤ a few steps.
    // For very large gaps (e.g. habit not completed in years with a daily
    // cadence) we compute k approximately via days.
    let mut candidate = add_interval(base, v, u).unwrap_or(after);
    // Fast-forward by a rough estimate of k.
    let gap_days = (after - base).num_days().max(0) as u64;
    let step_days = interval_approx_days(v, u, base).max(1);
    let k_estimate = gap_days / step_days;
    if k_estimate > 1 {
        candidate = add_interval(base, v * k_estimate as i64, u).unwrap_or(candidate);
    }
    // Walk forward until strictly after `after`.
    while candidate <= after {
        candidate = add_interval(candidate, v, u).unwrap_or(candidate);
    }
    // Walk backward once in case we over-shot (possible for m/y when months
    // vary in length).
    loop {
        let prev = sub_interval(candidate, v, u).unwrap_or(base);
        if prev <= after || prev <= base {
            break;
        }
        candidate = prev;
    }
    candidate
}

/// Subtract (v, u) from date.
fn sub_interval(date: NaiveDate, value: i64, unit: &str) -> Option<NaiveDate> {
    add_interval(date, -value, unit)
}

/// Approximate number of days in one (v, u) interval, used for fast-forward
/// estimation only — does not need to be exact.
fn interval_approx_days(v: i64, u: &str, _base: NaiveDate) -> u64 {
    let per_unit: u64 = match u {
        "d" => 1,
        "w" => 7,
        "m" => 30,
        "y" => 365,
        _ => 1,
    };
    (v.unsigned_abs()) * per_unit
}

// =============================================================================
// Tests
// =============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    fn d(s: &str) -> NaiveDate {
        NaiveDate::parse_from_str(s, "%Y-%m-%d").unwrap()
    }

    // -------------------------------------------------------------------------
    // Cadence parser
    // -------------------------------------------------------------------------

    #[test]
    fn parse_dotplus_days() {
        let c = parse_cadence(".+3d").unwrap();
        assert_eq!(c.kind, ".+");
        assert_eq!(c.value, 3);
        assert_eq!(c.unit, "d");
        assert!(c.max_value.is_none());
        assert!(c.max_unit.is_none());
    }

    #[test]
    fn parse_dotplus_relaxed_range_same_unit() {
        let c = parse_cadence(".+1w/2w").unwrap();
        assert_eq!(c.kind, ".+");
        assert_eq!(c.value, 1);
        assert_eq!(c.unit, "w");
        assert_eq!(c.max_value, Some(2));
        assert_eq!(c.max_unit.as_deref(), Some("w"));
    }

    #[test]
    fn parse_plusplus_relaxed_range() {
        let c = parse_cadence("++2w/4w").unwrap();
        assert_eq!(c.kind, "++");
        assert_eq!(c.value, 2);
        assert_eq!(c.unit, "w");
        assert_eq!(c.max_value, Some(4));
        assert_eq!(c.max_unit.as_deref(), Some("w"));
    }

    #[test]
    fn parse_plus_mixed_units() {
        let c = parse_cadence("+5d/3w").unwrap();
        assert_eq!(c.kind, "+");
        assert_eq!(c.value, 5);
        assert_eq!(c.unit, "d");
        assert_eq!(c.max_value, Some(3));
        assert_eq!(c.max_unit.as_deref(), Some("w"));
    }

    #[test]
    fn parse_monthly_cadence() {
        let c = parse_cadence("+1m").unwrap();
        assert_eq!(c.kind, "+");
        assert_eq!(c.value, 1);
        assert_eq!(c.unit, "m");
    }

    #[test]
    fn parse_yearly_cadence() {
        let c = parse_cadence("++1y").unwrap();
        assert_eq!(c.kind, "++");
        assert_eq!(c.unit, "y");
    }

    #[test]
    fn parse_from_full_timestamp() {
        let ts = "<2026-05-28 Thu .+3d -0d>";
        let c = parse_cadence(ts).unwrap();
        assert_eq!(c.kind, ".+");
        assert_eq!(c.value, 3);
        assert_eq!(c.unit, "d");
    }

    #[test]
    fn parse_from_full_timestamp_plusplus() {
        let ts = "<2026-01-01 Wed ++1w -2d>";
        let c = parse_cadence(ts).unwrap();
        assert_eq!(c.kind, "++");
        assert_eq!(c.value, 1);
        assert_eq!(c.unit, "w");
    }

    #[test]
    fn parse_full_timestamp_no_repeater_returns_none() {
        assert!(parse_cadence("<2026-05-28 Thu>").is_none());
    }

    #[test]
    fn parse_bare_invalid_unit_returns_none() {
        assert!(parse_cadence("+3x").is_none());
    }

    #[test]
    fn parse_empty_returns_none() {
        assert!(parse_cadence("").is_none());
    }

    // -------------------------------------------------------------------------
    // add_interval
    // -------------------------------------------------------------------------

    #[test]
    fn add_days() {
        let base = d("2026-05-28");
        assert_eq!(add_interval(base, 3, "d").unwrap(), d("2026-05-31"));
    }

    #[test]
    fn add_weeks() {
        let base = d("2026-05-28");
        assert_eq!(add_interval(base, 2, "w").unwrap(), d("2026-06-11"));
    }

    #[test]
    fn add_months() {
        let base = d("2026-01-31");
        // January 31 + 1 month → February 28 (clamp to month end).
        assert_eq!(add_interval(base, 1, "m").unwrap(), d("2026-02-28"));
    }

    #[test]
    fn add_years() {
        let base = d("2024-02-29"); // leap year
                                    // 2024-02-29 + 1 year → 2025-02-28 (non-leap).
        assert_eq!(add_interval(base, 1, "y").unwrap(), d("2025-02-28"));
    }

    // -------------------------------------------------------------------------
    // compute — anchor-based state
    // -------------------------------------------------------------------------

    #[test]
    fn anchor_in_future_is_ok() {
        let cadence = parse_cadence(".+3d").unwrap();
        let today = d("2026-05-28");
        let anchor = Some(d("2026-06-01"));
        let r = compute(&cadence, anchor, today);
        assert_eq!(r.next_due, d("2026-06-01"));
        assert_eq!(r.state, "ok");
    }

    #[test]
    fn anchor_today_is_due() {
        let cadence = parse_cadence(".+3d").unwrap();
        let today = d("2026-05-28");
        let r = compute(&cadence, Some(today), today);
        assert_eq!(r.next_due, today);
        assert_eq!(r.state, "due");
    }

    #[test]
    fn anchor_in_past_is_overdue() {
        let cadence = parse_cadence(".+3d").unwrap();
        let today = d("2026-05-28");
        let anchor = Some(d("2026-05-20"));
        let r = compute(&cadence, anchor, today);
        assert_eq!(r.next_due, d("2026-05-20"));
        assert_eq!(r.state, "overdue");
    }

    #[test]
    fn no_anchor_falls_back_to_today_due() {
        let cadence = parse_cadence(".+1d").unwrap();
        let today = d("2026-05-28");
        let r = compute(&cadence, None, today);
        assert_eq!(r.next_due, today);
        assert_eq!(r.state, "due");
    }

    // -------------------------------------------------------------------------
    // compute — relaxed cadence (overdue grace window)
    // -------------------------------------------------------------------------
    //
    // Grace window: anchor..=anchor+(max-min).
    // ".+1w/2w": min=1w(7d), max=2w(14d), grace=7d.
    //   anchor = next_due; grace_end = anchor + 7d.
    //   today <= anchor+7d and today >= anchor → "due"
    //   today > anchor+7d                      → "overdue"

    #[test]
    fn relaxed_anchor_today_is_due() {
        let cadence = parse_cadence(".+1w/2w").unwrap();
        let today = d("2026-05-28");
        let r = compute(&cadence, Some(today), today);
        assert_eq!(r.state, "due");
    }

    #[test]
    fn relaxed_within_grace_window_is_due() {
        // anchor = 2026-05-21; grace_end = anchor + 7d = 2026-05-28.
        // today = 2026-05-27: within window → "due"
        let cadence = parse_cadence(".+1w/2w").unwrap();
        let anchor = Some(d("2026-05-21"));
        let today = d("2026-05-27");
        let r = compute(&cadence, anchor, today);
        assert_eq!(r.state, "due");
    }

    #[test]
    fn relaxed_exactly_on_grace_end_is_due() {
        // anchor = 2026-05-21; grace_end = 2026-05-28.
        // today == grace_end → still "due" (overdue requires strictly >)
        let cadence = parse_cadence(".+1w/2w").unwrap();
        let anchor = Some(d("2026-05-21"));
        let today = d("2026-05-28");
        let r = compute(&cadence, anchor, today);
        assert_eq!(r.state, "due");
    }

    #[test]
    fn relaxed_one_past_grace_end_is_overdue() {
        // anchor = 2026-05-21; grace_end = 2026-05-28.
        // today = 2026-05-29 → overdue
        let cadence = parse_cadence(".+1w/2w").unwrap();
        let anchor = Some(d("2026-05-21"));
        let today = d("2026-05-29");
        let r = compute(&cadence, anchor, today);
        assert_eq!(r.state, "overdue");
    }

    #[test]
    fn relaxed_anchor_in_future_is_ok_regardless() {
        let cadence = parse_cadence(".+1w/2w").unwrap();
        let today = d("2026-05-28");
        let anchor = Some(d("2026-06-05"));
        let r = compute(&cadence, anchor, today);
        assert_eq!(r.state, "ok");
    }

    #[test]
    fn relaxed_mixed_units_within_grace() {
        // ".+1m/6w": min=1m≈30d, max=6w=42d, grace=12d (42−30).
        // anchor = 2026-05-01; grace_end = 2026-05-13.
        // today = 2026-05-10 (within grace) → "due"
        let cadence = parse_cadence(".+1m/6w").unwrap();
        let anchor = Some(d("2026-05-01"));
        let today = d("2026-05-10");
        let r = compute(&cadence, anchor, today);
        assert_eq!(r.state, "due");
    }

    #[test]
    fn plus_overdue_with_max() {
        // "+5d/3w": min=5d, max=3w=21d, grace=16d.
        // anchor = 2026-04-01; grace_end = 2026-04-17.
        // today = 2026-04-26 → overdue
        let cadence = parse_cadence("+5d/3w").unwrap();
        let anchor = Some(d("2026-04-01"));
        let today = d("2026-04-26");
        let r = compute(&cadence, anchor, today);
        assert_eq!(r.state, "overdue");
    }

    #[test]
    fn plusplus_overdue_with_max() {
        // "++1w/2w": min=1w=7d, max=2w=14d, grace=7d.
        // anchor = 2026-05-01; grace_end = 2026-05-08.
        // today = 2026-05-22 → overdue
        let cadence = parse_cadence("++1w/2w").unwrap();
        let anchor = Some(d("2026-05-01"));
        let today = d("2026-05-22");
        let r = compute(&cadence, anchor, today);
        assert_eq!(r.state, "overdue");
    }

    // -------------------------------------------------------------------------
    // advance — ".+" restart
    // -------------------------------------------------------------------------

    #[test]
    fn advance_dotplus_returns_today_plus_interval() {
        let cadence = parse_cadence(".+3d").unwrap();
        let today = d("2026-05-28");
        let next = advance(&cadence, Some(d("2026-05-01")), today);
        // Restart: today + 3d
        assert_eq!(next, d("2026-05-31"));
    }

    #[test]
    fn advance_dotplus_no_anchor_still_today_plus_interval() {
        let cadence = parse_cadence(".+1w").unwrap();
        let today = d("2026-05-28");
        let next = advance(&cadence, None, today);
        assert_eq!(next, d("2026-06-04"));
    }

    // -------------------------------------------------------------------------
    // advance — "+" cumulate
    // -------------------------------------------------------------------------

    #[test]
    fn advance_plus_grid_strictly_after_today() {
        // Anchor = 2026-05-01, interval = 7d.
        // Grid: 05-01, 05-08, 05-15, 05-22, 05-29, 06-05, ...
        // today = 2026-05-28 → first strictly after today = 2026-05-29
        let cadence = parse_cadence("+7d").unwrap();
        let anchor = Some(d("2026-05-01"));
        let today = d("2026-05-28");
        let next = advance(&cadence, anchor, today);
        assert_eq!(next, d("2026-05-29"));
    }

    #[test]
    fn advance_plus_when_today_is_on_grid() {
        // today = 2026-05-22 which is on the grid (05-01 + 3*7d).
        // Strictly after: 2026-05-29.
        let cadence = parse_cadence("+7d").unwrap();
        let anchor = Some(d("2026-05-01"));
        let today = d("2026-05-22");
        let next = advance(&cadence, anchor, today);
        assert_eq!(next, d("2026-05-29"));
    }

    // -------------------------------------------------------------------------
    // advance — "++" catch-up
    // -------------------------------------------------------------------------

    #[test]
    fn advance_plusplus_grid_strictly_after_today() {
        // Same grid arithmetic as "+" for advance.
        let cadence = parse_cadence("++7d").unwrap();
        let anchor = Some(d("2026-05-01"));
        let today = d("2026-05-28");
        let next = advance(&cadence, anchor, today);
        assert_eq!(next, d("2026-05-29"));
    }

    // -------------------------------------------------------------------------
    // Boundary precision
    // -------------------------------------------------------------------------

    #[test]
    fn one_day_before_due_is_ok() {
        let cadence = parse_cadence(".+7d").unwrap();
        // anchor = tomorrow
        let today = d("2026-05-28");
        let anchor = Some(today + Duration::days(1));
        let r = compute(&cadence, anchor, today);
        assert_eq!(r.next_due, d("2026-05-29"));
        assert_eq!(r.state, "ok");
    }

    #[test]
    fn anchor_no_anchor_no_completion_uses_today() {
        let cadence = parse_cadence(".+1d").unwrap();
        let today = d("2026-05-28");
        let r = compute(&cadence, None, today);
        assert_eq!(r.next_due, today);
        assert_eq!(r.state, "due");
    }
}
