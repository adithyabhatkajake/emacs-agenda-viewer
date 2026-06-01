import Testing
import Foundation
@testable import EAVCore

@Suite("HabitStats")
struct HabitStatsTests {

    // MARK: - HabitMath.parseOrgDate (now delegates to OrgTimestamp.parseDateString)

    @Test("parseOrgDate: plain YYYY-MM-DD")
    func parseOrgDatePlain() {
        let d = HabitMath.parseOrgDate("2026-05-11")
        #expect(d != nil)
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: d!)
        #expect(comps.year == 2026)
        #expect(comps.month == 5)
        #expect(comps.day == 11)
    }

    @Test("parseOrgDate: full daemon completion string with day-name and time")
    func parseOrgDateFull() {
        let d = HabitMath.parseOrgDate("2026-05-11 Mon 14:32")
        #expect(d != nil)
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour], from: d!)
        #expect(comps.year == 2026)
        #expect(comps.month == 5)
        #expect(comps.day == 11)
        // Time portion is discarded — midnight in Calendar.current.
        #expect(comps.hour == 0)
    }

    @Test("parseOrgDate: bracket-delimited LAST_REPEAT string")
    func parseOrgDateBracketStripped() {
        // LAST_REPEAT arrives as "[2026-05-12 Tue 09:52]"; stats() trims
        // the brackets before calling parseOrgDate, so we test the stripped form.
        let d = HabitMath.parseOrgDate("2026-05-12 Tue 09:52")
        #expect(d != nil)
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: d!)
        #expect(comps.year == 2026)
        #expect(comps.month == 5)
        #expect(comps.day == 12)
    }

    @Test("parseOrgDate: garbage returns nil")
    func parseOrgDateGarbage() {
        #expect(HabitMath.parseOrgDate("not a date") == nil)
    }

    @Test("parseOrgDate: DST spring-forward date 2026-03-08")
    func parseOrgDateDSTSpringForward() {
        // 2026-03-08 is US DST spring-forward. The 2 AM hour is skipped, but
        // midnight (00:00) is unaffected. Parsing must return a valid Date.
        let d = HabitMath.parseOrgDate("2026-03-08")
        #expect(d != nil)
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: d!)
        #expect(comps.year == 2026)
        #expect(comps.month == 3)
        #expect(comps.day == 8)
    }

    @Test("parseOrgDate: DST fall-back date 2026-11-01")
    func parseOrgDateDSTFallBack() {
        // 2026-11-01 is US DST fall-back. The 1 AM hour occurs twice, but
        // midnight is unambiguous. Parsing must return a valid Date.
        let d = HabitMath.parseOrgDate("2026-11-01")
        #expect(d != nil)
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: d!)
        #expect(comps.year == 2026)
        #expect(comps.month == 11)
        #expect(comps.day == 1)
    }

    // MARK: - HabitMath.stats — daily cadence basics

    private static let dailyRepeater = OrgTimestamp.Repeater(type: ".+", value: 1, unit: "d")

    @Test("stats: no completions → all cells are upcoming or missed, streak 0")
    func statsNoCompletions() {
        var cal = Calendar.current
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = makeDate(2026, 5, 15, cal: cal)
        let s = HabitMath.stats(
            completions: nil,
            repeater: Self.dailyRepeater,
            now: now,
            calendar: cal
        )
        #expect(s.currentStreak == 0)
        #expect(s.longestStreak == 0)
        #expect(s.cells.last == .upcoming)
    }

    @Test("stats: completed today increments streak to 1")
    func statsCompletedToday() {
        var cal = Calendar.current
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = makeDate(2026, 5, 15, cal: cal)
        let s = HabitMath.stats(
            completions: ["2026-05-15 Thu 08:00"],
            repeater: Self.dailyRepeater,
            now: now,
            calendar: cal
        )
        #expect(s.currentStreak == 1)
        #expect(s.cells.last == .done)
    }

    @Test("stats: three consecutive days → streak 3")
    func statsThreeDayStreak() {
        var cal = Calendar.current
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = makeDate(2026, 5, 15, cal: cal)
        let s = HabitMath.stats(
            completions: [
                "2026-05-13 Tue 09:00",
                "2026-05-14 Wed 10:00",
                "2026-05-15 Thu 11:00",
            ],
            repeater: Self.dailyRepeater,
            now: now,
            calendar: cal
        )
        #expect(s.currentStreak == 3)
    }

    @Test("stats: gap in completions breaks streak")
    func statsGapBreaksStreak() {
        var cal = Calendar.current
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = makeDate(2026, 5, 15, cal: cal)
        let s = HabitMath.stats(
            completions: [
                "2026-05-11 Sun 09:00",  // break before here
                "2026-05-13 Tue 09:00",
                "2026-05-14 Wed 10:00",
                "2026-05-15 Thu 11:00",
            ],
            repeater: Self.dailyRepeater,
            now: now,
            calendar: cal
        )
        // Streak counts from 13–15: 3 days (gap on 12 breaks it from 11).
        #expect(s.currentStreak == 3)
        #expect(s.longestStreak == 3)
    }

    @Test("stats: LAST_REPEAT merged when no logbook entry for today")
    func statsLastRepeatMerged() {
        var cal = Calendar.current
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = makeDate(2026, 5, 15, cal: cal)
        // completions only has yesterday; LAST_REPEAT is today.
        let s = HabitMath.stats(
            completions: ["2026-05-14 Wed 10:00"],
            repeater: Self.dailyRepeater,
            lastRepeat: "[2026-05-15 Thu 09:52]",
            now: now,
            calendar: cal
        )
        #expect(s.currentStreak == 2)
        #expect(s.cells.last == .done)
    }

    @Test("stats: weekly cadence — one completion this week → streak 1")
    func statsWeeklyCadence() {
        var cal = Calendar.current
        cal.timeZone = TimeZone(identifier: "UTC")!
        // 2026-05-11 is a Monday (start of ISO week).
        let now = makeDate(2026, 5, 13, cal: cal)  // Wednesday of that week
        let weeklyRepeater = OrgTimestamp.Repeater(type: ".+", value: 1, unit: "w")
        let s = HabitMath.stats(
            completions: ["2026-05-12 Tue 09:00"],
            repeater: weeklyRepeater,
            now: now,
            calendar: cal
        )
        #expect(s.currentStreak == 1)
        #expect(s.cells.last == .done)
    }

    @Test("stats: completion rate equals done cells / window")
    func statsCompletionRate() {
        var cal = Calendar.current
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = makeDate(2026, 5, 15, cal: cal)
        // 14-cell window; complete exactly 7 of the past days (not today).
        let completions = (1...7).map { offset -> String in
            let date = cal.date(byAdding: .day, value: -offset, to: cal.startOfDay(for: now))!
            let comps = cal.dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d-%02d-%02d", comps.year!, comps.month!, comps.day!)
        }
        let s = HabitMath.stats(
            completions: completions,
            repeater: Self.dailyRepeater,
            now: now,
            calendar: cal
        )
        // 7 done out of 14 cells = 0.5 (today is .upcoming, not .done)
        #expect(abs(s.completionRate - 0.5) < 0.01)
    }
}

