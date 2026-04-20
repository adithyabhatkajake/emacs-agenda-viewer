import SwiftUI

struct DateBadge: View {
    enum Kind {
        case scheduled, deadline

        var icon: String {
            switch self {
            case .scheduled: return "calendar"
            case .deadline: return "exclamationmark.circle"
            }
        }
    }

    let timestamp: OrgTimestamp
    let kind: Kind

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: kind.icon)
                .font(.system(size: 9, weight: .semibold))
            Text(formatted)
                .font(.caption2)
        }
        .foregroundStyle(color)
    }

    private var formatted: String {
        guard let date = timestamp.parsedDate else { return timestamp.raw }
        return DateBadge.relativeLabel(for: date)
    }

    private var color: Color {
        guard kind == .deadline, let date = timestamp.parsedDate else {
            return Theme.textSecondary
        }
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()), to: Calendar.current.startOfDay(for: date)).day ?? 0
        if days < 0 { return Theme.priorityA }
        if days <= 2 { return Theme.priorityB }
        return Theme.textSecondary
    }

    static func relativeLabel(for date: Date) -> String {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let target = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: today, to: target).day ?? 0
        switch days {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        case 2...6:
            let f = DateFormatter()
            f.dateFormat = "EEEE"
            return f.string(from: date)
        default:
            let f = DateFormatter()
            f.dateFormat = days >= -6 && days < 0 ? "'Last' EEEE" : "MMM d"
            return f.string(from: date)
        }
    }
}
