//! Walk a parsed org document and emit `OrgTask` records.
//!
//! Mirrors `eav--extract-task-at-point` from `elisp/eav.el`: only headings
//! whose `todo_keyword()` is non-empty become tasks. Tag inheritance follows
//! `org-tags-match-list-sublevels` (default true) — a child inherits all
//! ancestor and `#+FILETAGS:` tags. Categories follow the
//! nearest-ancestor-with-:CATEGORY: property, falling back to `#+CATEGORY:`,
//! falling back to the file basename.

use eav_core::{OrgTask, OrgTimestamp};
use orgize::ast::{Headline, PropertyDrawer};
use orgize::config::ParseConfig;
use orgize::Org;
use std::collections::BTreeMap;
use std::path::Path;

use crate::timestamp::{convert as ts_convert, extract_active_timestamps};
use once_cell::sync::Lazy;
use regex::Regex;

/// Captures `- State "DONE" ... [2026-05-11 Mon 14:32]` lines inside a
/// LOGBOOK drawer. Group 1 is the new state (we only keep DONE for now —
/// org records `from "TODO"` etc. and there's no clean way to ask the
/// daemon what the user's done keywords are at parse time). Group 2 is
/// the raw timestamp inside the brackets, including the day-of-week and
/// optional clock time.
static LOGBOOK_DONE: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r#"-\s+State\s+"([^"]+)"\s+from\s+"[^"]*"\s+\[([^\]]+)\]"#).unwrap()
});

/// Per-file context resolved before walking headlines.
#[derive(Debug, Clone)]
pub struct FileMeta {
    pub file: String,
    pub category: String,
    pub filetags: Vec<String>,
    /// User-overridden TODO keyword sequences from `#+TODO:` lines. Each
    /// element is a list of (keyword, is_done) pairs.
    pub todo_sequences: Vec<Vec<(String, bool)>>,
    pub active_keywords: Vec<String>,
    pub done_keywords: Vec<String>,
    /// Property defaults from `#+PROPERTY:` lines.
    pub default_properties: BTreeMap<String, String>,
}

/// Globally-configured TODO keywords (from the user's Emacs config), used as
/// fallback when a file has no `#+TODO:` line.
#[derive(Debug, Clone, Default)]
pub struct GlobalKeywords {
    pub active: Vec<String>,
    pub done: Vec<String>,
}

impl GlobalKeywords {
    pub fn from_keyword_sequences(seqs: &[(Vec<String>, Vec<String>)]) -> Self {
        let mut active = Vec::new();
        let mut done = Vec::new();
        for (a, d) in seqs {
            for k in a {
                if !active.contains(k) {
                    active.push(k.clone());
                }
            }
            for k in d {
                if !done.contains(k) {
                    done.push(k.clone());
                }
            }
        }
        Self { active, done }
    }
}

impl FileMeta {
    pub fn from_source(source: &str, path: &Path) -> Self {
        Self::from_source_with(source, path, None)
    }

