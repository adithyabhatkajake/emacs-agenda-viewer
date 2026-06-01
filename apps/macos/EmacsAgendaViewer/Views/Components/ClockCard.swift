#if !os(macOS)
import SwiftUI

/// Stack of currently-clocked sessions rendered above the Today summary
/// chips. Uses `ClockManager.sessions` (the local-only multi-clock model
/// shared with the Mac app) — see `ClockManager.swift` for the rationale
/// behind running multiple clocks in parallel against single-clock org.
struct ClockCard: View {
    @Environment(ClockManager.self) private var clocks
    @Environment(AppSettings.self) private var settings
    let store: TasksStore

    @State private var pulse: Bool = false

    var body: some View {
        if !clocks.sessions.isEmpty {
            // TimelineView fires only while this node is in the rendered hierarchy
            // (i.e. sessions are non-empty and the view is on-screen).
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(spacing: 6) {
                    ForEach(clocks.sessions) { session in
                        sessionRow(session, now: context.date)
                    }
                    if let err = clocks.lastStopError {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(Theme.priorityA)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                    }
                }
                .onAppear { pulse = true }
            }
        }
    }

    /// Returns a VoiceOver-friendly elapsed string: "2 hours 5 minutes" rather
    /// than the digit-colon format VoiceOver would read character-by-character.
    private func spokenElapsed(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        var parts: [String] = []
        if hours == 1 { parts.append("1 hour") }
        else if hours > 1 { parts.append("\(hours) hours") }
        if minutes == 1 { parts.append("1 minute") }
        else if minutes > 1 { parts.append("\(minutes) minutes") }
        if parts.isEmpty { parts.append("less than a minute") }
        return "Clocked in for \(parts.joined(separator: " "))"
    }

    @ViewBuilder
    private func sessionRow(_ session: Clock, now: Date) -> some View {
        let label = session.title ?? session.taskId
        HStack(spacing: 12) {
            Circle()
                .fill(Theme.doneGreen)
                .frame(width: 8, height: 8)
                .opacity(pulse ? 0.4 : 1.0)
                .scaleEffect(pulse ? 0.85 : 1.0)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Clocked in")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.2)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.textTertiary)
                Text(label)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 8)

            let elapsed = ClockManager.elapsed(for: session, now: now)
            Text(ClockManager.formatElapsed(elapsed))
                .font(.system(size: 18, weight: .bold).monospacedDigit())
                .tracking(-0.2)
                .foregroundStyle(Theme.textPrimary)
                .accessibilityLabel(spokenElapsed(elapsed))

            Button {
                Task {
                    guard let client = settings.apiClient else { return }
                    _ = await clocks.stop(taskId: session.taskId, using: client, store: store)
                }
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.priorityA)
                    .frame(width: 30, height: 30)
                    .background(Theme.priorityA.opacity(0.15), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop clock for \(label)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.borderSubtle, lineWidth: 0.5)
        )
    }
}
#endif
