#if !os(macOS)
import ActivityKit
import Foundation

/// Attributes for the single "clock session" Live Activity.
/// One Activity covers the entire ClockManager.sessions roster — iOS only
/// surfaces one Activity in the Dynamic Island at a time, so a per-task
/// model silently hides all but one when the user is multitasking.
/// ContentState carries the full roster; each Entry's elapsed time
/// self-ticks via Text(timerInterval:), so we only push updates when the
/// roster changes (clock in / clock out), never per-second.
struct ClockActivityAttributes: ActivityAttributes {
    /// Stable identifier so reconcileOnLaunch can find the surviving Activity.
    let sessionId: String

    struct ContentState: Codable, Hashable {
        struct Entry: Codable, Hashable {
            let taskId: String
            let title: String
            let startedAt: Date
        }
        /// Ordered roster, [0] = primary = most-recently-started.
        var clocks: [Entry]
    }
}
#endif