    /// Pre-scan a file's `#+...:` header lines without a full parse. If the
    /// file has no `#+TODO:` line, fall back to the supplied global keywords.
    pub fn from_source_with(
        source: &str,
        path: &Path,
        globals: Option<&GlobalKeywords>,
    ) -> Self {
        let mut filetags = Vec::new();
        let mut category = String::new();
        let mut todo_sequences: Vec<Vec<(String, bool)>> = Vec::new();
        let mut default_properties = BTreeMap::new();

        for line in source.lines() {
            let trimmed = line.trim_start();
            // A heading marks the end of the in-buffer keywords block.
            if trimmed.starts_with('*') && !trimmed.starts_with("*/") {
                break;
            }
            let rest = match trimmed.strip_prefix("#+") {
                Some(r) => r,
                None => continue,
            };
            let (key, value) = match rest.split_once(':') {
                Some((k, v)) => (k.trim().to_uppercase(), v.trim()),
                None => continue,
            };
            match key.as_str() {
                "FILETAGS" => {
                    for t in value
                        .split(|c: char| c == ':' || c.is_whitespace())
                        .filter(|s| !s.is_empty())
                    {
                        filetags.push(t.to_string());
                    }
                }
                "CATEGORY" => {
                    if category.is_empty() {
                        category = value.to_string();
                    }
                }
                "TODO" | "SEQ_TODO" | "TYP_TODO" => {
                    todo_sequences.push(parse_todo_sequence(value));
                }
                "PROPERTY" => {
                    if let Some((k, v)) = value.split_once(' ') {
                        default_properties.insert(k.trim().to_string(), v.trim().to_string());
                    }
                }
                _ => {}
            }
        }

        if category.is_empty() {
            category = path
                .file_stem()
                .and_then(|s| s.to_str())
                .unwrap_or("")
                .to_string();
        }

        // Resolve symlinks if the file exists, so the wire path matches what
        // Emacs reports (which goes through `expand-file-name` /
        // `file-truename`).
        let resolved = std::fs::canonicalize(path)
            .ok()
            .and_then(|p| p.to_str().map(str::to_string))
            .unwrap_or_else(|| path.to_string_lossy().into_owned());

        let (active_keywords, done_keywords) = if todo_sequences.is_empty() {
            match globals {
                Some(g) if !g.active.is_empty() || !g.done.is_empty() => {
                    (g.active.clone(), g.done.clone())
                }
                _ => (vec!["TODO".into()], vec!["DONE".into()]),
            }
        } else {
            let mut act = Vec::new();
            let mut done = Vec::new();
            for seq in &todo_sequences {
                for (kw, is_done) in seq {
                    if *is_done {
                        done.push(kw.clone());
                    } else {
                        act.push(kw.clone());
                    }
                }
            }
            (act, done)
        };

        FileMeta {
            file: resolved,
            category,
            filetags,
            todo_sequences,
            active_keywords,
            done_keywords,
            default_properties,
        }
    }

    /// Build a `ParseConfig` for this file (so orgize recognises the user's
    /// custom keywords).
    pub fn to_parse_config(&self) -> ParseConfig {
        ParseConfig {
            todo_keywords: (self.active_keywords.clone(), self.done_keywords.clone()),
            ..ParseConfig::default()
        }
    }

    pub fn is_task_keyword(&self, kw: &str) -> bool {
        self.active_keywords.iter().any(|s| s == kw)
            || self.done_keywords.iter().any(|s| s == kw)
    }

    pub fn is_done_keyword(&self, kw: &str) -> bool {
        self.done_keywords.iter().any(|s| s == kw)
    }
}

/// Parse a single `#+TODO:` line into (keyword, is_done) pairs.
/// `TODO(t) WAITING(w) | DONE(d) CANCELLED(c)`.
fn parse_todo_sequence(value: &str) -> Vec<(String, bool)> {
    let mut out = Vec::new();
    let mut past_bar = false;
    for tok in value.split_whitespace() {
        if tok == "|" {
            past_bar = true;
            continue;
        }
        // Strip `(c)` shortcut hints.
        let kw = match tok.find('(') {
            Some(i) => &tok[..i],
            None => tok,
        };
        if kw.is_empty() {
            continue;
        }
        out.push((kw.to_string(), past_bar));
    }
    // If no bar, the last keyword is the done state per org's convention.
    if !out.iter().any(|(_, d)| *d) && out.len() >= 2 {
        if let Some(last) = out.last_mut() {
            last.1 = true;
        }
    }
    out
}

/// Walk all headlines in DOC, emitting one `OrgTask` per heading whose
/// `todo_keyword()` is in the file's keyword set.
///
/// `source` is the raw file text (used to slice section bodies); `meta` is the
/// pre-resolved file context.
pub fn extract_tasks(org: &Org, source: &str, meta: &FileMeta) -> Vec<OrgTask> {
    let mut out = Vec::new();
    let document = org.document();
    let mut ancestors: Vec<HeadlineCtx> = Vec::new();
    walk_headlines(
        document.headlines(),
        source,
        meta,
        &mut ancestors,
        &mut out,
    );
    out
}

