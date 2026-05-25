#if !os(macOS)
import SwiftUI

/// Single-line compact event row for the Home view's Events section.
///
/// Renders a small time label (or "all-day") plus the event title on one muted
/// line — much lighter than `EventRow`, which uses a card-style layout with a
/// calendar icon and a secondary metadata row. The compact form is appropriate
/// in a dense home feed where events share space with pinned tasks and scheduled
/// items and should not dominate visually.
///
/// Keeps the same context-menu hide-tag affordance as `EventRow` so the user
/// can still suppress noisy calendars without switching views.
struct CompactEventRow: View {
    let entry: AgendaEntry

    @Environment(AppSettings.self) private var settings

    var body: some View {
        HStack(spacing: 8) {
            Text(timeLabel)
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
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .contextMenu {
            ForEach(uniqueTags, id: \.self) { tag in
                Button {
                    settings.hideEventTag(tag)
                } label: {
                    Label("Hide events tagged \(tag)", systemImage: "eye.slash")
                }
            }
        }
    }

    private var timeLabel: String {
        if let t = entry.timeOfDay, !t.isEmpty { return t }
        return "all-day"
    }

    private var accessibilityLabel: String {
        var parts: [String] = ["Event: \(entry.title)", timeLabel]
        if !entry.category.isEmpty { parts.append(entry.category) }
        return parts.joined(separator: ", ")
    }

    /// Direct tags first, then inherited; duplicates removed in insertion order.
    private var uniqueTags: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for tag in entry.tags + entry.inheritedTags where !tag.isEmpty {
            if seen.insert(tag).inserted { ordered.append(tag) }
        }
        return ordered
    }
}
#endif
