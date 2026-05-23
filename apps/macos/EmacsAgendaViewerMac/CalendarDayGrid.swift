import SwiftUI

/// Single-day time grid with hour rules, event chips, drag-to-create, and
/// drag-to-reschedule support. Stateless with respect to calendar data —
/// all mutations are reported via callbacks to the parent.
struct CalendarDayGrid: View {
    @Environment(AppSettings.self) private var settings
    let day: Date
    let isToday: Bool
    let placed: [CalendarOverlap.PlacedItem]
    let hourHeight: CGFloat
    let startHour: Int
    let endHour: Int
    let onTapItem: (CalendarGridItem) -> Void
    let onResize: (CalendarGridItem, Int) -> Void
    let onDrop: (String, CGFloat) -> Void
    let onCreateAt: (CGFloat) -> Void
    let onCreateRange: (CGFloat, CGFloat) -> Void
    let snapTime: (CGFloat) -> (Int, Int)

    @State private var hoverY: CGFloat?
    @State private var createDragStart: CGFloat?
    @State private var createDragEnd: CGFloat?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                CalendarDropZone(hoverY: $hoverY) { id, point in
                    onDrop(id, point.y)
                    return true
                }

                VStack(spacing: 0) {
                    ForEach(startHour..<endHour, id: \.self) { _ in
                        ZStack(alignment: .top) {
                            Rectangle()
                                .fill(Theme.background)
                                .frame(height: hourHeight)
                            Rectangle()
                                .frame(height: 0.5)
                                .foregroundStyle(Theme.borderSubtle)
                            Rectangle()
                                .frame(height: 0.5)
                                .foregroundStyle(Theme.borderSubtle.opacity(0.4))
                                .offset(y: hourHeight / 2)
                        }
                    }
                }
                .background(isToday ? Theme.accent.opacity(0.04) : Color.clear)
                .allowsHitTesting(false)

                Color.clear
                    .contentShape(Rectangle())
                    .gesture(SpatialTapGesture(count: 2).onEnded { value in
                        onCreateAt(value.location.y)
                    })
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 8)
                            .onChanged { value in
                                createDragStart = value.startLocation.y
                                createDragEnd = value.location.y
                            }
                            .onEnded { value in
                                let startY = value.startLocation.y
                                let endY = value.location.y
                                createDragStart = nil
                                createDragEnd = nil
                                onCreateRange(startY, endY)
                            }
                    )

                ForEach(placed, id: \.item.id) { p in
                    let laneWidth = max(20, geo.size.width / CGFloat(p.groupSize))
                    let color = p.item.resolvedColor(using: settings)
                    if p.item.isDeadlineOnly {
                        DeadlineMarker(item: p.item, color: color)
                            .frame(width: geo.size.width - 4, height: 18)
                            .offset(x: 2, y: p.layout.y)
                            .onTapGesture { onTapItem(p.item) }
                            .draggable(p.item.dragPayload) {
                                DeadlineMarker(item: p.item, color: color).frame(width: 200, height: 18)
                            }
                    } else {
                        ResizableEvent(
                            item: p.item,
                            color: color,
                            layout: p.layout,
                            hourHeight: hourHeight,
                            onTap: { onTapItem(p.item) },
                            onResize: { dur in onResize(p.item, dur) }
                        )
                        .frame(width: laneWidth - 2, alignment: .top)
                        .offset(x: 1 + laneWidth * CGFloat(p.lane), y: p.layout.y)
                        .draggable(p.item.dragPayload) {
                            EventChip(item: p.item, color: color, compact: false).frame(width: 200, height: 40)
                        }
                    }
                }

                if isToday {
                    nowLine(gridWidth: geo.size.width).allowsHitTesting(false)
                }

                if let y = hoverY {
                    snapPreview(at: y, gridWidth: geo.size.width)
                        .allowsHitTesting(false)
                }

                if let start = createDragStart, let end = createDragEnd {
                    createRangePreview(from: start, to: end, gridWidth: geo.size.width)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: geo.size.width)
        }
        .frame(height: CGFloat(endHour - startHour) * hourHeight)
    }

    @ViewBuilder
    private func nowLine(gridWidth: CGFloat) -> some View {
        let cal = Calendar.current
        let now = Date()
        let hour = cal.component(.hour, from: now)
        let minute = cal.component(.minute, from: now)
        let mins = (hour * 60 + minute) - startHour * 60
        if mins >= 0 && mins <= (endHour - startHour) * 60 {
            let y = CGFloat(mins) / 60.0 * hourHeight
            ZStack(alignment: .leading) {
                Rectangle().fill(Theme.priorityA).frame(width: gridWidth, height: 1.5)
                Circle().fill(Theme.priorityA).frame(width: 7, height: 7).offset(x: -3)
            }
            .offset(y: y - 0.75)
        }
    }

    @ViewBuilder
    private func snapPreview(at y: CGFloat, gridWidth: CGFloat) -> some View {
        let (h, m) = snapTime(y)
        let snappedY = CGFloat((h - startHour) * 60 + m) / 60.0 * hourHeight
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Theme.accent)
                .frame(width: gridWidth, height: 2)
            Text(String(format: "%02d:%02d", h, m))
                .font(.system(size: 10, weight: .bold).monospacedDigit())
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Theme.accent)
                )
                .foregroundStyle(.white)
                .offset(x: 4, y: -10)
        }
        .offset(y: snappedY - 1)
    }

    @ViewBuilder
    private func createRangePreview(from startY: CGFloat, to endY: CGFloat, gridWidth: CGFloat) -> some View {
        let (sh, sm) = snapTime(min(startY, endY))
        let (eh, em) = snapTime(max(startY, endY))
        let topPx = CGFloat((sh - startHour) * 60 + sm) / 60.0 * hourHeight
        let botPx = CGFloat((eh - startHour) * 60 + em) / 60.0 * hourHeight
        let height = max(hourHeight / 2, botPx - topPx)

        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Theme.accent.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(Theme.accent.opacity(0.5), lineWidth: 1.5)
                )
                .frame(width: gridWidth - 4, height: height)
            VStack(alignment: .leading, spacing: 0) {
                Text(String(format: "%02d:%02d", sh, sm))
                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                    .foregroundStyle(Theme.accent)
                Spacer(minLength: 0)
                Text(String(format: "%02d:%02d", eh, em))
                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                    .foregroundStyle(Theme.accent)
            }
            .padding(6)
            .frame(height: height)
        }
        .offset(x: 2, y: topPx)
    }
}