/// One-shot helper: pre-scan keywords, build a `ParseConfig`, parse, extract.
pub fn extract_tasks_from_source(source: &str, path: &Path) -> (Vec<OrgTask>, FileMeta) {
    extract_tasks_from_source_with(source, path, None)
}

pub fn extract_tasks_from_source_with(
    source: &str,
    path: &Path,
    globals: Option<&GlobalKeywords>,
) -> (Vec<OrgTask>, FileMeta) {
    let meta = FileMeta::from_source_with(source, path, globals);
    let org = meta.to_parse_config().parse(source);
    let tasks = extract_tasks(&org, source, &meta);
    (tasks, meta)
}

#[derive(Clone)]
struct HeadlineCtx {
    pub id: String,
    pub local_tags: Vec<String>,
    pub category: Option<String>,
}

fn walk_headlines(
    iter: impl Iterator<Item = Headline>,
    source: &str,
    meta: &FileMeta,
    ancestors: &mut Vec<HeadlineCtx>,
    out: &mut Vec<OrgTask>,
) {
    for h in iter {
        let local_tags: Vec<String> = h.tags().map(|t| (&t as &str).to_string()).collect();
        let property_drawer = h.properties();

        // Compute this once so the fallback path doesn't re-scan repeatedly.
        let raw_section_text_for_id = h.section().map(|s| s.raw()).unwrap_or_default();
        let drawer_props_fallback = extract_property_drawer(&raw_section_text_for_id);
        let id_property = property_drawer
            .as_ref()
            .and_then(|p| p.get("ID"))
            .map(|t| (&t as &str).to_string())
            .or_else(|| drawer_props_fallback.get("ID").cloned());
        let category_property = property_drawer
            .as_ref()
            .and_then(|p| p.get("CATEGORY"))
            .map(|t| (&t as &str).to_string())
            .or_else(|| drawer_props_fallback.get("CATEGORY").cloned());

        let pos = byte_offset_to_emacs_point(source, h.start());
        let synthetic_id = format!("{}::{}", meta.file, pos);
        let id = id_property.clone().unwrap_or_else(|| synthetic_id.clone());

        // Inherited tags = file-tags ∪ all ancestor local tags
        let inherited_tags: Vec<String> = {
            let mut seen = std::collections::BTreeSet::new();
            let mut v = Vec::new();
            for t in meta
                .filetags
                .iter()
                .chain(ancestors.iter().flat_map(|a| a.local_tags.iter()))
            {
                if seen.insert(t.clone()) {
                    v.push(t.clone());
                }
            }
            v
        };

        let category = category_property
            .clone()
            .or_else(|| {
                ancestors
                    .iter()
                    .rev()
                    .find_map(|a| a.category.clone())
            })
            .unwrap_or_else(|| meta.category.clone());

        // Emit if the heading carries a TODO keyword *or* has a date
        // (scheduled / deadline) *or* has active body timestamps. The first
        // case feeds /api/tasks; all three feed agenda queries.
        let todo_state = h.todo_keyword().map(|t| (&t as &str).to_string());
        let raw_todo_state = todo_state.clone();
        let is_task = todo_state
            .as_deref()
            .map(|s| meta.is_task_keyword(s))
            .unwrap_or(false);

        let scheduled_preview = h.scheduled().as_ref().and_then(ts_convert);
        let deadline_preview = h.deadline().as_ref().and_then(ts_convert);
        // If orgize already picked up the property drawer, the leading
        // planning slot is "consumed" and any later SCHEDULED:/DEADLINE:
        // line in the section is body content (cf. malformed-order entries).
        let preview_props_present = property_drawer.is_some();
        let (notes_preview, body_ts_preview) =
            section_body(&h, source, preview_props_present);
        let has_date = scheduled_preview.is_some()
            || deadline_preview.is_some()
            || !body_ts_preview.is_empty();

        // org-agenda also surfaces a heading whose title itself bears an
        // inactive timestamp like `<2026-05-07 Thu>` (calendar entries) — but
        // those are caught via `body_ts_preview` because orgize parses them as
        // part of the section if we read enough context. For headings with no
        // section we need an explicit title scan.
        let title_text = h.title_raw();
        let title_active_ts = if !has_date {
            crate::timestamp::extract_active_timestamps(&title_text)
        } else {
            Vec::new()
        };
        let has_title_ts = !title_active_ts.is_empty();

        if is_task || has_date || has_title_ts {
            let priority = h.priority().map(|t| (&t as &str).to_string());
            let level = h.level() as u32;

            // orgize 0.10 alpha doesn't accept the deadline-repeater syntax
            // (`+1w/2w` per org-element.el:4445-4448) — when it fails the
            // planning line stays in the section body and `h.scheduled()` etc.
            // return None. Fall back to a hand parse of the section's raw
            // text for those cases.
            //
            // BUT: only run the fallback when orgize *also* missed the
            // property drawer. If orgize found the property drawer but no
            // planning, the planning slot is already "consumed" — a later
            // SCHEDULED: line is body content, not planning, and Express
            // surfaces its timestamp via `org-agenda-get-timestamps` rather
            // than via `:scheduled` (cf. malformed-order entries we observed
            // in the user's data).
            let raw_section_text = h
                .section()
                .as_ref()
                .map(|s| s.raw())
                .unwrap_or_default();
            let allow_planning_fallback = property_drawer.is_none();
            let scheduled = scheduled_preview.or_else(|| {
                if allow_planning_fallback {
                    extract_planning_ts(&raw_section_text, "SCHEDULED")
                } else {
                    None
                }
            });
            let deadline = deadline_preview.or_else(|| {
                if allow_planning_fallback {
                    extract_planning_ts(&raw_section_text, "DEADLINE")
                } else {
                    None
                }
            });
            let closed = h
                .closed()
                .as_ref()
                .and_then(ts_convert)
                .map(|ts| ts.raw)
                .or_else(|| {
                    if allow_planning_fallback {
                        extract_planning_ts(&raw_section_text, "CLOSED").map(|ts| ts.raw)
                    } else {
                        None
                    }
                });

            let title = title_text.trim().to_string();

            let notes = notes_preview;
            let mut active_ts = body_ts_preview;
            active_ts.extend(title_active_ts);

            let parent_id = ancestors.last().map(|a| a.id.clone());

            // Drop only the strictly-not-relevant case: if we got here purely
            // because of `has_title_ts`, propagate todo_state as None so the
            // tasks endpoint still filters it out.
            let _ = raw_todo_state;

            let effort = property_drawer
                .as_ref()
                .and_then(|p| p.get("EFFORT").map(|t| (&t as &str).to_string()))
                .or_else(|| {
                    extract_property_drawer(&raw_section_text)
                        .get("EFFORT")
                        .cloned()
                });

            // Custom properties: prefer orgize's parsed drawer, fall back to a
            // hand scan of the section text when orgize couldn't reach it.
            // Strip CATEGORY/ID/EFFORT (surfaced as their own task fields).
            const SKIP: &[&str] = &["CATEGORY", "ID", "EFFORT"];
            let mut props_map = property_drawer
                .as_ref()
                .map(custom_properties)
                .unwrap_or_default();
            if props_map.is_empty() {
                props_map = extract_property_drawer(&raw_section_text);
                for k in SKIP {
                    props_map.remove(*k);
                }
            }
            let properties = if props_map.is_empty() {
                None
            } else {
                Some(props_map)
            };

            // Habit completions: mine the LOGBOOK only when the heading
            // is flagged as a habit, so the API payload doesn't grow
            // for every regular task that's ever been retried.
            let completions = properties
                .as_ref()
                .and_then(|p| p.get("STYLE"))
                .filter(|v| v.eq_ignore_ascii_case("habit"))
                .map(|_| extract_logbook_completions(&raw_section_text))
                .filter(|v| !v.is_empty());

            let task = OrgTask {
                id,
                title,
                todo_state,
                priority,
                tags: local_tags.clone(),
                inherited_tags,
                scheduled,
                deadline,
                closed,
                category: category.clone(),
                level,
                file: meta.file.clone(),
                pos,
                parent_id,
                effort,
                notes,
                active_timestamps: if active_ts.is_empty() {
                    None
                } else {
                    Some(active_ts)
                },
                properties,
                completions,
            };
            out.push(task);
        }

        ancestors.push(HeadlineCtx {
            id: synthetic_id,
            local_tags,
            category: category_property,
        });
        walk_headlines(h.headlines(), source, meta, ancestors, out);
        ancestors.pop();
    }
}

