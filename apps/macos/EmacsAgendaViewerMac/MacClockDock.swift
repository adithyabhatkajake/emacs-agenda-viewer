import SwiftUI

struct MacClockDock: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ClockManager.self) private var clocks
    let store: TasksStore

    var body: some View {
        // Read tick so the elapsed labels re-render every second; we
        // intentionally avoid putting `.id(clocks.tick)` here because that
        // would re-create child views and lose in-flight button taps.
        let _ = clocks.tick
        if clocks.sessions.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "stopwatch.fill")
                        .foregroundStyle(Theme.priorityB)
                    Text("ACTIVE CLOCKS  \(clocks.sessions.count)")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.6)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                }
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(clocks.sessions) { session in
                        sessionPill(session)
                    }
                }
                if let err = clocks.lastStopError {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.priorityA)
                        Text(err)
                            .font(.caption2)
                            .foregroundStyle(Theme.priorityA)
                            .lineLimit(2)
                        Spacer()
                        Button {
                            clocks.lastStopError = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textTertiary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 4)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Theme.surface.opacity(0.85))
            .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.borderSubtle), alignment: .bottom)
        }
    }

    private func sessionPill(_ session: ClockManager.Session) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if !session.category.isEmpty {
                        Text(session.category)
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Text(ClockManager.formatElapsed(session.elapsed()))
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.priorityB)
                }
            }
            Spacer(minLength: 8)

            Button {
                Task {
                    guard let client = settings.apiClient else { return }
                    await clocks.stop(taskId: session.id, using: client, store: store)
                }
            } label: {
                Image(systemName: "stop.circle.fill")
                    .foregroundStyle(Theme.priorityA)
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)
            .help("Stop and log")

            Button {
                clocks.cancel(taskId: session.id)
            } label: {
                Image(systemName: "xmark.circle")
                    .foregroundStyle(Theme.textTertiary)
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .help("Cancel without logging")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.surfaceElevated)
        )
    }
}
