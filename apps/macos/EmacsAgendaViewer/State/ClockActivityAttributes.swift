#if !os(macOS)
import ActivityKit
import Foundation

/// Live-Activity attributes for a single clocked session. One LA per
/// `ClockManager.Session` — see `ClockLiveActivityCoordinator` for the
/// lifecycle wiring. We keep `ContentState` empty in v1 because elapsed
/// time auto-ticks on-screen via SwiftUI's `Text(timerInterval:)` reading
/// `startedAt` from these attributes — no per-second update budget spent.
struct ClockActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {}

    let taskId: String      // matches ClockManager.Session.id (= OrgTask.id)
    let title: String
    let category: String
    let startedAt: Date
}
#endif