/// orgize uses 0-based byte offsets; Emacs `point` is 1-based and *character*
/// indexed (one position per code point, not per byte). For ASCII text the
/// two coincide, but org files routinely include emoji titles that explode
/// the gap. Convert by counting characters in the prefix.
fn byte_offset_to_emacs_point(source: &str, offset: orgize::TextSize) -> u64 {
    let n: u32 = offset.into();
    let n = n as usize;
    let prefix = source.get(..n).unwrap_or("");
    prefix.chars().count() as u64 + 1
}

fn custom_properties(drawer: &PropertyDrawer) -> BTreeMap<String, String> {
    // org normalises property keys to uppercase (`org-entry-properties` returns
    // them upcased), and the elisp surface skips "CATEGORY", "ID", "EFFORT"
    // (they're surfaced separately on the task struct).
    //
    // We deliberately do *not* fold in `#+PROPERTY:` defaults here — Emacs's
    // `org-entry-properties nil 'standard` only returns drawer keys (plus
    // CATEGORY), not file-level defaults. Matching that gives us byte parity
    // with the existing wire format.
    const SKIP: &[&str] = &["CATEGORY", "ID", "EFFORT"];
    let mut out = BTreeMap::new();
    for (k, v) in drawer.iter() {
        let key: &str = &k;
        let key_upper = key.to_uppercase();
        if SKIP.contains(&key_upper.as_str()) {
            continue;
        }
        out.insert(key_upper, (&v as &str).to_string());
    }
    out
}

