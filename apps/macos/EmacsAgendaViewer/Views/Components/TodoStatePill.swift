import SwiftUI

struct TodoStatePill: View {
    let state: String
    let isDone: Bool

    var body: some View {
        Text(state)
            .font(.caption2.weight(.semibold))
            .tracking(0.5)
            .foregroundStyle(foreground)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(background)
            )
    }

    private var color: Color {
        if isDone { return Theme.doneGreen }
        switch state.uppercased() {
        case "TODO": return Theme.accent
        case "NEXT", "STARTED", "DOING": return Theme.accentTeal
        case "WAITING", "HOLD", "BLOCKED": return Theme.priorityB
        case "CANCELLED", "CANCELED": return Theme.textTertiary
        default: return Theme.accent
        }
    }

    private var foreground: Color { color }
    private var background: Color { color.opacity(0.15) }
}
