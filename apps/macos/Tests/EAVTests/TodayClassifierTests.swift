import Testing
import Foundation
@testable import EAVCore

@Suite("TodayClassifier")
struct TodayClassifierTests {

    // MARK: - Helpers

    /// Today as a `Calendar.dateComponents` triple (no time-of-day) — used by
    /// every test that needs to build a "today" timestamp without hard-coding
    /// a date that would silently drift across days.
    private static func todayYMD() -> (Int, Int, Int) {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return (c.year!, c.month!, c.day!)
    }

    private static func yesterdayYMD() -> (Int, Int, Int) {
        let d = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return (c.year!, c.month!, c.day!)
    }

    private func today() -> OrgTimestamp {
        let (y, m, d) = Self.todayYMD()
        return makeTimestamp(
            raw: String(format: "<%04d-%02d-%02d>", y, m, d),
            date: String(format: "%04d-%02d-%02d", y, m, d),
            year: y, month: m, day: d
        )
    }

    private func yesterday() -> OrgTimestamp {
        let (y, m, d) = Self.yesterdayYMD()
        return makeTimestamp(
            raw: String(format: "<%04d-%02d-%02d>", y, m, d),
            date: String(format: "%04d-%02d-%02d", y, m, d),
            year: y, month: m, day: d
        )
    }

