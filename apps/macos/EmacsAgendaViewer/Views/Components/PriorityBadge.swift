import SwiftUI

/// Priority shown as a square pill matching `TodoStatePill` — tinted
/// background + matching foreground letter. Color comes from the user's
/// per-priority palette (see AppSettings.resolvedPriorityColor) so a
/// recolored priority A propagates here automatically.
struct PriorityBadge: View {
    @Environment(AppSettings.self) private var settings
    let priority: String

    var body: some View {
        let _ = settings.colorRevision
        Text(priority.uppercased())
            .font(.caption2.weight(.semibold))
            .tracking(0.5)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(color.opacity(0.15))
            )
            .accessibilityLabel("Priority \(priority.uppercased())")
    }

    private var color: Color {
        settings.resolvedPriorityColor(for: priority)
    }
}
