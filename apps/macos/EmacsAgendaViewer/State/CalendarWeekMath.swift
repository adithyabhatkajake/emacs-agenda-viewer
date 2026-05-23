import Foundation

/// Pure calendar arithmetic shared between `MacCalendarView` and tests.
enum CalendarWeekMath {
    /// Returns the 7 calendar dates that make up the week containing `anchor`,
    /// with the week anchored to `calendar.firstWeekday`.
    ///
    /// `firstWeekday` follows NSCalendar convention: 1 = Sunday, 2 = Monday,
    /// 7 = Saturday. Each day is the start-of-day for that date in `calendar`.
    /// Day generation uses `date(byAdding: .day, ...)` to handle DST transitions
    /// correctly.
    static func weekDays(for anchor: Date, calendar: Calendar) -> [Date] {
        let weekday = calendar.component(.weekday, from: anchor)
        // Offset from this weekday back to the start of the locale week.
        // NSCalendar weekday values: 1=Sun … 7=Sat. firstWeekday has the same
        // domain. The modulo wraps correctly: if anchor IS the first day of the
        // week the offset is 0; if it is one day before it wraps to 6.
        let offsetToStart = ((weekday - calendar.firstWeekday) + 7) % 7
        let weekStart = calendar.date(
            byAdding: .day, value: -offsetToStart,
            to: calendar.startOfDay(for: anchor)
        )!
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: weekStart) }
    }
}
