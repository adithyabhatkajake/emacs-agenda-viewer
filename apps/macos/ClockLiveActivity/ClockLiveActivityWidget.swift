import ActivityKit
import SwiftUI
import WidgetKit

// Theme colors duplicated here because the widget extension is a separate
// process and cannot import the app target's Theme.swift. Values kept in sync
// with Theme.swift doneGreen / priorityA / textTertiary / textSecondary.
private extension Color {
    // Theme.doneGreen (light: #34C759, dark: #30D158)
    static let doneGreen = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 48/255, green: 209/255, blue: 88/255, alpha: 1)
            : UIColor(red: 52/255, green: 199/255, blue: 89/255, alpha: 1)
    })
    // Theme.textTertiary
    static let clockTertiary = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 134/255, green: 134/255, blue: 140/255, alpha: 1)
            : UIColor(red: 174/255, green: 174/255, blue: 178/255, alpha: 1)
    })
    // Theme.textSecondary
    static let clockSecondary = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 176/255, green: 176/255, blue: 182/255, alpha: 1)
            : UIColor(red: 110/255, green: 110/255, blue: 115/255, alpha: 1)
    })
}

struct ClockLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ClockActivityAttributes.self) { context in
            lockScreenView(context: context)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .activityBackgroundTint(Color.doneGreen.opacity(0.10))
                .activitySystemActionForegroundColor(.primary)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    leadingExpanded(context: context)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    trailingExpanded(context: context)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    bottomExpanded(context: context)
                }
                DynamicIslandExpandedRegion(.center) {
                    EmptyView()
                }
            } compactLeading: {
                Image(systemName: "stopwatch.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.doneGreen)
            } compactTrailing: {
                compactTrailingView(context: context)
            } minimal: {
                minimalView(context: context)
            }
            .keylineTint(Color.doneGreen)
        }
    }

    // MARK: - Compact trailing

    @ViewBuilder
    private func compactTrailingView(context: ActivityViewContext<ClockActivityAttributes>) -> some View {
        if let primary = context.state.clocks.first {
            HStack(spacing: 2) {
                elapsedText(startedAt: primary.startedAt)
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Color.doneGreen)
                if context.state.clocks.count >= 2 {
                    Text("·\(context.state.clocks.count)")
                        .font(.system(size: 11, weight: .regular).monospacedDigit())
                        .foregroundStyle(Color.clockSecondary)
                }
            }
        }
    }

    // MARK: - Minimal

    @ViewBuilder
    private func minimalView(context: ActivityViewContext<ClockActivityAttributes>) -> some View {
        let count = context.state.clocks.count
        if count >= 2 {
            Text("\(count)")
                .font(.system(size: 13, weight: .bold).monospacedDigit())
                .foregroundStyle(Color.doneGreen)
        } else {
            Image(systemName: "stopwatch.fill")
                .foregroundStyle(Color.doneGreen)
        }
    }

    // MARK: - Expanded: leading

    @ViewBuilder
    private func leadingExpanded(context: ActivityViewContext<ClockActivityAttributes>) -> some View {
        let count = context.state.clocks.count
        HStack(spacing: 6) {
            PulsingDot()
                .frame(width: 8, height: 8)
            Text(count >= 2 ? "\(count) RUNNING" : "CLOCKED IN")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(Color.clockTertiary)
        }
    }

    // MARK: - Expanded: trailing

    @ViewBuilder
    private func trailingExpanded(context: ActivityViewContext<ClockActivityAttributes>) -> some View {
        if let primary = context.state.clocks.first {
            elapsedText(startedAt: primary.startedAt)
                .font(.system(size: 22, weight: .bold).monospacedDigit())
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .foregroundStyle(Color.doneGreen)
        }
    }

    // MARK: - Expanded: bottom

    @ViewBuilder
    private func bottomExpanded(context: ActivityViewContext<ClockActivityAttributes>) -> some View {
        let clocks = context.state.clocks
        if clocks.count == 1, let only = clocks.first {
            // Single clock: title + start time
            VStack(alignment: .leading, spacing: 3) {
                Text(only.title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Started \(only.startedAt, format: .dateTime.hour().minute())")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.clockSecondary)
            }
            .padding(.top, 4)
        } else if !clocks.isEmpty {
            // Multi-clock: stacked roster, up to 3 visible rows
            let visible = Array(clocks.prefix(3))
            let overflow = clocks.count - visible.count
            VStack(alignment: .leading, spacing: 4) {
                ForEach(visible, id: \.taskId) { entry in
                    rosterRow(entry: entry)
                }
                if overflow > 0 {
                    Text("+\(overflow) more")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.clockTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.top, 4)
        }
    }

    // MARK: - Lock screen

    @ViewBuilder
    private func lockScreenView(context: ActivityViewContext<ClockActivityAttributes>) -> some View {
        let clocks = context.state.clocks
        if clocks.count == 1, let only = clocks.first {
            // Single clock: eyebrow + title + bottom row with start time / hero elapsed
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    PulsingDot()
                        .frame(width: 8, height: 8)
                    Text("CLOCKED IN")
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.8)
                        .textCase(.uppercase)
                        .foregroundStyle(Color.clockTertiary)
                }
                Text(only.title)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    Text("Started \(only.startedAt, format: .dateTime.hour().minute())")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.clockSecondary)
                    Spacer(minLength: 8)
                    elapsedText(startedAt: only.startedAt)
                        .font(.system(size: 28, weight: .bold).monospacedDigit())
                        .foregroundStyle(Color.doneGreen)
                }
            }
        } else if !clocks.isEmpty {
            // Multi-clock: eyebrow + roster (up to 4 rows) + optional overflow
            let visible = Array(clocks.prefix(4))
            let overflow = clocks.count - visible.count
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    PulsingDot()
                        .frame(width: 8, height: 8)
                    Text("\(clocks.count) CLOCKS RUNNING")
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.8)
                        .textCase(.uppercase)
                        .foregroundStyle(Color.clockTertiary)
                }
                ForEach(visible, id: \.taskId) { entry in
                    rosterRow(entry: entry)
                }
                if overflow > 0 {
                    Text("+\(overflow) more")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.clockTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: - Shared roster row (expanded bottom + lock screen multi)

    @ViewBuilder
    private func rosterRow(entry: ClockActivityAttributes.ContentState.Entry) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.doneGreen)
                .frame(width: 5, height: 5)
            Text(entry.title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            elapsedText(startedAt: entry.startedAt)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(Color.doneGreen)
                .multilineTextAlignment(.trailing)
        }
    }

    // MARK: - Timer helper

    /// Text(timerInterval:) ticks once a second without re-running widget code.
    /// 24-hour window is the cap; the daemon guardrail limits practical use.
    private func elapsedText(startedAt: Date) -> Text {
        Text(
            timerInterval: startedAt ... startedAt.addingTimeInterval(86_400),
            pauseTime: nil,
            countsDown: false,
            showsHours: true
        )
    }
}

// MARK: - Pulsing dot (mirrors ClockCard's pulse animation)

private struct PulsingDot: View {
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(Color.doneGreen)
            .opacity(pulse ? 0.4 : 1.0)
            .scaleEffect(pulse ? 0.85 : 1.0)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = true }
    }
}
