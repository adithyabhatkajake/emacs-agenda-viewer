import EventKit

/// Represents the three meaningful authorization states for EventKit calendar access.
///
/// On macOS 14+, the system can grant `.writeOnly` access, which allows creating
/// events but not reading existing ones. Treating this as "no access" causes the
/// view to show a misleading "no events / grant access" message when the user has
/// already granted partial access.
enum CalendarAccess: Equatable {
    case denied
    case writeOnly
    case fullAccess

    var canRead: Bool {
        self == .fullAccess
    }

    var canWrite: Bool {
        self == .fullAccess || self == .writeOnly
    }

    /// Maps an `EKAuthorizationStatus` to the app's access representation.
    ///
    /// `.authorized` is the pre-macOS 14 synonym for `.fullAccess`; both grant read+write.
    /// `.writeOnly` is macOS 14+ only — no read, but event creation works.
    /// All other statuses (`.denied`, `.restricted`, `.notDetermined`) map to `.denied`.
    static func access(from status: EKAuthorizationStatus) -> CalendarAccess {
        switch status {
        case .fullAccess, .authorized:
            return .fullAccess
        case .writeOnly:
            return .writeOnly
        default:
            return .denied
        }
    }
}
