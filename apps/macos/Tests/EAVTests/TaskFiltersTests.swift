import Testing
import Foundation
@testable import EAVCore

@Suite("TaskFilters")
struct TaskFiltersTests {

    // MARK: - isPinnedToday

    @Test("isPinnedToday: true when PINNED property equals today's date string")
    func pinnedTodayMatch() {
        let today = DateQuery.today()
        var task = makeTask(id: "t1")
        // Inject the PINNED property via JSON round-trip so we don't depend on
        // a mutable OrgTask API.
        let json: [String: Any] = [
            "id": "t1", "title": "Pinned task", "category": "Work",
            "tags": [String](), "inheritedTags": [String](),
            "level": 1, "file": "/test.org", "pos": 1,
            "properties": ["PINNED": today],
        ]
        task = try! JSONDecoder().decode(
            OrgTask.self,
            from: JSONSerialization.data(withJSONObject: json)
        )
        #expect(TaskFilters.isPinnedToday(task) == true)
    }

    @Test("isPinnedToday: false when PINNED property is a different date")
    func pinnedYesterdayNoMatch() {
        let yesterday = {
            let d = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.locale = Locale(identifier: "en_US_POSIX")
            return f.string(from: d)
        }()
        let json: [String: Any] = [
            "id": "t2", "title": "Old pin", "category": "Work",
            "tags": [String](), "inheritedTags": [String](),
            "level": 1, "file": "/test.org", "pos": 1,
            "properties": ["PINNED": yesterday],
        ]
        let task = try! JSONDecoder().decode(
            OrgTask.self,
            from: JSONSerialization.data(withJSONObject: json)
        )
        #expect(TaskFilters.isPinnedToday(task) == false)
    }

    @Test("isPinnedToday: false when PINNED property is absent")
    func pinnedAbsent() {
        let task = makeTask(id: "t3")
        #expect(TaskFilters.isPinnedToday(task) == false)
    }

    @Test("isPinnedToday: false when PINNED property is empty string")
    func pinnedEmptyString() {
        let json: [String: Any] = [
            "id": "t4", "title": "Unpinned", "category": "Work",
            "tags": [String](), "inheritedTags": [String](),
            "level": 1, "file": "/test.org", "pos": 1,
            "properties": ["PINNED": ""],
        ]
        let task = try! JSONDecoder().decode(
            OrgTask.self,
            from: JSONSerialization.data(withJSONObject: json)
        )
        #expect(TaskFilters.isPinnedToday(task) == false)
    }

    // MARK: - resolvedDoneSet

    @Test("resolvedDoneSet: uses configured keywords uppercased")
    func resolvedDoneSetFromKeywords() {
        let kw = makeTodoKeywords(active: ["TODO", "DOING"], done: ["done", "kill"])
        let set = TaskFilters.resolvedDoneSet(kw)
        #expect(set == ["DONE", "KILL"])
    }

    @Test("resolvedDoneSet: falls back to DONE and KILL when keywords is nil")
    func resolvedDoneSetNilFallback() {
        let set = TaskFilters.resolvedDoneSet(nil)
        #expect(set == ["DONE", "KILL"])
    }

    @Test("resolvedDoneSet: falls back to DONE and KILL when done list is empty")
    func resolvedDoneSetEmptyFallback() {
        let kw = makeTodoKeywords(active: ["TODO"], done: [])
        let set = TaskFilters.resolvedDoneSet(kw)
        #expect(set == ["DONE", "KILL"])
    }

    // MARK: - doneTasks

    @Test("doneTasks: returns only tasks whose todoState is in the done set")
    func doneTasksFiltersCorrectly() {
        let kw = makeTodoKeywords(active: ["TODO"], done: ["DONE", "KILL"])
        let tasks = [
            makeTask(id: "active", todoState: "TODO"),
            makeTask(id: "done",   todoState: "DONE"),
            makeTask(id: "killed", todoState: "KILL"),
            makeTask(id: "nostate", todoState: nil),
        ]
        let result = TaskFilters.doneTasks(from: tasks, keywords: kw)
        #expect(result.map(\.id).sorted() == ["done", "killed"])
    }

    @Test("doneTasks: comparison is case-insensitive")
    func doneTasksCaseInsensitive() {
        let kw = makeTodoKeywords(active: ["TODO"], done: ["Done"])
        let tasks = [
            makeTask(id: "lower", todoState: "done"),
            makeTask(id: "upper", todoState: "DONE"),
            makeTask(id: "mixed", todoState: "Done"),
        ]
        let result = TaskFilters.doneTasks(from: tasks, keywords: kw)
        #expect(result.count == 3)
    }

    @Test("doneTasks: uses fallback set when keywords is nil")
    func doneTasksFallbackKeywords() {
        let tasks = [
            makeTask(id: "done",  todoState: "DONE"),
            makeTask(id: "kill",  todoState: "KILL"),
            makeTask(id: "todo",  todoState: "TODO"),
            makeTask(id: "none",  todoState: nil),
        ]
        let result = TaskFilters.doneTasks(from: tasks, keywords: nil)
        #expect(result.map(\.id).sorted() == ["done", "kill"])
    }

    @Test("doneTasks: excludes tasks with nil todoState")
    func doneTasksExcludesNilState() {
        let kw = makeTodoKeywords(active: ["TODO"], done: ["DONE"])
        let tasks = [makeTask(id: "no-state", todoState: nil)]
        let result = TaskFilters.doneTasks(from: tasks, keywords: kw)
        #expect(result.isEmpty)
    }

