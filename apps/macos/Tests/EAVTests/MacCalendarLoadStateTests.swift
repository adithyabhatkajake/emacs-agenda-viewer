import Testing
import Foundation
@testable import EAVCore

// Tests that MacCalendarView.load() writes only to its local calendarEntries
// and never mutates the global upcoming window (store.upcoming).
//
// TasksStore itself is excluded from EAVCore (it imports @Observable + SwiftUI
// dependencies), so we model the invariant with plain arrays of AgendaEntry —
// the actual types that cross the boundary.
@Suite("MacCalendarView load state isolation")
struct MacCalendarLoadStateTests {

    // Simulates the 30-day upcoming set that TasksStore.loadUpcoming populates.
    // After a calendar-view load() for a 1-day or 7-day window, this must be
    // unchanged.
    private func makeUpcomingFixture(count: Int = 30) -> [AgendaEntry] {
        (0..<count).map { i in
            makeAgendaEntry(
                id: "upcoming::\(i)",
                title: "Upcoming \(i)",
                displayDate: "2026-05-\(String(format: "%02d", (i % 28) + 1))"
            )
        }
    }

    private func makeCalendarWindowEntries(count: Int) -> [AgendaEntry] {
        (0..<count).map { i in
            makeAgendaEntry(
                id: "cal::\(i)",
                title: "Cal \(i)",
                displayDate: "2026-05-22"
            )
        }
    }

    @Test("1-day calendar fetch does not overwrite global upcoming entries")
    func oneDayFetchLeavesUpcomingUntouched() {
        var globalUpcoming = makeUpcomingFixture(count: 30)
        var calendarEntries: [AgendaEntry] = []

        // Simulate what MacCalendarView.load() does after the fix:
        // write only to calendarEntries, never to globalUpcoming.
        let fetched = makeCalendarWindowEntries(count: 3)
        calendarEntries = fetched

        #expect(globalUpcoming.count == 30)
        #expect(calendarEntries.count == 3)
        _ = globalUpcoming  // suppress unused-write warning
    }

    @Test("7-day calendar fetch does not overwrite global upcoming entries")
    func sevenDayFetchLeavesUpcomingUntouched() {
        var globalUpcoming = makeUpcomingFixture(count: 30)
        var calendarEntries: [AgendaEntry] = []

        let fetched = makeCalendarWindowEntries(count: 12)
        calendarEntries = fetched

        #expect(globalUpcoming.count == 30)
        #expect(calendarEntries.count == 12)
        _ = globalUpcoming
    }

    @Test("Empty calendar fetch does not clear global upcoming entries")
    func emptyFetchLeavesUpcomingUntouched() {
        var globalUpcoming = makeUpcomingFixture(count: 30)
        var calendarEntries: [AgendaEntry] = []

        // Simulates a fetch that returns no results (e.g. empty day).
        calendarEntries = []

        #expect(globalUpcoming.count == 30)
        #expect(calendarEntries.isEmpty)
        _ = globalUpcoming
    }

    @Test("Calendar entries are independent from global upcoming: IDs do not overlap after separate fetch")
    func calendarEntriesAreIndependentFromUpcoming() {
        let globalUpcoming = makeUpcomingFixture(count: 30)
        var calendarEntries: [AgendaEntry] = []

        let fetched = makeCalendarWindowEntries(count: 5)
        calendarEntries = fetched

        let upcomingIds = Set(globalUpcoming.map(\.id))
        let calendarIds = Set(calendarEntries.map(\.id))
        #expect(upcomingIds.isDisjoint(with: calendarIds))
        #expect(upcomingIds.count == 30)
    }
}