/// Return the section body text (with the *leading* planning lines and
/// canonical drawers stripped) plus the active timestamps it contains.
///
/// Per `org-element-section`, planning is recognised only as the leading run
/// after the heading (cf. `org-at-planning-p` checking
/// `(line-beginning-position 2)`). A `SCHEDULED:` line that appears after a
/// `CLOCK:` or any prose line is body content; its timestamp must surface in
/// `active_timestamps` and feed agenda `timestamp` entries.
///
/// `props_already_consumed` signals that orgize already recognised a property
/// drawer for this headline. In that case, the section text begins *after*
/// the drawer; any further `SCHEDULED:` / `DEADLINE:` line at the top of the
/// section is body content (planning slot was previously occupied) and must
/// not be stripped.
fn section_body(
    h: &Headline,
    _source: &str,
    props_already_consumed: bool,
) -> (Option<String>, Vec<OrgTimestamp>) {
    let Some(section) = h.section() else {
        return (None, Vec::new());
    };

    let raw_section = section.raw();

    let mut lines: Vec<&str> = Vec::new();
    let mut leading_planning_consumed = props_already_consumed;
    let mut leading_drawer_open = false;
    let mut leading_drawer_consumed = props_already_consumed;

    for line in raw_section.lines() {
        let trimmed = line.trim_start();

        // Phase 1: strip the leading planning region. A line matching
        // SCHEDULED:/DEADLINE:/CLOSED: at the very top of the section is
        // planning; once non-planning content appears, planning ends.
        if !leading_planning_consumed {
            if trimmed.starts_with("SCHEDULED:")
                || trimmed.starts_with("DEADLINE:")
                || trimmed.starts_with("CLOSED:")
            {
                continue;
            }
            leading_planning_consumed = true;
        }

        // Phase 2: skip the canonical leading PROPERTIES/LOGBOOK drawer (and
        // friends). These can appear right after planning.
        if !leading_drawer_consumed {
            if leading_drawer_open {
                if trimmed == ":END:" {
                    leading_drawer_open = false;
                }
                continue;
            }
            if is_drawer_open(trimmed) {
                leading_drawer_open = true;
                continue;
            }
            // First "real" line — drawers no longer get auto-stripped.
            leading_drawer_consumed = true;
        }

        // Phase 3: still skip CLOCK lines (those are noise) but keep prose
        // (including a stale SCHEDULED: that's body content now).
        if trimmed.starts_with("CLOCK:") {
            continue;
        }
        lines.push(line);
    }

    let body = lines.join("\n").trim().to_string();
    if body.is_empty() {
        return (None, Vec::new());
    }
    let stamps = extract_active_timestamps(&body);
    (Some(body), stamps)
}

