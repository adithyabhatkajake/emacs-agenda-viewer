import SwiftUI

struct TodoStatePill: View {
    @Environment(AppSettings.self) private var settings
    let state: String
    let isDone: Bool

    var body: some View {
        let _ = settings.colorRevision
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
        settings.resolvedTodoStateColor(for: state, isDone: isDone)
    }

    private var foreground: Color { color }
    private var background: Color { color.opacity(0.15) }
}
