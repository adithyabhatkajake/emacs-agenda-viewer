import Testing
import Foundation
@testable import EAVCore

@Suite("CalendarLaneAssign.assignLanes")
struct CalendarLaneAssignTests {

    // MARK: - No overlap

    @Test("Two non-overlapping events both land in lane 0, each in its own group")
    func noOverlapBothInLaneZero() {
        // Event A: y=0..64, Event B: y=128..192 (gap of 64 between them)
        let slots: [(y: CGFloat, height: CGFloat)] = [
            (y: 0, height: 64),
            (y: 128, height: 64),
        ]
        let result = CalendarLaneAssign.assignLanes(slots: slots)

        #expect(result.count == 2)
        #expect(result[0].lane == 0)
        #expect(result[0].groupSize == 1)
        #expect(result[1].lane == 0)
        #expect(result[1].groupSize == 1)
    }

    // MARK: - Two overlapping events

    @Test("Two overlapping events land in lanes 0 and 1")
    func twoOverlappingEventsGetSeparateLanes() {
        // Event A: y=0..128, Event B: y=64..192 — they overlap at [64,128)
        let slots: [(y: CGFloat, height: CGFloat)] = [
            (y: 0,  height: 128),
            (y: 64, height: 128),
        ]
        let result = CalendarLaneAssign.assignLanes(slots: slots)

        #expect(result.count == 2)
        #expect(result[0].lane == 0)
        #expect(result[1].lane == 1)
        #expect(result[0].groupSize == 2)
        #expect(result[1].groupSize == 2)
    }

    // MARK: - Three events, first and last do not overlap each other

    @Test("Third event reuses lane 0 when it starts strictly before the second event ends")
    func thirdEventReusesLaneZero() {
        // A: y=0..64   (lane 0)
        // B: y=32..96  (overlaps A → lane 1, groupSize=2)
        // C: y=80..144 (starts before B ends at 96 → joins same group; A's lane ends at 64 ≤ 80 → reuses lane 0)
        let slots: [(y: CGFloat, height: CGFloat)] = [
            (y: 0,  height: 64),
            (y: 32, height: 64),
            (y: 80, height: 64),
        ]
        let result = CalendarLaneAssign.assignLanes(slots: slots)

        #expect(result.count == 3)
        #expect(result[0].lane == 0)
        #expect(result[1].lane == 1)
        // C starts at 80 < groupBottom 96 → same group; lane 0 ended at 64 ≤ 80 → reuses it
        #expect(result[2].lane == 0)
        // All three share a group of width 2
        #expect(result[2].groupSize == 2)
    }

    @Test("Third event touching (not overlapping) the second starts a fresh solo group")
    func thirdEventTouchingSecondStartsFreshGroup() {
        // A: y=0..64, B: y=32..96, C: y=96..160
        // C's y=96 is NOT strictly less than groupBottom=96 → new group → lane 0, groupSize 1
        let slots: [(y: CGFloat, height: CGFloat)] = [
            (y: 0,  height: 64),
            (y: 32, height: 64),
            (y: 96, height: 64),
        ]
        let result = CalendarLaneAssign.assignLanes(slots: slots)

        #expect(result.count == 3)
        #expect(result[0].lane == 0)
        #expect(result[1].lane == 1)
        #expect(result[0].groupSize == 2)
        // C is its own group
        #expect(result[2].lane == 0)
        #expect(result[2].groupSize == 1)
    }

    // MARK: - Three fully-overlapping events

    @Test("Three mutually-overlapping events each get a distinct lane")
    func threeFullyOverlappingEventsGetThreeLanes() {
        // A: y=0..192, B: y=0..192, C: y=0..192 — all start at the same top
        let slots: [(y: CGFloat, height: CGFloat)] = [
            (y: 0, height: 192),
            (y: 0, height: 192),
            (y: 0, height: 192),
        ]
        let result = CalendarLaneAssign.assignLanes(slots: slots)

        #expect(result.count == 3)
        let lanes = result.map(\.lane).sorted()
        #expect(lanes == [0, 1, 2])
        #expect(result[0].groupSize == 3)
        #expect(result[1].groupSize == 3)
        #expect(result[2].groupSize == 3)
    }

    // MARK: - Empty input

    @Test("Empty input returns empty output")
    func emptyInputProducesEmptyOutput() {
        let result = CalendarLaneAssign.assignLanes(slots: [])
        #expect(result.isEmpty)
    }
}
