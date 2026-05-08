//! Org-mode parser and task extractor.
//!
//! Wraps `orgize` with the project-specific shape: emit one `OrgTask` per
//! heading with a TODO keyword, with tag inheritance, file-local TODO/category
//! overrides, and active-timestamp scanning of the body.

pub mod extract;
pub mod timestamp;

pub use extract::{
    extract_tasks, extract_tasks_from_source, extract_tasks_from_source_with, FileMeta,
    GlobalKeywords,
};
pub use eav_core::OrgTimestamp;
pub use timestamp::{convert as convert_timestamp, extract_active_timestamps, parse_timestamp};
