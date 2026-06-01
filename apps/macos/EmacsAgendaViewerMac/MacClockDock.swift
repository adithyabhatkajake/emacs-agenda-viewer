import SwiftUI

struct MacClockDock: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ClockManager.self) private var clocks
    let store: TasksStore
    /// Called when the user clicks the (non-button) body of a clock row —
    /// the title, priority box, category chip, or elapsed counter. Lets
    /// the host (RootView) navigate to the task in the All Tasks list.
    /// Nil means clicks are inert.
    var onReveal: ((Clock) -> Void)? = nil

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
            ForEach(clocks.sessions) { clock in
                clockRow(clock, now: now)
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
    private func clockRow(_ clock: Clock, now: Date) -> some View {
        let priority = priorityFor(clock)
        let displayTitle = clock.title ?? clock.taskId
        let category = categoryFor(clock)
        HStack(spacing: 10) {
            // Reveal area: everything between the stopwatch and the stop
            // button is one big invisible button. Hit-testing the buttons
            // takes precedence — they live outside this group below.
            Button {
                onReveal?(clock)
            } label: {
                HStack(spacing: 10) {
                    Text("⏰")
                        .font(.system(size: 14))
                        .frame(width: 18)
                    if let p = priority, !p.isEmpty {
                        priorityBox(p)
                    }
                    Text(displayTitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if let cat = category, !cat.isEmpty {
                        Text(cat.uppercased())
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
                    Text(ClockManager.formatElapsed(ClockManager.elapsed(for: clock, now: now)))
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.priorityB)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Reveal task in the current list")
            .disabled(onReveal == nil)
            stopButton(clock)
            cancelButton(clock)
        }
        .padding(.horizontal, 18)
        .frame(height: 40)
        .overlay(alignment: .top) {
            if isNotFirst(clock) {
                Rectangle()
                    .frame(height: 0.5)
                    .foregroundStyle(Theme.borderSubtle)
            }
        }
    }

    private func isNotFirst(_ clock: Clock) -> Bool {
        clocks.sessions.first?.id != clock.id
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

    private func priorityFor(_ clock: Clock) -> String? {
        func find<T: TaskDisplayable>(in tasks: [T]?) -> String? {
            guard let tasks else { return nil }
            let t = tasks.first(where: { $0.id == clock.taskId })
            if let p = t?.priority, !p.isEmpty { return p }
            return nil
        }
        return find(in: store.allTasks.value)
            ?? find(in: store.today.value)
            ?? find(in: store.upcoming.value)
    }

    private func categoryFor(_ clock: Clock) -> String? {
        func find<T: TaskDisplayable>(in tasks: [T]?) -> String? {
            tasks?.first(where: { $0.id == clock.taskId })?.category
        }
        return find(in: store.allTasks.value)
            ?? find(in: store.today.value)
            ?? find(in: store.upcoming.value)
    }

    private func stopButton(_ clock: Clock) -> some View {
        Button {
            Task {
                guard let client = settings.apiClient else { return }
                await clocks.clockOut(clockId: clock.id, using: client)
            }
        } label: {
            Image(systemName: "stop.circle.fill")
                .foregroundStyle(Theme.priorityA)
                .font(.system(size: 16))
        }
        .buttonStyle(.plain)
        .help("Stop and log")
    }

    private func cancelButton(_ clock: Clock) -> some View {
        Button {
            Task {
                guard let client = settings.apiClient else { return }
                await clocks.cancel(clockId: clock.id, using: client)
            }
        } label: {
            Image(systemName: "xmark.circle")
                .foregroundStyle(Theme.textTertiary)
                .font(.system(size: 13))
        }
        .buttonStyle(.plain)
        .help("Cancel without logging")
    }
}
