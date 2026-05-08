//! Wire types for the EAV daemon.
//!
//! Every type here mirrors `server/emacs.ts` and
//! `apps/macos/EmacsAgendaViewer/Models/Models.swift` field-for-field, so the
//! Rust daemon serialises byte-equal JSON to the existing Express server.
//! `#[serde(rename_all = "camelCase")]` does the snake_case↔camelCase mapping;
//! optional fields use `#[serde(skip_serializing_if = "Option::is_none")]` so
//! that "absent" matches the elisp `(push ...)` style output.

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

pub mod agenda_type {
    //! String constants for `AgendaEntry::agenda_type`. Mirrors the symbols
    //! used by org-agenda's text-property `'type`.
    //! See `org-agenda-get-day-entries` (org-agenda.el:5526).
    pub const SCHEDULED: &str = "scheduled";
    pub const DEADLINE: &str = "deadline";
    pub const UPCOMING_DEADLINE: &str = "upcoming-deadline";
    pub const TIMESTAMP: &str = "timestamp";
    pub const SEXP: &str = "sexp";
    pub const TODO: &str = "todo";
    /// `org-agenda-get-blocks`: a date-range active timestamp (`<a>--<b>`)
    /// where the queried date falls within the range, but isn't the start
    /// or end. The Mac/web UIs render these as multi-day blocks.
    pub const BLOCK: &str = "block";
}

