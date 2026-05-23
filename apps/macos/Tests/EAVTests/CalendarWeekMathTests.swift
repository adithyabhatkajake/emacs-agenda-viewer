import Testing
import Foundation
@testable import EAVCore

@Suite("CalendarWeekMath.weekDays")
struct CalendarWeekMathTests {

    // Returns a Gregorian calendar with no locale influence on firstWeekday.
    private func gregorian(firstWeekday: Int) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = firstWeekday
        return cal
    }

    // Returns midnight local time for a known date components.
    private func date(year: Int, month: Int, day: Int, calendar: Calendar) -> Date {
        var dc = DateComponents()
        dc.year = year; dc.month = month; dc.day = day
        return calendar.date(from: dc)!
    }

    // MARK: - Case 1: US locale (firstWeekday=1, Sunday)

    @Test("US locale: Tuesday anchor yields week starting on Sunday")
    func usSundayFirstWeek() {
        let cal = gregorian(firstWeekday: 1)
        // 2026-05-19 is a Tuesday
        let tuesday = date(year: 2026, month: 5, day: 19, calendar: cal)
        let days = CalendarWeekMath.weekDays(for: tuesday, calendar: cal)

        #expect(days.count == 7)
        // Week should start on Sunday 2026-05-17
        let dc = cal.dateComponents([.year, .month, .day, .weekday], from: days[0])
        #expect(dc.year == 2026)
        #expect(dc.month == 5)
        #expect(dc.day == 17)
        #expect(dc.weekday == 1) // Sunday
    }

    @Test("US locale: Sunday anchor stays on same Sunday")
    func usSundayAnchorStaysOnSunday() {
        let cal = gregorian(firstWeekday: 1)
        // 2026-05-17 is a Sunday
        let sunday = date(year: 2026, month: 5, day: 17, calendar: cal)
        let days = CalendarWeekMath.weekDays(for: sunday, calendar: cal)

        #expect(days.count == 7)
        let dc = cal.dateComponents([.year, .month, .day, .weekday], from: days[0])
        #expect(dc.day == 17)
        #expect(dc.weekday == 1) // Sunday — offset is 0
    }

    // MARK: - Case 2: UK locale (firstWeekday=2, Monday)

    @Test("UK locale: Tuesday anchor yields week starting on Monday")
    func ukMondayFirstWeek() {
        let cal = gregorian(firstWeekday: 2)
        // 2026-05-19 is a Tuesday
        let tuesday = date(year: 2026, month: 5, day: 19, calendar: cal)
        let days = CalendarWeekMath.weekDays(for: tuesday, calendar: cal)

        #expect(days.count == 7)
        // Week should start on Monday 2026-05-18
        let dc = cal.dateComponents([.year, .month, .day, .weekday], from: days[0])
        #expect(dc.year == 2026)
        #expect(dc.month == 5)
        #expect(dc.day == 18)
        #expect(dc.weekday == 2) // Monday
    }

    @Test("UK locale: Sunday anchor goes back 6 days to Monday of prior week")
    func ukSundayAnchorGoesBackToMonday() {
        let cal = gregorian(firstWeekday: 2)
        // 2026-05-17 is a Sunday; week should start on Mon 2026-05-11
        let sunday = date(year: 2026, month: 5, day: 17, calendar: cal)
        let days = CalendarWeekMath.weekDays(for: sunday, calendar: cal)

        #expect(days.count == 7)
        let dc = cal.dateComponents([.year, .month, .day, .weekday], from: days[0])
        #expect(dc.day == 11)
        #expect(dc.weekday == 2) // Monday
        // Last day should be Sunday 2026-05-17
        let last = cal.dateComponents([.day, .weekday], from: days[6])
        #expect(last.day == 17)
        #expect(last.weekday == 1) // Sunday
    }

    // MARK: - Case 3: DST spring-forward boundary

    @Test("DST spring-forward Sunday: all 7 days have distinct, correct calendar dates")
    func dstSpringForwardProducesSevenDistinctDays() {
        // US spring-forward in 2026: 2026-03-08 (Sunday, clocks go forward at 2am)
        var cal = gregorian(firstWeekday: 1)
        // Use a timezone that observes US DST so the test is meaningful.
        cal.timeZone = TimeZone(identifier: "America/New_York")!

        let springForwardSunday = date(year: 2026, month: 3, day: 8, calendar: cal)
        let days = CalendarWeekMath.weekDays(for: springForwardSunday, calendar: cal)

        #expect(days.count == 7)

        // Each day's calendar date should differ by exactly one day from the previous.
        for i in 1..<7 {
            let prev = cal.dateComponents([.year, .month, .day], from: days[i - 1])
            let curr = cal.dateComponents([.year, .month, .day], from: days[i])
            // Advance prev by one calendar day and compare.
            let expected = cal.date(byAdding: .day, value: 1, to: days[i - 1])!
            let expDC = cal.dateComponents([.year, .month, .day], from: expected)
            #expect(curr.year == expDC.year)
            #expect(curr.month == expDC.month)
            #expect(curr.day == expDC.day,
                    "Day \(i) should be \(expDC.day!) but got \(curr.day!)")
            _ = prev
        }

        // Week starts on Sunday 2026-03-08
        let first = cal.dateComponents([.year, .month, .day, .weekday], from: days[0])
        #expect(first.year == 2026)
        #expect(first.month == 3)
        #expect(first.day == 8)
        #expect(first.weekday == 1)
    }

    // MARK: - Case 4: Year boundary

    @Test("US locale: year boundary 2026-01-01 (Thursday) → week starts 2025-12-28 (Sunday)")
    func yearBoundaryUSSundayFirst() {
        let cal = gregorian(firstWeekday: 1)
        // 2026-01-01 is a Thursday (weekday=5 in NSCalendar)
        let newYearsDay = date(year: 2026, month: 1, day: 1, calendar: cal)
        let days = CalendarWeekMath.weekDays(for: newYearsDay, calendar: cal)

        #expect(days.count == 7)
        let first = cal.dateComponents([.year, .month, .day, .weekday], from: days[0])
        // Sunday before: 2025-12-28
        #expect(first.year == 2025)
        #expect(first.month == 12)
        #expect(first.day == 28)
        #expect(first.weekday == 1) // Sunday

        let last = cal.dateComponents([.year, .month, .day, .weekday], from: days[6])
        // Saturday: 2026-01-03
        #expect(last.year == 2026)
        #expect(last.month == 1)
        #expect(last.day == 3)
        #expect(last.weekday == 7) // Saturday
    }

    @Test("UK locale: year boundary 2026-01-01 (Thursday) → week starts 2025-12-29 (Monday)")
    func yearBoundaryUKMondayFirst() {
        let cal = gregorian(firstWeekday: 2)
        let newYearsDay = date(year: 2026, month: 1, day: 1, calendar: cal)
        let days = CalendarWeekMath.weekDays(for: newYearsDay, calendar: cal)

        #expect(days.count == 7)
        let first = cal.dateComponents([.year, .month, .day, .weekday], from: days[0])
        // Monday: 2025-12-29
        #expect(first.year == 2025)
        #expect(first.month == 12)
        #expect(first.day == 29)
        #expect(first.weekday == 2) // Monday

        let last = cal.dateComponents([.year, .month, .day, .weekday], from: days[6])
        // Sunday: 2026-01-04
        #expect(last.year == 2026)
        #expect(last.month == 1)
        #expect(last.day == 4)
        #expect(last.weekday == 1) // Sunday
    }

    // MARK: - Structural invariants

    @Test("Result always contains exactly 7 sequential calendar days")
    func alwaysSevenSequentialDays() {
        let cal = gregorian(firstWeekday: 1)
        let anchor = date(year: 2026, month: 5, day: 22, calendar: cal)
        let days = CalendarWeekMath.weekDays(for: anchor, calendar: cal)

        #expect(days.count == 7)
        for i in 1..<7 {
            let diff = Calendar.current.dateComponents([.day], from: days[i - 1], to: days[i]).day
            #expect(diff == 1)
        }
    }

    @Test("firstWeekday is honored: Monday anchor with firstWeekday=2 has offset 0")
    func mondayAnchorWithMondayFirstWeekdayHasOffsetZero() {
        let cal = gregorian(firstWeekday: 2)
        // 2026-05-18 is a Monday
        let monday = date(year: 2026, month: 5, day: 18, calendar: cal)
        let days = CalendarWeekMath.weekDays(for: monday, calendar: cal)

        #expect(days.count == 7)
        let dc = cal.dateComponents([.year, .month, .day, .weekday], from: days[0])
        #expect(dc.day == 18)
        #expect(dc.weekday == 2) // Monday — no offset applied
    }
}