// MARK: - dueHabitsToday / Habit.isDueToday

@Suite("dueHabitsToday")
struct DueHabitsTodayTests {
    private static let dailyCadence = HabitCadenceSpec(kind: "+", value: 1, unit: "d", maxValue: nil, maxUnit: nil)

    private func makeHabit(id: String = "h1", active: Bool = true, state: String?) -> Habit {
        Habit(
            id: id,
            title: "Test",
            cadence: Self.dailyCadence,
            category: nil,
            priority: nil,
            tags: [],
            notes: nil,
            anchorDate: nil,
            active: active,
            resetChecklistOnComplete: false,
            completions: [],
            nextDue: nil,
            state: state
        )
    }

    @Test("due habit with state=due is included")
    func dueHabitIncluded() {
        let h = makeHabit(state: "due")
        #expect(h.isDueToday)
        #expect(dueHabitsToday([h]).count == 1)
    }

    @Test("overdue habit with state=overdue is included")
    func overdueHabitIncluded() {
        let h = makeHabit(state: "overdue")
        #expect(h.isDueToday)
        #expect(dueHabitsToday([h]).count == 1)
    }

    @Test("ok habit is excluded")
    func okHabitExcluded() {
        let h = makeHabit(state: "ok")
        #expect(!h.isDueToday)
        #expect(dueHabitsToday([h]).isEmpty)
    }

    @Test("inactive habit is excluded even when overdue")
    func inactiveHabitExcluded() {
        let h = makeHabit(active: false, state: "overdue")
        #expect(!h.isDueToday)
        #expect(dueHabitsToday([h]).isEmpty)
    }

    @Test("nil state habit is excluded")
    func nilStateExcluded() {
        let h = makeHabit(state: nil)
        #expect(!h.isDueToday)
        #expect(dueHabitsToday([h]).isEmpty)
    }

    @Test("mixed list filters correctly")
    func mixedList() {
        let habits = [
            makeHabit(id: "a", active: true, state: "due"),
            makeHabit(id: "b", active: true, state: "ok"),
            makeHabit(id: "c", active: false, state: "overdue"),
            makeHabit(id: "d", active: true, state: "overdue"),
        ]
        let due = dueHabitsToday(habits)
        #expect(due.count == 2)
        #expect(due.map(\.id).contains("a"))
        #expect(due.map(\.id).contains("d"))
    }
}

// MARK: - helpers

private func makeDate(_ year: Int, _ month: Int, _ day: Int, cal: Calendar) -> Date {
    var dc = DateComponents()
    dc.year = year; dc.month = month; dc.day = day
    dc.hour = 12; dc.minute = 0; dc.second = 0
    return cal.date(from: dc)!
}