    /// Builds a habit-flagged OrgTask. The helper in TestHelpers can't take a
    /// :STYLE: habit property directly, so we roll our own here.
    private func makeHabitTask(
        id: String,
        scheduled: OrgTimestamp? = nil,
        todoState: String? = "TODO"
    ) -> OrgTask {
        var json: [String: Any] = [
            "id": id, "title": "Habit \(id)", "todoState": todoState ?? "",
            "tags": [String](), "inheritedTags": [String](),
            "category": "Habits", "level": 1, "file": "/test.org", "pos": 1,
            "properties": ["STYLE": "habit"],
        ]
        if let s = scheduled {
            json["scheduled"] = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(s))
        }
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(OrgTask.self, from: data)
    }

    /// Builds an agenda entry that the classifier should see as a habit. The
    /// existing helper doesn't expose the `isHabit` field, so we add it via
    /// raw JSON.
    private func makeHabitAgendaEntry(
        id: String,
        agendaType: String = "scheduled",
        scheduled: OrgTimestamp? = nil
    ) -> AgendaEntry {
        var json: [String: Any] = [
            "id": id, "title": "Habit entry \(id)", "agendaType": agendaType,
            "todoState": "TODO",
            "tags": [String](), "inheritedTags": [String](),
            "category": "Habits", "level": 1, "file": "/test.org", "pos": 1,
            "isHabit": true,
        ]
        if let s = scheduled {
            json["scheduled"] = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(s))
        }
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(AgendaEntry.self, from: data)
    }

    // MARK: - Inclusion rules

    @Test("Today-scheduled task is included in main")
    func todayScheduledIncluded() {
        let entry = makeAgendaEntry(
            id: "t1", agendaType: "scheduled", scheduled: today()
        )
        let result = TodayClassifier.buildItems(
            today: [entry], all: [], doneStates: ["DONE"], hideHabits: false
        )
        #expect(result.main.count == 1)
        #expect(result.main.first?.id == "t1")
        #expect(result.events.isEmpty)
    }

    @Test("Today-deadline task is included in main")
    func todayDeadlineIncluded() {
        let entry = makeAgendaEntry(
            id: "t2", agendaType: "deadline", deadline: today()
        )
        let result = TodayClassifier.buildItems(
            today: [entry], all: [], doneStates: ["DONE"], hideHabits: false
        )
        #expect(result.main.count == 1)
        #expect(result.main.first?.id == "t2")
    }

    @Test("Upcoming-deadline is dropped unconditionally")
    func upcomingDeadlineDropped() {
        // A `upcoming-deadline` entry whose deadline date happens to be today
        // is still dropped — the classifier ignores those entries by agenda
        // type, period.
        let entry = makeAgendaEntry(
            id: "t3", agendaType: "upcoming-deadline", deadline: today()
        )
        let result = TodayClassifier.buildItems(
            today: [entry], all: [], doneStates: ["DONE"], hideHabits: false
        )
        #expect(result.main.isEmpty)
    }

    @Test("Done state is always dropped")
    func doneStateDropped() {
        let entry = makeAgendaEntry(
            id: "t4", agendaType: "scheduled",
            todoState: "DONE",
            scheduled: today()
        )
        let result = TodayClassifier.buildItems(
            today: [entry], all: [], doneStates: ["DONE"], hideHabits: false
        )
        #expect(result.main.isEmpty)
    }

    @Test("Habit dropped when hideHabits is true")
    func habitDroppedWhenHidden() {
        let entry = makeHabitAgendaEntry(id: "h1", scheduled: today())
        let result = TodayClassifier.buildItems(
            today: [entry], all: [], doneStates: ["DONE"], hideHabits: true
        )
        #expect(result.main.isEmpty)
    }

    @Test("Habit included when hideHabits is false")
    func habitIncludedWhenShown() {
        let entry = makeHabitAgendaEntry(id: "h2", scheduled: today())
        let result = TodayClassifier.buildItems(
            today: [entry], all: [], doneStates: ["DONE"], hideHabits: false
        )
        #expect(result.main.count == 1)
        #expect(result.main.first?.id == "h2")
    }

    // MARK: - Overdue pull from /api/tasks

    @Test("Overdue task in `all` (not in `today`) is pulled into main")
    func overduePulledIn() {
        let task = makeTask(id: "o1", scheduled: yesterday())
        let result = TodayClassifier.buildItems(
            today: [], all: [task], doneStates: ["DONE"], hideHabits: false
        )
        #expect(result.main.count == 1)
        #expect(result.main.first?.id == "o1")
    }

    @Test("Task in `today` already AND in `all` with past scheduled — only one row")
    func overdueNotDuplicated() {
        // The same heading shows up in `today` (because the daemon emitted a
        // scheduled row for today's date) AND in `all` (with its raw past
        // scheduled date, e.g. a repeating task that already rolled). It
        // should only appear once in main.
        let entry = makeAgendaEntry(
            id: "dup", agendaType: "scheduled", scheduled: today()
        )
        let task = makeTask(id: "dup", scheduled: yesterday())
        let result = TodayClassifier.buildItems(
            today: [entry], all: [task], doneStates: ["DONE"], hideHabits: false
        )
        #expect(result.main.count == 1)
        #expect(result.main.first?.id == "dup")
    }

    @Test("Overdue habit in `all` is pulled in when hideHabits is false")
    func overdueHabitPulledInWhenShown() {
        let habit = makeHabitTask(id: "habit-overdue", scheduled: yesterday())
        let result = TodayClassifier.buildItems(
            today: [], all: [habit], doneStates: ["DONE"], hideHabits: false
        )
        #expect(result.main.count == 1)
        #expect(result.main.first?.id == "habit-overdue")
    }

    @Test("Overdue habit in `all` is dropped when hideHabits is true")
    func overdueHabitDroppedWhenHidden() {
        let habit = makeHabitTask(id: "habit-overdue", scheduled: yesterday())
        let result = TodayClassifier.buildItems(
            today: [], all: [habit], doneStates: ["DONE"], hideHabits: true
        )
        #expect(result.main.isEmpty)
    }

    @Test("Done task in `all` is never pulled in as overdue")
    func doneNotPulledAsOverdue() {
        let task = {
            var json: [String: Any] = [
                "id": "done-overdue", "title": "Done", "todoState": "DONE",
                "tags": [String](), "inheritedTags": [String](),
                "category": "Test", "level": 1, "file": "/test.org", "pos": 1,
            ]
            let ts = yesterday()
            json["scheduled"] = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(ts))
            let data = try! JSONSerialization.data(withJSONObject: json)
            return try! JSONDecoder().decode(OrgTask.self, from: data)
        }()
        let result = TodayClassifier.buildItems(
            today: [], all: [task], doneStates: ["DONE"], hideHabits: false
        )
        #expect(result.main.isEmpty)
    }

    // MARK: - Dedupe by id, prefer deadline

    @Test("Same id with both deadline-today and scheduled-today → deadline wins")
    func deadlinePreferredOverScheduled() {
        let scheduled = makeAgendaEntry(
            id: "x", title: "Scheduled view",
            agendaType: "scheduled", scheduled: today()
        )
        let deadline = makeAgendaEntry(
            id: "x", title: "Deadline view",
            agendaType: "deadline", deadline: today()
        )
        // Daemon order shouldn't matter — try both orderings.
        let result1 = TodayClassifier.buildItems(
            today: [scheduled, deadline], all: [], doneStates: ["DONE"], hideHabits: false
        )
        let result2 = TodayClassifier.buildItems(
            today: [deadline, scheduled], all: [], doneStates: ["DONE"], hideHabits: false
        )
        #expect(result1.main.count == 1)
        #expect((result1.main.first as? AgendaEntry)?.agendaType == "deadline")
        #expect(result2.main.count == 1)
        #expect((result2.main.first as? AgendaEntry)?.agendaType == "deadline")
    }

    // MARK: - Events bucket

    @Test("Calendar event (timestamp/sexp/block) goes to events bucket, not main")
    func calendarEventGoesToEvents() {
        // No todoState + agendaType == timestamp → it's a calendar event.
        let event = makeAgendaEntry(
            id: "evt", agendaType: "timestamp", todoState: nil, scheduled: today()
        )
        let result = TodayClassifier.buildItems(
            today: [event], all: [], doneStates: ["DONE"], hideHabits: false
        )
        #expect(result.events.count == 1)
        #expect(result.events.first?.id == "evt")
        #expect(result.main.isEmpty)
    }
}
