import Foundation

/// Pure, EventKit-free logic for building deterministic drag-payload identifiers
/// for calendar events. Lives in the shared layer so the SPM test target can
/// cover it without linking EventKit.
enum CalendarStableId {

    // Prefix used for the deterministic fallback. EventKitService.findEvent(stableId:)
    // checks for this prefix to route to the linear scan path.
    static let localPrefix = "local:"

    /// Return a stable string identifier for an EKEvent, given the properties
    /// available to `CalendarGridItem`. Priority:
    ///   1. `eventIdentifier` — always present on committed EKEvents.
    ///   2. `externalIdentifier` — present on synced events; may be nil locally.
    ///   3. Deterministic hash of `(title, start, end, calendarId)` — fallback for
    ///      events that have neither identifier (should be rare).
    static func makeStableId(
        eventIdentifier: String?,
        externalIdentifier: String?,
        title: String,
        start: Date,
        end: Date?,
        calendarId: String
    ) -> String {
        if let id = eventIdentifier { return id }
        if let id = externalIdentifier { return id }
        return makeLocalId(title: title, start: start, end: end, calendarId: calendarId)
    }

    /// Build the deterministic local-event id. Exposed for `findEvent(stableId:)`
    /// to reconstruct and compare without re-calling `makeStableId`.
    static func makeLocalId(title: String, start: Date, end: Date?, calendarId: String) -> String {
        let endInterval = end?.timeIntervalSinceReferenceDate ?? -1
        return "\(localPrefix)\(title)|\(start.timeIntervalSinceReferenceDate)|\(endInterval)|\(calendarId)"
    }

    /// True when the id was produced by `makeLocalId` and must be resolved by
    /// scanning `visibleEvents` rather than by an EKEventStore lookup.
    static func isLocalId(_ id: String) -> Bool {
        id.hasPrefix(localPrefix)
    }
}