// ----------------------------------------------------------------------------
// Timestamps
// ----------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OrgTimestampComponent {
    pub year: i32,
    pub month: u32,
    pub day: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub hour: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub minute: Option<u32>,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OrgTimestamp {
    /// The raw bracketed text, e.g. `<2026-05-07 Thu 10:00 +1d>`.
    pub raw: String,
    /// Legacy field: the first bracketed substring of `raw`.
    pub date: String,
    /// `active`, `inactive`, `active-range`, or `inactive-range`. Optional in
    /// the elisp output; we keep it optional for round-trip parity.
    #[serde(skip_serializing_if = "Option::is_none", rename = "type")]
    pub ts_type: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub range_type: Option<String>,
    pub start: OrgTimestampComponent,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub end: Option<OrgTimestampComponent>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub repeater: Option<Repeater>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub warning: Option<Warning>,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Repeater {
    /// `+`, `++`, or `.+` (org's source syntax).
    #[serde(rename = "type")]
    pub kind: String,
    pub value: i32,
    /// One of `h`, `d`, `w`, `m`, `y`.
    pub unit: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Warning {
    pub value: i32,
    pub unit: String,
}

// ----------------------------------------------------------------------------
// Tasks
// ----------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OrgTask {
    pub id: String,
    pub title: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub todo_state: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub priority: Option<String>,
    #[serde(default)]
    pub tags: Vec<String>,
    #[serde(default)]
    pub inherited_tags: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub scheduled: Option<OrgTimestamp>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub deadline: Option<OrgTimestamp>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub closed: Option<String>,
    pub category: String,
    pub level: u32,
    pub file: String,
    pub pos: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub parent_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub effort: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub notes: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub active_timestamps: Option<Vec<OrgTimestamp>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub properties: Option<BTreeMap<String, String>>,
}

// ----------------------------------------------------------------------------
// Agenda entries
// ----------------------------------------------------------------------------

/// The wire form of `AgendaEntry::level`.
///
/// `eav.el` reads `(get-text-property 0 'level entry)` from org-agenda's output;
/// org-agenda sets that property to a whitespace-prefix *string* (one space
/// per outline level), but the elisp default-fallback `(or … 1)` can also send
/// an integer. The Mac client (`Models.swift`) normalises both at decode time
/// by `strLevel.count` or the int directly. We preserve the original form here
/// so the JSON round-trip is exact.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(untagged)]
pub enum AgendaLevel {
    Int(u32),
    Spaces(String),
}

impl AgendaLevel {
    pub fn as_u32(&self) -> u32 {
        match self {
            AgendaLevel::Int(n) => *n,
            AgendaLevel::Spaces(s) => {
                let trimmed = s.trim_end();
                if trimmed.is_empty() {
                    s.len() as u32
                } else {
                    trimmed.chars().count() as u32
                }
            }
        }
    }
}

impl From<u32> for AgendaLevel {
    fn from(n: u32) -> Self {
        AgendaLevel::Int(n)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgendaEntry {
    pub id: String,
    pub title: String,
    /// One of the values in `agenda_type`.
    pub agenda_type: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub todo_state: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub priority: Option<String>,
    #[serde(default)]
    pub tags: Vec<String>,
    #[serde(default)]
    pub inherited_tags: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub scheduled: Option<OrgTimestamp>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub deadline: Option<OrgTimestamp>,
    pub category: String,
    pub level: AgendaLevel,
    pub file: String,
    pub pos: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub effort: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub warntime: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub time_of_day: Option<String>,
    /// org-agenda's "In 3 d.:" / "1 d. ago:" descriptor for non-display-date
    /// entries; passed through from elisp output.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub extra: Option<String>,
    /// Absolute YYYY-MM-DD for the triggering timestamp (per
    /// `org-agenda-get-day-entries`). Older path; the Mac client also accepts
    /// `display_date` as a fallback.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ts_date: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub display_date: Option<String>,
}

// ----------------------------------------------------------------------------
// Configuration
// ----------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgendaFile {
    pub path: String,
    pub name: String,
    pub category: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TodoKeywordSequence {
    pub active: Vec<String>,
    pub done: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TodoKeywords {
    pub sequences: Vec<TodoKeywordSequence>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OrgConfig {
    pub deadline_warning_days: i32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OrgListConfig {
    pub allow_alphabetical: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OrgPriorities {
    pub highest: String,
    pub lowest: String,
    pub default: String,
}

// ----------------------------------------------------------------------------
// Clock
// ----------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ClockStatus {
    pub clocking: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub file: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pos: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub heading: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub start_time: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub elapsed: Option<i64>,
}

// ----------------------------------------------------------------------------
// Notes / outline
// ----------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HeadingNotes {
    #[serde(default)]
    pub notes: String,
    #[serde(default)]
    pub active_timestamps: Vec<OrgTimestamp>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OutlinePath {
    pub file: String,
    pub headings: Vec<String>,
}

// ----------------------------------------------------------------------------
// Refile / capture
// ----------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RefileTarget {
    pub name: String,
    pub file: String,
    pub pos: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CapturePrompt {
    pub name: String,
    /// `string` | `date` | `tags` | `property`
    #[serde(rename = "type")]
    pub kind: String,
    #[serde(default)]
    pub options: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CaptureTemplate {
    pub key: String,
    pub description: String,
    #[serde(skip_serializing_if = "Option::is_none", rename = "type")]
    pub kind: Option<String>,
    pub is_group: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub target_type: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub target_file: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub target_headline: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub template: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub template_is_function: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub prompts: Option<Vec<CapturePrompt>>,
    pub web_supported: bool,
}

// ----------------------------------------------------------------------------
// Helpers
// ----------------------------------------------------------------------------

impl OrgTask {
    /// The task's stable identifier, used by clients.
    /// Falls back to "{file}::{pos}" if the heading lacks an `:ID:` property.
    pub fn synthetic_id(file: &str, pos: u64) -> String {
        format!("{file}::{pos}")
    }
}

impl OrgTimestamp {
    /// Convert to a `chrono::NaiveDate` from the `start` component.
    pub fn date_naive(&self) -> Option<chrono::NaiveDate> {
        chrono::NaiveDate::from_ymd_opt(
            self.start.year,
            self.start.month,
            self.start.day,
        )
    }

    /// `true` if the start component has hour/minute set.
    pub fn has_time(&self) -> bool {
        self.start.hour.is_some()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn timestamp_round_trip() {
        let ts = OrgTimestamp {
            raw: "<2026-05-07 Thu 10:00 +1d>".into(),
            date: "<2026-05-07 Thu 10:00 +1d>".into(),
            ts_type: Some("active".into()),
            range_type: None,
            start: OrgTimestampComponent {
                year: 2026,
                month: 5,
                day: 7,
                hour: Some(10),
                minute: Some(0),
            },
            end: None,
            repeater: Some(Repeater {
                kind: "+".into(),
                value: 1,
                unit: "d".into(),
            }),
            warning: None,
        };
        let json = serde_json::to_string(&ts).unwrap();
        let back: OrgTimestamp = serde_json::from_str(&json).unwrap();
        assert_eq!(ts, back);
        // Sanity-check that camelCase made it onto the wire.
        assert!(json.contains("\"raw\""));
        assert!(!json.contains("ts_type"));
    }

    #[test]
    fn task_omits_none() {
        let task = OrgTask {
            id: "abc".into(),
            title: "Hello".into(),
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
        };
        let json = serde_json::to_string(&task).unwrap();
        assert!(!json.contains("priority"));
        assert!(!json.contains("scheduled"));
        assert!(json.contains("\"todoState\":\"TODO\""));
    }
}
