//! Conversion between `orgize::ast::Timestamp` and `eav_core::OrgTimestamp`,
//! plus a standalone `parse_timestamp` for raw strings.

use eav_core::{OrgTimestamp, OrgTimestampComponent, Repeater, Warning};
use orgize::ast::{RepeaterType, TimeUnit, Timestamp as OrgizeTimestamp, Token};
use orgize::rowan::ast::AstNode;

fn parse_u32(t: Option<Token>) -> Option<u32> {
    t.and_then(|tok| {
        let s: &str = &tok;
        s.parse::<u32>().ok()
    })
}

fn parse_i32(t: Option<Token>) -> Option<i32> {
    t.and_then(|tok| {
        let s: &str = &tok;
        s.parse::<i32>().ok()
    })
}

fn unit_to_char(u: TimeUnit) -> &'static str {
    match u {
        TimeUnit::Hour => "h",
        TimeUnit::Day => "d",
        TimeUnit::Week => "w",
        TimeUnit::Month => "m",
        TimeUnit::Year => "y",
    }
}

fn repeater_kind(rt: RepeaterType) -> &'static str {
    match rt {
        RepeaterType::Cumulate => "+",
        RepeaterType::CatchUp => "++",
        RepeaterType::Restart => ".+",
    }
}

/// Convert an orgize `Timestamp` AST node to the wire shape.
pub fn convert(ts: &OrgizeTimestamp) -> Option<OrgTimestamp> {
    let raw = ts.raw();
    if raw.is_empty() {
        return None;
    }

    let year = parse_i32(ts.year_start())?;
    let month = parse_u32(ts.month_start())?;
    let day = parse_u32(ts.day_start())?;
    let hour = parse_u32(ts.hour_start());
    let minute = parse_u32(ts.minute_start());

    let start = OrgTimestampComponent {
        year,
        month,
        day,
        hour,
        minute,
    };

    // org-element (and therefore the existing Express output) always populates
    // `end`: for non-range timestamps it's a copy of the start. We mirror that
    // shape here so the JSON wire format is byte-identical.
    let (y2, m2, d2, h2, mn2) = (
        parse_i32(ts.year_end()),
        parse_u32(ts.month_end()),
        parse_u32(ts.day_end()),
        parse_u32(ts.hour_end()),
        parse_u32(ts.minute_end()),
    );
    let end = match (y2, m2, d2) {
        (Some(y), Some(m), Some(d)) => Some(OrgTimestampComponent {
            year: y,
            month: m,
            day: d,
            hour: h2,
            minute: mn2,
        }),
        _ => Some(OrgTimestampComponent {
            year,
            month,
            day,
            hour: h2.or(hour),
            minute: mn2.or(minute),
        }),
    };

    let ts_type = if ts.is_diary() {
        Some("diary".to_string())
    } else if ts.is_active() {
        if ts.is_range() {
            Some("active-range".to_string())
        } else {
            Some("active".to_string())
        }
    } else if ts.is_inactive() {
        if ts.is_range() {
            Some("inactive-range".to_string())
        } else {
            Some("inactive".to_string())
        }
    } else {
        None
    };

    let range_type = if ts.is_range() {
        if y2.is_some()
            && d2.is_some()
            && (y2 != Some(year) || m2 != Some(month) || d2 != Some(day))
        {
            Some("daterange".to_string())
        } else if h2.is_some() {
            Some("timerange".to_string())
        } else if y2.is_some() {
            Some("daterange".to_string())
        } else {
            None
        }
    } else {
        None
    };

    let repeater = match (ts.repeater_type(), ts.repeater_value(), ts.repeater_unit()) {
        (Some(rt), Some(v), Some(u)) => Some(Repeater {
            kind: repeater_kind(rt).to_string(),
            value: v as i32,
            unit: unit_to_char(u).to_string(),
        }),
        _ => None,
    };

    let warning = match (ts.warning_value(), ts.warning_unit()) {
        (Some(v), Some(u)) => Some(Warning {
            value: v as i32,
            unit: unit_to_char(u).to_string(),
        }),
        _ => None,
    };

    let date = first_bracketed(&raw).unwrap_or_else(|| raw.clone());

    Some(OrgTimestamp {
        raw,
        date,
        ts_type,
        range_type,
        start,
        end,
        repeater,
        warning,
    })
}

fn first_bracketed(s: &str) -> Option<String> {
    let bytes = s.as_bytes();
    let len = bytes.len();
    let mut i = 0;
    while i < len {
        let open = bytes[i];
        if open == b'<' || open == b'[' {
            let close = if open == b'<' { b'>' } else { b']' };
            if let Some(end) = s[i + 1..].find(close as char) {
                return Some(s[i..=i + 1 + end].to_string());
            }
        }
        i += 1;
    }
    None
}

/// Parse a raw timestamp string (e.g. "<2026-05-07 Thu 10:00 +1d>") into the
/// wire shape, by feeding it to orgize as a one-line document.
pub fn parse_timestamp(raw: &str) -> Option<OrgTimestamp> {
    let raw = raw.trim();
    if raw.is_empty() {
        return None;
    }
    let doc = format!("dummy {raw}\n");
    let parsed = orgize::Org::parse(&doc);
    let document = parsed.document();
    let syntax = document.syntax();
    for node in syntax.descendants() {
        if let Some(ts) = OrgizeTimestamp::cast(node) {
            return convert(&ts);
        }
    }
    None
}