fn is_drawer_open(line: &str) -> bool {
    if !line.starts_with(':') || !line.ends_with(':') {
        return false;
    }
    let inner = &line[1..line.len() - 1];
    !inner.is_empty()
        && inner.chars().all(|c| c.is_ascii_uppercase() || c == '_')
        && inner != "END"
}

/// Pull a `SCHEDULED:` / `DEADLINE:` / `CLOSED:` timestamp out of a raw
/// section text. Used as a fallback when orgize's headline accessor fails
/// (e.g. on `+1w/2w` deadline-repeater syntax).
///
/// Mirrors `org-element-planning-parser`: planning lines must be the *first
/// non-blank lines* of the section; once another type of content appears
/// (clock lines, drawers, prose), planning stops being recognised. A
/// `SCHEDULED:` line buried below a `CLOCK:` line is body content and
/// produces an active body timestamp instead.
fn extract_planning_ts(section: &str, key: &str) -> Option<crate::OrgTimestamp> {
    let prefix = format!("{key}:");
    for line in section.lines() {
        let trimmed = line.trim_start();
        if trimmed.is_empty() {
            continue;
        }
        // A planning line begins with one of these keywords; anything else
        // (CLOCK:, drawer headers, prose) closes the planning region.
        let is_planning_line = trimmed.starts_with("SCHEDULED:")
            || trimmed.starts_with("DEADLINE:")
            || trimmed.starts_with("CLOSED:");
        if !is_planning_line {
            return None;
        }
        if let Some(rest) = trimmed.strip_prefix(&prefix) {
            let rest = rest.trim_start();
            let cap_end = rest
                .find(|c: char| c == '\n' || c == '\r')
                .unwrap_or(rest.len());
            let mut piece = &rest[..cap_end];
            for stop in &[" SCHEDULED:", " DEADLINE:", " CLOSED:"] {
                if let Some(idx) = piece.find(stop) {
                    piece = &piece[..idx];
                }
            }
            let stamp = first_timestamp_token(piece)?;
            return crate::timestamp::parse_timestamp_lenient(&stamp);
        }
    }
    None
}

// `parse_timestamp_lenient` lives in `crate::timestamp` so the body-scan helper
// can share it.

/// Find the first <...>...> or [...] timestamp token in TEXT (handles ranges).
fn first_timestamp_token(text: &str) -> Option<String> {
    let bytes = text.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        let c = bytes[i];
        if c == b'<' || c == b'[' {
            let close = if c == b'<' { b'>' } else { b']' };
            let start = i;
            let mut end = None;
            for j in (i + 1)..bytes.len() {
                if bytes[j] == close {
                    end = Some(j);
                    break;
                }
            }
            let stamp_end = end?;
            let mut total_end = stamp_end + 1;
            // Date-range: <a>--<b>.
            if text[total_end..].starts_with("--") {
                if let Some(rest_start) = text[total_end + 2..].find(|cc: char| cc == '<' || cc == '[') {
                    let inner_start = total_end + 2 + rest_start;
                    let inner_close = if &text[inner_start..inner_start + 1] == "<" { b'>' } else { b']' };
                    if let Some(j) = text.as_bytes()[inner_start + 1..]
                        .iter()
                        .position(|&b| b == inner_close)
                    {
                        total_end = inner_start + 1 + j + 1;
                    }
                }
            }
            return Some(text[start..total_end].to_string());
        }
        i += 1;
    }
    None
}

