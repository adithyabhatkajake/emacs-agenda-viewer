import SwiftUI
import EventKit

struct CalendarDragPayload: Codable {
    enum Kind: String, Codable { case org, ek }
    let kind: Kind
    let id: String
    let file: String
    let pos: Int

    var encoded: String {
        let data = try! JSONEncoder().encode(self)
        return String(data: data, encoding: .utf8)!
    }

    static func decode(from string: String) -> CalendarDragPayload? {
        guard let data = string.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(CalendarDragPayload.self, from: data)
    }
}

/// Unified abstraction for items rendered on the calendar grid: org tasks
/// (from agenda data) and EventKit events.
enum CalendarGridItem: Identifiable {
    case org(AgendaEntry)
    case ek(EKEvent)

    var id: String {
        switch self {
        case .org(let e): return e.id
        case .ek(let e):  return "ek:" + Self.stableId(of: e)
        }
    }

    var title: String {
        switch self {
        case .org(let e): return e.title
        case .ek(let e):  return e.title ?? "(no title)"
        }
    }

    var isDeadlineOnly: Bool {
        switch self {
        case .org(let e):
            return e.scheduled == nil && e.deadline != nil
        case .ek:
            return false
        }
    }

    /// Whether this item appears on the timed grid (has a clock time) or in the all-day strip.
    var isTimed: Bool {
        switch self {
        case .org(let e): return (e.scheduled?.hasTime ?? false) || (e.deadline?.hasTime ?? false)
        case .ek(let e):  return !e.isAllDay
        }
    }

    /// Best-effort start date (used to lay out timed items).
    var startDate: Date? {
        switch self {
        case .org(let e):
            return e.scheduled?.parsedDate ?? e.deadline?.parsedDate
        case .ek(let e):
            return e.startDate
        }
    }

    /// Best-effort end date.
    var endDate: Date? {
        switch self {
        case .org(let e):
            return Self.orgEnd(e) ?? e.scheduled?.parsedDate?.addingTimeInterval(60 * 60)
        case .ek(let e):
            return e.endDate
        }
    }

    /// Default color (no user overrides applied).
    var color: Color {
        switch self {
        case .org(let e):
            return e.category.isEmpty ? Theme.accent : Self.color(forCategory: e.category)
        case .ek(let e):
            #if os(macOS)
            return Color(nsColor: e.calendar.color)
            #else
            return Color(uiColor: e.calendar.color)
            #endif
        }
    }

    /// Resolve the chip color, preferring any per-category override the user
    /// has set in Settings → Categories.
    func resolvedColor(using settings: AppSettings) -> Color {
        if case .org(let e) = self,
           !e.category.isEmpty,
           let hex = settings.categoryColorHex(for: e.category),
           let c = Color(hex: hex) {
            return c
        }
        return color
    }

    /// Stable color per category. Uses a curated palette + a stable string hash
    /// so the same category lands on the same color across launches and devices.
    static func color(forCategory category: String) -> Color {
        let palette: [Color] = [
            Color(red: 0.30, green: 0.62, blue: 0.96),  // blue
            Color(red: 0.95, green: 0.45, blue: 0.40),  // coral
            Color(red: 0.40, green: 0.75, blue: 0.60),  // mint
            Color(red: 0.95, green: 0.62, blue: 0.32),  // orange
            Color(red: 0.60, green: 0.50, blue: 0.90),  // purple
            Color(red: 0.92, green: 0.74, blue: 0.30),  // amber
            Color(red: 0.40, green: 0.78, blue: 0.85),  // teal
            Color(red: 0.88, green: 0.55, blue: 0.78),  // pink
            Color(red: 0.55, green: 0.78, blue: 0.32),  // lime
            Color(red: 0.70, green: 0.60, blue: 0.45),  // taupe
        ]
        var h: UInt32 = 5381
        for byte in category.utf8 { h = h &* 33 &+ UInt32(byte) }
        return palette[Int(h) % palette.count]
    }

    static func stableId(of event: EKEvent) -> String {
        event.calendarItemExternalIdentifier ?? event.eventIdentifier ?? UUID().uuidString
    }

    var dragPayload: String {
        switch self {
        case .org(let e):
            return CalendarDragPayload(kind: .org, id: e.id, file: e.file, pos: e.pos).encoded
        case .ek(let e):
            return CalendarDragPayload(kind: .ek, id: Self.stableId(of: e), file: "", pos: 0).encoded
        }
    }

    private static func orgEnd(_ e: AgendaEntry) -> Date? {
        guard let ts = e.scheduled ?? e.deadline,
              let s = ts.start, let sh = s.hour,
              let end = ts.end, let eh = end.hour,
              end.year == s.year, end.month == s.month, end.day == s.day
        else { return nil }
        let startMin = sh * 60 + (s.minute ?? 0)
        let endMin = eh * 60 + (end.minute ?? 0)
        guard endMin > startMin else { return nil }
        var dc = DateComponents()
        dc.year = end.year; dc.month = end.month; dc.day = end.day
        dc.hour = eh; dc.minute = end.minute ?? 0
        return Calendar.current.date(from: dc)
    }
}

extension OrgTask {
    var dragPayload: String {
        CalendarDragPayload(kind: .org, id: id, file: file, pos: pos).encoded
    }
}
