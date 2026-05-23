import SwiftUI

/// A timed event block that can be resized by dragging its bottom edge.
struct ResizableEvent: View {
    let item: CalendarGridItem
    let color: Color
    let layout: CalendarOverlap.EventLayout
    let hourHeight: CGFloat
    let onTap: () -> Void
    let onResize: (Int) -> Void

    @State private var liveHeightDelta: CGFloat = 0
    @State private var hovered = false

    var body: some View {
        let h = max(20, layout.height + liveHeightDelta)
        ZStack(alignment: .bottom) {
            EventChip(item: item, color: color, compact: false)
                .frame(height: h)
                .onTapGesture(perform: onTap)
            ResizeHandle(active: hovered || liveHeightDelta != 0)
                .gesture(resizeGesture)
                .onHover { hovered = $0 }
        }
        .frame(height: h)
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in liveHeightDelta = value.translation.height }
            .onEnded { value in
                let newHeight = max(20, layout.height + value.translation.height)
                let mins = max(15, Int((newHeight / hourHeight) * 60))
                let snapped = (mins / 15) * 15
                liveHeightDelta = 0
                onResize(snapped)
            }
    }
}

/// Drag handle rendered at the bottom of a `ResizableEvent`.
struct ResizeHandle: View {
    let active: Bool
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(active ? 0.5 : 0.001)) // near-transparent but hit-testable
            .frame(height: 8)
            .overlay(
                Capsule()
                    .fill(Color.white.opacity(active ? 0.7 : 0.3))
                    .frame(width: 28, height: 3)
            )
            .contentShape(Rectangle())
            .help("Drag to resize")
    }
}

/// Horizontal deadline indicator shown at the item's scheduled time.
struct DeadlineMarker: View {
    let item: CalendarGridItem
    let color: Color

    var body: some View {
        HStack(spacing: 0) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Rectangle()
                .fill(color)
                .frame(height: 1.5)
                .frame(maxWidth: 6)
            Text(item.title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 4)
            Rectangle()
                .fill(color.opacity(0.4))
                .frame(height: 1)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help("Deadline: \(item.title)")
    }
}

/// Compact chip used in the all-day strip.
struct AllDayChip: View {
    let item: CalendarGridItem
    let color: Color

    var body: some View {
        HStack(spacing: 3) {
            Rectangle().fill(color).frame(width: 2, height: 10)
            Text(item.title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 3).padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(color.opacity(0.14))
        )
        .help(item.title)
    }
}

/// Chip rendered inside a `ResizableEvent` block on the time grid.
struct EventChip: View {
    let item: CalendarGridItem
    let color: Color
    let compact: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            Rectangle().fill(color).frame(width: 2)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(compact ? 1 : 2)
                if let t = timeText {
                    Text(t)
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4).padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(color.opacity(0.18))
        )
    }

    private var timeText: String? {
        guard let start = item.startDate else { return nil }
        let cal = Calendar.current
        let h = cal.component(.hour, from: start)
        let m = cal.component(.minute, from: start)
        return String(format: "%d:%02d", h, m)
    }
}