/// Hand parser for `:PROPERTIES: ... :END:` drawers. Returns an empty map if
/// none is found. Used when orgize's headline accessor failed.
///
/// org-mode requires the property drawer to appear *immediately* after the
/// heading (and any planning lines), with no intervening prose or other
/// drawers. A `:PROPERTIES:` line buried below a `CLOCK:` line is treated
/// as a different drawer or as plain text. To stay consistent with
/// `extract_planning_ts`, this scans only the leading planning + drawer
/// region and stops at the first non-planning, non-drawer line.
fn extract_property_drawer(section: &str) -> BTreeMap<String, String> {
    let mut out = BTreeMap::new();
    let mut in_drawer = false;
    for line in section.lines() {
        let trimmed = line.trim_start();
        if trimmed.is_empty() {
            if !in_drawer {
                // A blank line before any drawer ends the planning region.
                return out;
            }
            continue;
        }
        if !in_drawer {
            if trimmed == ":PROPERTIES:" {
                in_drawer = true;
                continue;
            }
            // Planning lines are allowed to precede the drawer.
            if trimmed.starts_with("SCHEDULED:")
                || trimmed.starts_with("DEADLINE:")
                || trimmed.starts_with("CLOSED:")
            {
                continue;
            }
            // Anything else (CLOCK:, prose, other drawers) means the property
            // drawer can no longer be the canonical one.
            return out;
        }
        if trimmed == ":END:" {
            break;
        }
        // Format: ":KEY: value"
        if let Some(rest) = trimmed.strip_prefix(':') {
            if let Some(idx) = rest.find(':') {
                let key = &rest[..idx];
                let value = rest[idx + 1..].trim();
                let key_upper = key.to_uppercase();
                out.insert(key_upper, value.to_string());
            }
        }
    }
    out
}

