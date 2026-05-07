import SwiftUI

struct MacClockDock: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ClockManager.self) private var clocks
    let store: TasksStore

    var body: some View {
        if clocks.sessions.isEmpty {
            EmptyView()
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                content(now: context.date)
            }
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(clocks.sessions) { session in
                sessionRow(session, now: now)
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
                    Button { clocks.lastStopError = nil } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 6)
                .background(Theme.priorityA.opacity(0.08))
            }
        }
        .background(
            ZStack {
                Theme.surface.opacity(0.85)
                LinearGradient(
                    colors: [Theme.priorityB.opacity(0.10), .clear],
                    startPoint: .leading,
                    endPoint: UnitPoint(x: 0.6, y: 0.5)
                )
            }
        )
        .overlay(alignment: .leading) { pulseStrip }
        .overlay(alignment: .bottom) {
            Rectangle()
                .frame(height: 0.5)
                .foregroundStyle(Theme.borderSubtle)
        }
    }

    private var pulseStrip: some View {
        TimelineView(.periodic(from: .now, by: 0.05)) { ctx in
            let phase = (sin(ctx.date.timeIntervalSince1970 * 2.6) + 1) / 2 // 0..1
            Rectangle()
                .fill(Theme.priorityB)
                .frame(width: 3)
                .opacity(0.55 + 0.45 * phase)
                .shadow(color: Theme.priorityB.opacity(0.6), radius: 6, x: 0, y: 0)
        }
    }

    @ViewBuilder
    private func sessionRow(_ session: ClockManager.Session, now: Date) -> some View {
        let priority = priorityFor(session)
        HStack(spacing: 10) {
            Text("⏰")
                .font(.system(size: 14))
                .frame(width: 18)
            if let p = priority, !p.isEmpty {
                priorityBox(p)
            }
            Text(session.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if !session.category.isEmpty {
                Text(session.category.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Theme.textSecondary.opacity(0.10))
                    )
            }
            Text(ClockManager.formatElapsed(session.elapsed(now: now)))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.priorityB)
            stopButton(session)
            cancelButton(session)
        }
        .padding(.horizontal, 18)
        .frame(height: 40)
        .overlay(alignment: .top) {
            if isNotFirst(session) {
                Rectangle()
                    .frame(height: 0.5)
                    .foregroundStyle(Theme.borderSubtle)
            }
        }
    }

    private func isNotFirst(_ session: ClockManager.Session) -> Bool {
        clocks.sessions.first?.id != session.id
    }

    @ViewBuilder
    private func priorityBox(_ priority: String) -> some View {
        Text(priority.uppercased())
            .font(.system(size: 10, weight: .heavy, design: .monospaced))
            .foregroundStyle(.white)
            .frame(width: 16, height: 16)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(settings.resolvedPriorityColor(for: priority))
            )
    }

    private func priorityFor(_ session: ClockManager.Session) -> String? {
        // Match by id first, then fall back to file+title — the session's id is a
        // file::pos snapshot from clock-in time, which goes stale once CLOCK lines
        // shift the heading's position in the file.
        func find<T: TaskDisplayable>(in tasks: [T]?) -> String? {
            guard let tasks else { return nil }
            let t = tasks.first(where: {
                $0.id == session.id || ($0.file == session.file && $0.title == session.title)
            })
            if let p = t?.priority, !p.isEmpty { return p }
            return nil
        }
        return find(in: store.allTasks.value)
            ?? find(in: store.today.value)
            ?? find(in: store.upcoming.value)
    }

    private func stopButton(_ session: ClockManager.Session) -> some View {
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
    }

    private func cancelButton(_ session: ClockManager.Session) -> some View {
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
}
