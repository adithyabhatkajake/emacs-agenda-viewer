import SwiftUI

enum AgendaEntryClassification {
    static let eventTypes: Set<String> = ["timestamp", "block", "sexp"]

    static func isEvent(_ entry: AgendaEntry) -> Bool {
        eventTypes.contains(entry.agendaType) && (entry.todoState?.isEmpty ?? true)
    }
}

struct MacEventBanners: View {
    let entries: [AgendaEntry]
    var showHeader: Bool = false

    var body: some View {
        if entries.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if showHeader {
                    Text("ALL DAY")
                        .font(.system(size: 10, weight: .heavy))
                        .tracking(0.6)
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.leading, 14)
                }
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(entries) { entry in
                        EventBanner(entry: entry)
                    }
                }
            }
        }
    }
}

struct EventBanner: View {
    let entry: AgendaEntry

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(barColor)
                .frame(width: 3, height: 22)

            Text(timeLabel ?? "all-day")
                .font(.system(size: 11, design: .monospaced).monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
                .frame(minWidth: 90, alignment: .leading)

            Text(entry.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)

            Spacer(minLength: 8)

            if let cal = calendarLabel {
                Text(cal)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                    .textCase(.lowercase)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Theme.borderSubtle, lineWidth: 0.5)
        )
    }

    private var barColor: Color {
        switch entry.agendaType {
        case "block": return Theme.priorityB
        case "sexp": return Theme.priorityC
        default: return Theme.accent
        }
    }

    private var timeLabel: String? {
        let start = startTime
        let end = endTime
        if let s = start, let e = end { return "\(s)–\(e)" }
        if let s = start { return s }
        return nil
    }

    private var startTime: String? {
        if let t = entry.timeOfDay, !t.isEmpty {
            // entry.timeOfDay can be "HH:MM" or "HH:MM-HH:MM"
            let parts = t.split(separator: "-")
            if let first = parts.first { return String(first) }
            return t
        }
        if let s = entry.scheduled?.start, let h = s.hour {
            return String(format: "%02d:%02d", h, s.minute ?? 0)
        }
        if let d = entry.deadline?.start, let h = d.hour {
            return String(format: "%02d:%02d", h, d.minute ?? 0)
        }
        return nil
    }

    private var endTime: String? {
        if let t = entry.timeOfDay, !t.isEmpty {
            let parts = t.split(separator: "-")
            if parts.count >= 2 { return String(parts[1]) }
        }
        if let e = entry.scheduled?.end, let h = e.hour {
            return String(format: "%02d:%02d", h, e.minute ?? 0)
        }
        if let e = entry.deadline?.end, let h = e.hour {
            return String(format: "%02d:%02d", h, e.minute ?? 0)
        }
        return nil
    }

    private var calendarLabel: String? {
        if !entry.category.isEmpty { return entry.category }
        return nil
    }
}