/// Scan a heading's raw section text for completion timestamps recorded
/// in the LOGBOOK drawer. Only `State "DONE" from ...` transitions are
/// returned — habits use the standard repeat cycle which always lands
/// the heading in DONE before re-scheduling, and users with custom
/// completion states can add them later if the need shows up.
///
/// Newest-first matches org's own LOGBOOK ordering (`org-log-into-drawer`
/// prepends), but we don't depend on that — the caller can sort.
fn extract_logbook_completions(section: &str) -> Vec<String> {
    let mut in_logbook = false;
    let mut out = Vec::new();
    for line in section.lines() {
        let trimmed = line.trim_start();
        if !in_logbook {
            if trimmed == ":LOGBOOK:" {
                in_logbook = true;
            }
            continue;
        }
        if trimmed == ":END:" {
            break;
        }
        if let Some(caps) = LOGBOOK_DONE.captures(trimmed) {
            if &caps[1] == "DONE" {
                out.push(caps[2].to_string());
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn extract(text: &str) -> Vec<OrgTask> {
        extract_tasks_from_source(text, Path::new("/tmp/test.org")).0
    }

    #[test]
    fn extracts_habit_completions() {
        let src = "* TODO Meditate\n  SCHEDULED: <2026-05-12 Tue .+1d>\n  :PROPERTIES:\n  :STYLE: habit\n  :END:\n  :LOGBOOK:\n  - State \"DONE\"       from \"TODO\"       [2026-05-11 Mon 14:32]\n  - State \"DONE\"       from \"TODO\"       [2026-05-10 Sun 09:15]\n  - State \"DONE\"       from \"TODO\"       [2026-05-09 Sat 18:00]\n  :END:\n";
        let tasks = extract(src);
        assert_eq!(tasks.len(), 1);
        let t = &tasks[0];
        let completions = t.completions.as_ref().expect("habit should carry completions");
        assert_eq!(completions.len(), 3);
        assert_eq!(completions[0], "2026-05-11 Mon 14:32");
        // Non-habit transitions on the same heading do not surface
        // — we only attach the field when STYLE=habit.
        assert!(t.properties.as_ref().unwrap().get("STYLE").map(String::as_str) == Some("habit"));
    }

    #[test]
    fn non_habit_omits_completions() {
        let src = "* DONE Pay bill\n  CLOSED: [2026-05-11 Mon 10:00]\n  :LOGBOOK:\n  - State \"DONE\"       from \"TODO\"       [2026-05-11 Mon 10:00]\n  :END:\n";
        let tasks = extract(src);
        assert_eq!(tasks.len(), 1);
        assert!(tasks[0].completions.is_none(),
            "non-habit headings should not carry the completions field");
    }

    #[test]
    fn extracts_simple_todo() {
        let tasks = extract("* TODO Write the daemon\nbody text here\n");
        assert_eq!(tasks.len(), 1);
        let t = &tasks[0];
        assert_eq!(t.title, "Write the daemon");
        assert_eq!(t.todo_state.as_deref(), Some("TODO"));
        assert_eq!(t.level, 1);
        assert_eq!(t.notes.as_deref(), Some("body text here"));
    }

    #[test]
    fn skips_plain_headings() {
        let tasks = extract("* Just a heading\n* TODO real task\n");
        assert_eq!(tasks.len(), 1);
        assert_eq!(tasks[0].title, "real task");
    }

    #[test]
    fn tag_inheritance_from_filetags_and_parents() {
        let tasks = extract(
            "\
#+FILETAGS: :proj:
* Parent :work:
** TODO Child :urgent:
",
        );
        assert_eq!(tasks.len(), 1);
        let t = &tasks[0];
        assert_eq!(t.tags, vec!["urgent"]);
        assert!(t.inherited_tags.contains(&"proj".to_string()));
        assert!(t.inherited_tags.contains(&"work".to_string()));
    }

    #[test]
    fn file_local_todo_sequence() {
        let tasks = extract(
            "\
#+TODO: NEXT(n) WAITING(w) | DONE(d)
* NEXT a
* WAITING b
* DONE c
* TODO d
",
        );
        let titles: Vec<&str> = tasks.iter().map(|t| t.title.as_str()).collect();
        assert!(titles.contains(&"a"), "tasks: {titles:?}");
        assert!(titles.contains(&"b"), "tasks: {titles:?}");
        assert!(titles.contains(&"c"), "tasks: {titles:?}");
        assert!(!titles.contains(&"d"), "TODO should not be a keyword here");
    }

    #[test]
    fn category_from_keyword_and_property() {
        let tasks = extract(
            "\
#+CATEGORY: Inbox
* TODO outer
** TODO inner
:PROPERTIES:
:CATEGORY: Project-X
:END:
*** TODO grand
",
        );
        let by_title = |title: &str| tasks.iter().find(|t| t.title == title).unwrap();
        assert_eq!(by_title("outer").category, "Inbox");
        assert_eq!(by_title("inner").category, "Project-X");
        assert_eq!(by_title("grand").category, "Project-X");
    }

    #[test]
    fn extracts_scheduled_and_deadline() {
        let tasks = extract(
            "\
* TODO with planning
SCHEDULED: <2026-05-07 Thu 10:00> DEADLINE: <2026-05-10 Sun>
",
        );
        let t = &tasks[0];
        let s = t.scheduled.as_ref().unwrap();
        assert_eq!(s.start.day, 7);
        assert_eq!(s.start.hour, Some(10));
        let d = t.deadline.as_ref().unwrap();
        assert_eq!(d.start.day, 10);
    }

    #[test]
    fn body_active_timestamps() {
        let tasks = extract(
            "\
* TODO task
:PROPERTIES:
:ID: abc-123
:END:
Some prose with <2026-06-01 Mon> mentioned.
",
        );
        let t = &tasks[0];
        assert_eq!(t.id, "abc-123");
        let stamps = t.active_timestamps.as_ref().unwrap();
        assert_eq!(stamps.len(), 1);
        assert_eq!(stamps[0].start.month, 6);
        assert!(t.notes.as_deref().unwrap().contains("Some prose"));
        assert!(!t.notes.as_deref().unwrap().contains(":ID:"));
    }
}