/// Scan TEXT for active timestamps (and ranges), in order. Mirrors
/// `eav--extract-active-timestamps`: only active forms.
///
/// We use a regex-based scanner instead of orgize because orgize 0.10.x
/// rejects the `+1w/2w` deadline-repeater syntax (org-element.el:4445-4448),
/// silently dropping such timestamps. Falling back to a regex keeps body
/// scans faithful and lets the agenda evaluator surface
/// SCHEDULED-after-CLOCK lines as plain `timestamp` entries.
pub fn extract_active_timestamps(text: &str) -> Vec<OrgTimestamp> {
    use regex::Regex;
    use std::sync::OnceLock;
    // Active timestamp: starts with `<`, followed by a date, followed by
    // arbitrary content not containing `<`, `>`, or newline, ending in `>`.
    // We then optionally consume `--<...>` for date ranges.
    static RE: OnceLock<Regex> = OnceLock::new();
    let re = RE.get_or_init(|| {
        Regex::new(r"<\d{4}-\d{2}-\d{2}[^<>\n]*?>(?:--<\d{4}-\d{2}-\d{2}[^<>\n]*?>)?").unwrap()
    });
    let mut out = Vec::new();
    for m in re.find_iter(text) {
        let raw = m.as_str();
        if let Some(ts) = parse_timestamp_lenient(raw) {
            out.push(ts);
        } else if let Some(ts) = parse_timestamp(raw) {
            out.push(ts);
        }
    }
    out
}

/// Like `parse_timestamp` but tolerant of the `+Nu/Mu` deadline-repeater
/// syntax that orgize rejects. Strips the `/Mu` portion before parsing, then
/// reattaches it to `raw` so the wire shape matches the source.
pub fn parse_timestamp_lenient(raw: &str) -> Option<OrgTimestamp> {
    use regex::Regex;
    use std::sync::OnceLock;
    static RE: OnceLock<Regex> = OnceLock::new();
    let re = RE.get_or_init(|| Regex::new(r"(\+|\+\+|\.\+)(\d+)([hdwmy])(/\d+[hdwmy])").unwrap());
    let stripped = re.replace_all(raw, "$1$2$3").into_owned();
    let mut ts = parse_timestamp(&stripped)?;
    if stripped != raw {
        ts.raw = raw.to_string();
        // Recompute the legacy `date` slice (first bracketed substring).
        ts.date = first_bracketed_local(raw).unwrap_or_else(|| raw.to_string());
    }
    Some(ts)
}

fn first_bracketed_local(s: &str) -> Option<String> {
    let bytes = s.as_bytes();
    for (i, &b) in bytes.iter().enumerate() {
        if b == b'<' || b == b'[' {
            let close = if b == b'<' { b'>' } else { b']' };
            if let Some(end) = s[i + 1..].find(close as char) {
                return Some(s[i..=i + 1 + end].to_string());
            }
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_simple_active() {
        let ts = parse_timestamp("<2026-05-07 Thu>").unwrap();
        assert_eq!(ts.start.year, 2026);
        assert_eq!(ts.start.month, 5);
        assert_eq!(ts.start.day, 7);
        assert_eq!(ts.ts_type.as_deref(), Some("active"));
        // org-element always populates end (= start for non-ranges); mirror it.
        let e = ts.end.expect("end always present");
        assert_eq!(e.year, 2026);
        assert_eq!(e.month, 5);
        assert_eq!(e.day, 7);
        assert!(ts.repeater.is_none());
    }

    #[test]
    fn parses_active_with_time() {
        let ts = parse_timestamp("<2026-05-07 Thu 10:00>").unwrap();
        assert_eq!(ts.start.hour, Some(10));
        assert_eq!(ts.start.minute, Some(0));
    }

    #[test]
    fn parses_repeater_and_warning() {
        let ts = parse_timestamp("<2026-05-07 Thu +1d -2d>").unwrap();
        let r = ts.repeater.unwrap();
        assert_eq!(r.kind, "+");
        assert_eq!(r.value, 1);
        assert_eq!(r.unit, "d");
        let w = ts.warning.unwrap();
        assert_eq!(w.value, 2);
        assert_eq!(w.unit, "d");
    }

    #[test]
    fn parses_inactive() {
        let ts = parse_timestamp("[2026-05-07 Thu]").unwrap();
        assert_eq!(ts.ts_type.as_deref(), Some("inactive"));
    }

    #[test]
    fn parses_time_range() {
        let ts = parse_timestamp("<2026-05-07 Thu 10:00-12:00>").unwrap();
        assert_eq!(ts.start.hour, Some(10));
        let end = ts.end.unwrap();
        assert_eq!(end.hour, Some(12));
        assert_eq!(end.year, 2026);
        assert_eq!(end.day, 7);
    }

    #[test]
    fn extracts_from_body_text() {
        let body = "Some prose. <2026-05-07 Thu> and later <2026-06-01 Mon 09:00>.";
        let ts = extract_active_timestamps(body);
        assert_eq!(ts.len(), 2);
        assert_eq!(ts[0].start.month, 5);
        assert_eq!(ts[1].start.month, 6);
        assert_eq!(ts[1].start.hour, Some(9));
    }

    #[test]
    fn ignores_inactive_in_body() {
        let body = "Skip [2026-05-07 Thu]. Keep <2026-06-01 Mon>.";
        let ts = extract_active_timestamps(body);
        assert_eq!(ts.len(), 1);
        assert_eq!(ts[0].start.month, 6);
    }
}
