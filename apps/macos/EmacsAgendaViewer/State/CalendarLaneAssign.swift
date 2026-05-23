import CoreGraphics

/// Lane-assignment result for a single (y, height) slot.
public struct LaneAssignment {
    public let lane: Int
    public let groupSize: Int
    public init(lane: Int, groupSize: Int) {
        self.lane = lane
        self.groupSize = groupSize
    }
}

/// Assigns non-overlapping lane indices to a sorted list of (y, height) slots.
///
/// Input must be sorted ascending by `y`. Returns one `LaneAssignment` per
/// input element in the same order.
///
/// This is the pure geometry kernel extracted from `CalendarOverlap` so it
/// can be unit-tested without EventKit.
public enum CalendarLaneAssign {
    public static func assignLanes(slots: [(y: CGFloat, height: CGFloat)]) -> [LaneAssignment] {
        var groups: [Range<Int>] = []
        var groupStart = 0
        var groupBottom: CGFloat = -.greatestFiniteMagnitude

        for (idx, slot) in slots.enumerated() {
            if slot.y < groupBottom {
                groupBottom = max(groupBottom, slot.y + slot.height)
            } else {
                if idx > groupStart { groups.append(groupStart..<idx) }
                groupStart = idx
                groupBottom = slot.y + slot.height
            }
        }
        groups.append(groupStart..<slots.count)

        var result = [LaneAssignment](repeating: LaneAssignment(lane: 0, groupSize: 1), count: slots.count)
        for range in groups {
            var laneEnds: [CGFloat] = []
            var assignments: [(index: Int, lane: Int)] = []
            for idx in range {
                let slot = slots[idx]
                var lane = -1
                for (lIdx, end) in laneEnds.enumerated() where end <= slot.y {
                    lane = lIdx; break
                }
                if lane == -1 {
                    lane = laneEnds.count
                    laneEnds.append(slot.y + slot.height)
                } else {
                    laneEnds[lane] = slot.y + slot.height
                }
                assignments.append((index: idx, lane: lane))
            }
            let total = laneEnds.count
            for (index, lane) in assignments {
                result[index] = LaneAssignment(lane: lane, groupSize: total)
            }
        }
        return result
    }
}
