import SwiftUI

/// Non-tappable row for calendar events (agendaType timestamp/block/sexp
/// with no TODO state). These entries come from org diary sexps or
/// timestamp-only headings and have no file/pos to navigate to, so the
/// row deliberately renders without a NavigationLink and without a
/// checkbox affordance.
///
/// Mac uses `MacEventBanners` for the same purpose; iOS folds it inline
/// to keep the Today/Upcoming lists scrolling as a single List.
struct EventRow: View {
    let entry: AgendaEntry

    #if !os(macOS)
    @Environment(AppSettings.self) private var settings
    #endif

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Calendar bullet — visually distinct from task checkboxes.
            Image(systemName: "calendar")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 18)
                .padding(.top, 4)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title)
                    .font(.body)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    if !entry.category.isEmpty {
                        Text(entry.category)
                            .font(.caption2)
                            .foregroundStyle(Theme.textTertiary)
                    }
                    if let t = entry.timeOfDay, !t.isEmpty {
                        Text(t)
                            .font(.caption2.monospaced())
                            .foregroundStyle(Theme.textSecondary)
                    }
                    let labelTag = entry.tags.first ?? entry.inheritedTags.first
                    if let tag = labelTag {
                        Text(tag)
                            .font(.caption2.monospaced())
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(Theme.surface)
                            )
                    }
                }
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(rowAccessibilityLabel)
        #if !os(macOS)
        .contextMenu {
            // One "Hide events tagged <tag>" item per unique tag — direct
            // first (more specific), then inherited. Mac branch skips this
            // because Mac uses MacEventBanners with its own visibility UI.
            ForEach(uniqueTags, id: \.self) { tag in
                Button {
                    settings.hideEventTag(tag)
                } label: {
                    Label("Hide events tagged \(tag)", systemImage: "eye.slash")
                }
            }
        }
        #endif
    }

    private var rowAccessibilityLabel: String {
        var parts: [String] = ["Event: \(entry.title)"]
        if let t = entry.timeOfDay, !t.isEmpty { parts.append(t) }
        if !entry.category.isEmpty { parts.append(entry.category) }
        return parts.joined(separator: ", ")
    }

    #if !os(macOS)
    /// Tags rendered in the context menu — order preserves "direct first",
    /// then inherited; duplicates removed in-place.
    private var uniqueTags: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for tag in entry.tags + entry.inheritedTags where !tag.isEmpty {
            if seen.insert(tag).inserted { ordered.append(tag) }
        }
        return ordered
    }
    #endif
}