    // MARK: - isInbox

    @Test("isInbox: matches task with category == 'Inbox' (title-case)")
    func inboxCategoryTitleCase() {
        let task = makeTask(id: "i1", todoState: "TODO", category: "Inbox")
        let doneStates: Set<String> = ["DONE", "KILL"]
        #expect(TaskFilters.isInbox(task, doneStates: doneStates) == true)
    }

    @Test("isInbox: matches task with category == 'inbox' (lowercase)")
    func inboxCategoryLowercase() {
        let task = makeTask(id: "i2", todoState: "TODO", category: "inbox")
        let doneStates: Set<String> = ["DONE", "KILL"]
        #expect(TaskFilters.isInbox(task, doneStates: doneStates) == true)
    }

    @Test("isInbox: does not match task with category == 'Work'")
    func inboxCategoryWork() {
        let task = makeTask(id: "i3", todoState: "TODO", category: "Work")
        let doneStates: Set<String> = ["DONE", "KILL"]
        #expect(TaskFilters.isInbox(task, doneStates: doneStates) == false)
    }

    @Test("isInbox: does not match Inbox task in a done state")
    func inboxDoneStateExcluded() {
        let task = makeTask(id: "i4", todoState: "DONE", category: "Inbox")
        let doneStates: Set<String> = ["DONE", "KILL"]
        #expect(TaskFilters.isInbox(task, doneStates: doneStates) == false)
    }

    @Test("isInbox: does not match Inbox task with nil todoState (bare heading)")
    func inboxNilStateExcluded() {
        let task = makeTask(id: "i5", todoState: nil, category: "Inbox")
        let doneStates: Set<String> = ["DONE", "KILL"]
        #expect(TaskFilters.isInbox(task, doneStates: doneStates) == false)
    }

    @Test("isInbox: does not match Inbox task with empty todoState")
    func inboxEmptyStateExcluded() {
        let task = makeTask(id: "i6", todoState: "", category: "Inbox")
        let doneStates: Set<String> = ["DONE", "KILL"]
        #expect(TaskFilters.isInbox(task, doneStates: doneStates) == false)
    }

    // MARK: - groupAgendaEntriesByDay

    @Test("groupAgendaEntriesByDay: preserves insertion order of keys")
    func groupByDayOrder() {
        let e1 = makeAgendaEntry(id: "a", displayDate: "2026-05-01")
        let e2 = makeAgendaEntry(id: "b", displayDate: "2026-05-03")
        let e3 = makeAgendaEntry(id: "c", displayDate: "2026-05-01")
        let groups = TaskFilters.groupAgendaEntriesByDay([e1, e2, e3])
        #expect(groups.map(\.key) == ["2026-05-01", "2026-05-03"])
    }

    @Test("groupAgendaEntriesByDay: items within each bucket preserve order")
    func groupByDayItemOrder() {
        let e1 = makeAgendaEntry(id: "first",  displayDate: "2026-05-01")
        let e2 = makeAgendaEntry(id: "second", displayDate: "2026-05-01")
        let groups = TaskFilters.groupAgendaEntriesByDay([e1, e2])
        #expect(groups.count == 1)
        #expect(groups[0].items.map(\.id) == ["first", "second"])
    }

    @Test("groupAgendaEntriesByDay: entries without any date fall into — bucket")
    func groupByDayNilDateFallback() {
        // makeAgendaEntry sets displayDate; nil displayDate means effectiveDate is nil.
        // Build a bare entry with no date fields.
        let json: [String: Any] = [
            "id": "no-date", "title": "No date", "agendaType": "scheduled",
            "category": "Work", "level": 1, "file": "/test.org", "pos": 1,
        ]
        let entry = try! JSONDecoder().decode(
            AgendaEntry.self,
            from: JSONSerialization.data(withJSONObject: json)
        )
        let groups = TaskFilters.groupAgendaEntriesByDay([entry])
        #expect(groups.count == 1)
        #expect(groups[0].key == "—")
    }

    @Test("groupAgendaEntriesByDay: scheduled date used when effectiveDate is nil")
    func groupByDayUsesScheduled() {
        let ts = makeTimestamp(raw: "<2026-06-10 Tue>", date: "2026-06-10",
                               year: 2026, month: 6, day: 10)
        let entry = makeAgendaEntry(id: "sched", scheduled: ts, displayDate: nil)
        let groups = TaskFilters.groupAgendaEntriesByDay([entry])
        #expect(groups.count == 1)
        #expect(groups[0].key == "2026-06-10")
    }

    @Test("groupAgendaEntriesByDay: deadline date used when effectiveDate and scheduled are nil")
    func groupByDayUsesDeadline() {
        let ts = makeTimestamp(raw: "<2026-07-15 Wed>", date: "2026-07-15",
                               year: 2026, month: 7, day: 15)
        let entry = makeAgendaEntry(id: "dead", deadline: ts, displayDate: nil)
        let groups = TaskFilters.groupAgendaEntriesByDay([entry])
        #expect(groups.count == 1)
        #expect(groups[0].key == "2026-07-15")
    }
}

// MARK: - Fixture helpers

private func makeTodoKeywords(active: [String], done: [String]) -> TodoKeywords {
    let json: [String: Any] = [
        "sequences": [
            ["active": active, "done": done],
        ],
    ]
    return try! JSONDecoder().decode(
        TodoKeywords.self,
        from: JSONSerialization.data(withJSONObject: json)
    )
}
