//! Golden-JSON round-trip parity test.
//!
//! Reads each captured response in `daemon/tests/golden/` (snapshots of the
//! current Express server), deserializes into the matching `eav-core` type,
//! re-serializes, and asserts a byte-equal value comparison (after canonical
//! re-formatting via serde_json::Value).

use eav_core::*;
use serde::de::DeserializeOwned;
use serde::Serialize;
use std::fs;
use std::path::{Path, PathBuf};

fn golden_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .join("tests")
        .join("golden")
}

/// Read a captured `/api/*` response by filename. The goldens live under
/// `daemon/tests/golden/*.json` and are .gitignored — they hold personal
/// agenda content. If the file is missing we return None and the calling
/// test skips, which makes a fresh clone build cleanly even before
/// `daemon/tests/golden/regenerate.sh` has been run.
fn read_golden(name: &str) -> Option<String> {
    fs::read_to_string(golden_dir().join(name)).ok()
}

fn assert_round_trip<T: DeserializeOwned + Serialize>(filename: &str) {
    let Some(raw) = read_golden(filename) else {
        eprintln!(
            "skipping {filename}: capture goldens with daemon/tests/golden/regenerate.sh"
        );
        return;
    };
    let value: T = serde_json::from_str(&raw)
        .unwrap_or_else(|e| panic!("deserialize {filename}: {e}"));
    let re_emitted = serde_json::to_string(&value).unwrap();
    let parsed_orig: serde_json::Value = serde_json::from_str(&raw).unwrap();
    let parsed_round: serde_json::Value = serde_json::from_str(&re_emitted).unwrap();
    assert_eq!(
        parsed_orig, parsed_round,
        "round-trip mismatch in {filename}"
    );
}

#[test]
fn tasks_round_trip() {
    assert_round_trip::<Vec<OrgTask>>("tasks.json");
}

#[test]
fn tasks_all_round_trip() {
    assert_round_trip::<Vec<OrgTask>>("tasks_all_true.json");
}

#[test]
fn files_round_trip() {
    assert_round_trip::<Vec<AgendaFile>>("files.json");
}

#[test]
fn keywords_round_trip() {
    assert_round_trip::<TodoKeywords>("keywords.json");
}

#[test]
fn priorities_round_trip() {
    assert_round_trip::<OrgPriorities>("priorities.json");
}

#[test]
fn config_round_trip() {
    assert_round_trip::<OrgConfig>("config.json");
}

#[test]
fn list_config_round_trip() {
    assert_round_trip::<OrgListConfig>("list-config.json");
}

#[test]
fn capture_templates_round_trip() {
    assert_round_trip::<Vec<CaptureTemplate>>("capture_templates.json");
}

#[test]
fn refile_targets_round_trip() {
    assert_round_trip::<Vec<RefileTarget>>("refile_targets.json");
}

#[test]
fn clock_round_trip() {
    assert_round_trip::<ClockStatus>("clock.json");
}

#[test]
fn agenda_days_round_trip() {
    let dir = golden_dir();
    let read = match fs::read_dir(&dir) {
        Ok(it) => it,
        Err(_) => {
            eprintln!("skipping agenda_days_round_trip: {} not present", dir.display());
            return;
        }
    };
    let mut count = 0;
    for entry in read {
        let entry = entry.expect("dir entry");
        let path = entry.path();
        let name = match path.file_name().and_then(|s| s.to_str()) {
            Some(n) => n,
            None => continue,
        };
        if !name.starts_with("agenda_day_") || !name.ends_with(".json") {
            continue;
        }
        let raw = fs::read_to_string(&path).expect("read agenda day");
        let parsed: Vec<AgendaEntry> = serde_json::from_str(&raw)
            .unwrap_or_else(|e| panic!("deserialize {name}: {e}"));
        let re_emitted = serde_json::to_string(&parsed).unwrap();
        let parsed_orig: serde_json::Value = serde_json::from_str(&raw).unwrap();
        let parsed_round: serde_json::Value = serde_json::from_str(&re_emitted).unwrap();
        assert_eq!(parsed_orig, parsed_round, "round-trip mismatch in {name}");
        count += 1;
    }
    if count == 0 {
        eprintln!(
            "skipping agenda_days_round_trip: no goldens in {} (run regenerate.sh)",
            dir.display()
        );
    }
}
