import ActivityKit
import SwiftUI
import WidgetKit

/// Live Activity for a single `ClockManager` session. One Activity per
/// clocked task — iOS handles stacking on the lock screen and in the
/// Dynamic Island. Elapsed time renders via SwiftUI's `Text(timerInterval:)`
/// which self-ticks from `attributes.startedAt`, so we don't burn the
/// per-second update budget on every active clock.
struct ClockLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ClockActivityAttributes.self) { context in
            // Lock-screen / banner view
            lockScreenView(context: context)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                // Subtle accent-tinted background.
                .activityBackgroundTint(Color.accentColor.opacity(0.08))
                .activitySystemActionForegroundColor(Color.primary)
        } dynamicIsland: { context in
            DynamicIsland {
                // Leading/trailing are width-constrained by the camera cutout
                // — putting the title there forces a "Prepare…" truncation
                // even when the bar is full-width. Move the title to the
                // .bottom region (full width) and keep leading/trailing as
                // glyph + timer.
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        Image(systemName: "stopwatch.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color.green)
                        Text("Clocked in")
                            .font(.system(size: 11, weight: .semibold))
                            .tracking(0.8)
                            .textCase(.uppercase)
                            .foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    elapsedText(startedAt: context.attributes.startedAt)
                        .font(.system(size: 20, weight: .bold).monospacedDigit())
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .foregroundStyle(Color.green)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.title)
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if !context.attributes.category.isEmpty {
                            Text(context.attributes.category)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.top, 2)
                }
            } compactLeading: {
                // Stopwatch glyph anchors the leading slot — a bare green dot
                // looked unmoored next to the trailing timer with the camera
                // cutout in between.
                Image(systemName: "stopwatch.fill")
                    .foregroundStyle(Color.green)
            } compactTrailing: {
                elapsedText(startedAt: context.attributes.startedAt)
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
            } minimal: {
                Image(systemName: "stopwatch.fill")
                    .foregroundStyle(Color.green)
            }
            .keylineTint(Color.accentColor)
        }
    }

    @ViewBuilder
    private func lockScreenView(context: ActivityViewContext<ClockActivityAttributes>) -> some View {
        HStack(spacing: 12) {
            liveDot
                .frame(width: 10, height: 10)
            // Title column grabs all remaining width so the timer ends up
            // flush against the trailing edge. A naked Spacer between them
            // collapses in the LA banner context — `Text(timerInterval:)`
            // reserves an internal width that makes the surrounding HStack
            // shrink-wrap unless we explicitly stretch the title side.
            VStack(alignment: .leading, spacing: 2) {
                Text("Clocked in")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.2)
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                Text(context.attributes.title)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                if !context.attributes.category.isEmpty {
                    Text(context.attributes.category)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            elapsedText(startedAt: context.attributes.startedAt)
                .font(.system(size: 20, weight: .bold).monospacedDigit())
                .multilineTextAlignment(.trailing)
        }
    }

    /// `Text(timerInterval:)` ticks once a second without re-running widget
    /// code. We stamp a 24-hour window because the timer needs an end date;
    /// the daemon-side guardrail caps practical use well below this.
    private func elapsedText(startedAt: Date) -> Text {
        Text(
            timerInterval: startedAt...startedAt.addingTimeInterval(86_400),
            pauseTime: nil,
            countsDown: false,
            showsHours: true
        )
    }

    private var liveDot: some View {
        Circle()
            .fill(Color.green)
    }
}
