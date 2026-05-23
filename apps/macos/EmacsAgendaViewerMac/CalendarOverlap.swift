import SwiftUI

/// Pure overlap-layout engine for the calendar time grid.
///
/// All functions are static so they can be called from views and tested
/// without any SwiftUI environment. `hourHeight` and `startHour` are passed
/// explicitly to keep the math self-contained.
enum CalendarOverlap {

    struct EventLayout {
        let y: CGFloat
        let height: CGFloat
        let durationMinutes: Int
    }

    struct PlacedItem {
        let item: CalendarGridItem
        let layout: EventLayout
        let lane: Int
        let groupSize: Int
    }

    /// Compute the pixel y-offset and height for one calendar grid item.
    ///
    /// Returns `nil` if the item has no start date (all-day items are
    /// excluded before this is called).
    static func computeLayout(
        _ item: CalendarGridItem,
        on day: Date,
        hourHeight: CGFloat,
        startHour: Int
    ) -> EventLayout? {
        guard let s = item.startDate else { return nil }
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: day)
        let startSec = s.timeIntervalSince(dayStart)
        let startMin = Int(startSec / 60) - startHour * 60
        let y = CGFloat(startMin) / 60.0 * hourHeight

        if item.isDeadlineOnly {
            return EventLayout(y: max(0, y), height: 18, durationMinutes: 0)
        }

        var duration = 60
        if let e = item.endDate, e > s {
            let mins = Int(e.timeIntervalSince(s) / 60)
            if mins > 0 { duration = mins }
        }
        let height = max(20, CGFloat(duration) / 60.0 * hourHeight)
        return EventLayout(y: max(0, y), height: height, durationMinutes: duration)
    }

    /// Assign lane indices to a list of timed items so overlapping events are
    /// displayed side-by-side rather than stacked.
    ///
    /// Algorithm:
    /// 1. Compute pixel layout for each item; drop items with no start date.
    /// 2. Sort by y (top edge).
    /// 3. Group consecutive items that share any vertical overlap.
    /// 4. Within each group, greedily assign the first available lane whose
    ///    bottom is at or above the current item's top.
    static func placeItems(
        _ items: [CalendarGridItem],
        on day: Date,
        hourHeight: CGFloat,
        startHour: Int
    ) -> [PlacedItem] {
        let pairs: [(CalendarGridItem, EventLayout)] = items
            .compactMap { i in
                computeLayout(i, on: day, hourHeight: hourHeight, startHour: startHour)
                    .map { (i, $0) }
            }
            .sorted { $0.1.y < $1.1.y }

        let slots = pairs.map { (y: $0.1.y, height: $0.1.height) }
        let assignments = CalendarLaneAssign.assignLanes(slots: slots)

        return zip(pairs, assignments).map { pair, assignment in
            PlacedItem(item: pair.0, layout: pair.1, lane: assignment.lane, groupSize: assignment.groupSize)
        }
    }
}
