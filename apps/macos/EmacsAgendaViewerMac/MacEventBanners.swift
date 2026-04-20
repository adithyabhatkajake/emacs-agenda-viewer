import SwiftUI

enum AgendaEntryClassification {
    static let eventTypes: Set<String> = ["timestamp", "block", "sexp"]

    static func isEvent(_ entry: AgendaEntry) -> Bool {
        eventTypes.contains(entry.agendaType) && (entry.todoState?.isEmpty ?? true)
    }
}

struct MacEventBanners: View {
    let entries: [AgendaEntry]

    var body: some View {
        if entries.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("EVENTS")
                    .font(.system(size: 9, weight: .bold)).tracking(0.6)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.leading, 4)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(entries) { entry in
                        EventBanner(entry: entry)
                    }
                }
            }
        }
    }
}

private struct EventBanner: View {
    let entry: AgendaEntry

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.accentTeal)
                .frame(width: 16)
            Text(entry.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let time = timeLabel {
                Text(time)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.surfaceElevated.opacity(0.7))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Theme.borderSubtle, lineWidth: 1)
        )
    }

    private var icon: String {
        switch entry.agendaType {
        case "block": return "rectangle.stack"
        case "sexp": return "function"
        default: return "calendar.circle"
        }
    }

    private var timeLabel: String? {
        if let t = entry.timeOfDay, !t.isEmpty { return t }
        if let s = entry.scheduled?.start, let h = s.hour {
            return String(format: "%d:%02d", h, s.minute ?? 0)
        }
        if let d = entry.deadline?.start, let h = d.hour {
            return String(format: "%d:%02d", h, d.minute ?? 0)
        }
        return nil
    }
}
