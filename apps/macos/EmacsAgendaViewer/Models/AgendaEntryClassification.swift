import Foundation

/// Classifies an `AgendaEntry` row as a calendar event vs a regular task.
///
/// Agenda types `timestamp`, `block`, and `sexp` with no TODO state are
/// timestamp-driven entries (org diary sexps, calendar blocks, plain
/// `<YYYY-MM-DD>` timestamps) — they don't have an associated org file
/// position the user can navigate to, so they should be rendered as
/// banners rather than tappable rows.
///
/// Lives in the shared layer so both iOS and Mac can partition lists
/// identically. (The Mac version of this file used to live next to
/// `MacEventBanners` but moved here when iOS gained its own Today view.)
enum AgendaEntryClassification {
    static let eventTypes: Set<String> = ["timestamp", "block", "sexp"]

    static func isEvent(_ entry: AgendaEntry) -> Bool {
        eventTypes.contains(entry.agendaType) && (entry.todoState?.isEmpty ?? true)
    }
}
