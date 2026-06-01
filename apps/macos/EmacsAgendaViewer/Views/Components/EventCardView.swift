#if !os(macOS)
import SwiftUI

/// A dense Things-3-style card containing all events for a given day as a
/// single List row. Each event occupies one ~22 pt line: a 3 pt colored bar
/// (calendar color keyed on category, fallback accent), a fixed-width muted
/// time column, then the event title truncated to one line.
///
/// Rendered as one list row so SwiftUI's per-row minimum height / inset
/// overhead applies only once regardless of how many events there are.
struct EventCardView: View {
    let entries: [AgendaEntry]

    @Environment(AppSettings.self) private var settings

    // Collapsed by default; "+N more" button reveals the rest.
    @State private var expanded = false

    private static let collapsedMax = 4

    private var visibleEntries: [AgendaEntry] {
        guard !expanded, entries.count > Self.collapsedMax else { return entries }
        return Array(entries.prefix(Self.collapsedMax))
    }

    private var hiddenCount: Int {
        guard !expanded else { return 0 }
        return max(0, entries.count - Self.collapsedMax)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(visibleEntries) { entry in
                eventLine(entry)
                    .contextMenu {
                        ForEach(uniqueTags(for: entry), id: \.self) { tag in
                            Button {
                                settings.hideEventTag(tag)
                            } label: {
                                Label("Hide events tagged \(tag)", systemImage: "eye.slash")
                            }
                        }
                    }
            }
            if hiddenCount > 0 {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { expanded = true }
                } label: {
                    Text("+\(hiddenCount) more")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .padding(.top, 3)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.surface)
        )
    }

    @ViewBuilder
    private func eventLine(_ entry: AgendaEntry) -> some View {
        HStack(spacing: 8) {
            // Colored calendar-source bar.
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(barColor(for: entry))
                .frame(width: 3, height: 16)
                .accessibilityHidden(true)

            Text(timeLabel(for: entry))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 52, alignment: .leading)
                .lineLimit(1)

            Text(entry.title)
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(for: entry))
    }

    private func barColor(for entry: AgendaEntry) -> Color {
        if !entry.category.isEmpty,
           let hex = settings.categoryColorHex(for: entry.category),
           let c = Color(hex: hex) {
            return c
        }
        return Theme.accent
    }

    private func timeLabel(for entry: AgendaEntry) -> String {
        if let t = entry.timeOfDay, !t.isEmpty { return t }
        return "all-day"
    }

    private func accessibilityLabel(for entry: AgendaEntry) -> String {
        var parts: [String] = ["Event: \(entry.title)", timeLabel(for: entry)]
        if !entry.category.isEmpty { parts.append(entry.category) }
        return parts.joined(separator: ", ")
    }

    private func uniqueTags(for entry: AgendaEntry) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for tag in entry.tags + entry.inheritedTags where !tag.isEmpty {
            if seen.insert(tag).inserted { ordered.append(tag) }
        }
        return ordered
    }
}
#endif
