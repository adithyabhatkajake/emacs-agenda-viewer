import Testing
import Foundation
@testable import EAVCore

@Suite("Sorting")
struct SortingTests {

    // MARK: - sortTasks

    @Test("Sort by priority: A < B < C < no priority")
    func sortByPriority() {
        let tasks = [
            makeTask(id: "none", priority: nil),
            makeTask(id: "c", priority: "C"),
            makeTask(id: "a", priority: "A"),
            makeTask(id: "b", priority: "B"),
        ]
        let sorted = sortTasks(tasks, by: .priority)
        #expect(sorted.map(\.id) == ["a", "b", "c", "none"])
    }

    @Test("Sort by priority: D sorts after C, before no-priority")
    func sortByPriorityD() {
        let tasks = [
            makeTask(id: "none", priority: nil),
            makeTask(id: "d", priority: "D"),
            makeTask(id: "c", priority: "C"),
        ]
        let sorted = sortTasks(tasks, by: .priority)
        #expect(sorted.map(\.id) == ["c", "d", "none"])
    }

    @Test("Sort by category: alphabetical")
    func sortByCategory() {
        let tasks = [
            makeTask(id: "w", category: "Work"),
            makeTask(id: "a", category: "Archive"),
            makeTask(id: "i", category: "Inbox"),
        ]
        let sorted = sortTasks(tasks, by: .category)
        #expect(sorted.map(\.id) == ["a", "i", "w"])
    }

    @Test("Sort by deadline: earliest first, no deadline last")
    func sortByDeadline() {
        let late = makeTimestamp(raw: "<2026-05-01 Fri>", date: "2026-05-01",
                                year: 2026, month: 5, day: 1)
        let early = makeTimestamp(raw: "<2026-04-15 Wed>", date: "2026-04-15",
                                 year: 2026, month: 4, day: 15)
        let tasks = [
            makeTask(id: "none"),
            makeTask(id: "late", deadline: late),
            makeTask(id: "early", deadline: early),
        ]
        let sorted = sortTasks(tasks, by: .deadline)
        #expect(sorted.map(\.id) == ["early", "late", "none"])
    }

    @Test("Sort by deadline: falls back to scheduled when no deadline")
    func sortByDeadlineFallsBackToScheduled() {
        let sched = makeTimestamp(raw: "<2026-04-10 Fri>", date: "2026-04-10",
                                 year: 2026, month: 4, day: 10)
        let dl = makeTimestamp(raw: "<2026-04-20 Mon>", date: "2026-04-20",
                               year: 2026, month: 4, day: 20)
        let tasks = [
            makeTask(id: "dl", deadline: dl),
            makeTask(id: "sched", scheduled: sched),
        ]
        let sorted = sortTasks(tasks, by: .deadline)
        #expect(sorted.map(\.id) == ["sched", "dl"])
    }

    @Test("Sort by state: alphabetical")
    func sortByState() {
        let tasks = [
            makeTask(id: "todo", todoState: "TODO"),
            makeTask(id: "done", todoState: "DONE"),
            makeTask(id: "next", todoState: "NEXT"),
        ]
        let sorted = sortTasks(tasks, by: .state)
        #expect(sorted.map(\.id) == ["done", "next", "todo"])
    }

    @Test("Sort by default: preserves original order")
    func sortByDefault() {
        let tasks = [
            makeTask(id: "c", priority: "C"),
            makeTask(id: "a", priority: "A"),
            makeTask(id: "b", priority: "B"),
        ]
        let sorted = sortTasks(tasks, by: .default)
        #expect(sorted.map(\.id) == ["c", "a", "b"])
    }

    @Test("Secondary sort by time when primary key ties")
    func secondarySortByTime() {
        let morning = makeTimestamp(raw: "<2026-04-18 Sat 09:00>", date: "2026-04-18",
                                   year: 2026, month: 4, day: 18, hour: 9, minute: 0)
        let afternoon = makeTimestamp(raw: "<2026-04-18 Sat 15:00>", date: "2026-04-18",
                                     year: 2026, month: 4, day: 18, hour: 15, minute: 0)
        let tasks = [
            makeTask(id: "pm", priority: "A", scheduled: afternoon),
            makeTask(id: "am", priority: "A", scheduled: morning),
        ]
        let sorted = sortTasks(tasks, by: .priority)
        #expect(sorted.map(\.id) == ["am", "pm"])
    }

    @Test("Sort by scheduled: earliest first, no scheduled last")
    func sortByScheduled() {
        let late = makeTimestamp(raw: "<2026-05-01 Fri>", date: "2026-05-01",
                                year: 2026, month: 5, day: 1)
        let early = makeTimestamp(raw: "<2026-04-15 Wed>", date: "2026-04-15",
                                 year: 2026, month: 4, day: 15)
        let tasks = [
            makeTask(id: "none"),
            makeTask(id: "late", scheduled: late),
            makeTask(id: "early", scheduled: early),
        ]
        let sorted = sortTasks(tasks, by: .scheduled)
        #expect(sorted.map(\.id) == ["early", "late", "none"])
    }

    @Test("Sort by scheduled: secondary sort by time within same day")
    func sortByScheduledTime() {
        let morning = makeTimestamp(raw: "<2026-04-18 Sat 09:00>", date: "2026-04-18",
                                   year: 2026, month: 4, day: 18, hour: 9, minute: 0)
        let afternoon = makeTimestamp(raw: "<2026-04-18 Sat 15:00>", date: "2026-04-18",
                                     year: 2026, month: 4, day: 18, hour: 15, minute: 0)
        let tasks = [
            makeTask(id: "pm", scheduled: afternoon),
            makeTask(id: "am", scheduled: morning),
        ]
        let sorted = sortTasks(tasks, by: .scheduled)
        #expect(sorted.map(\.id) == ["am", "pm"])
    }

    @Test("Sort works with AgendaEntry timeOfDay for secondary sort")
    func sortAgendaEntriesByTime() {
        let entries = [
            makeAgendaEntry(id: "late", priority: "A", timeOfDay: "17:00"),
            makeAgendaEntry(id: "early", priority: "A", timeOfDay: " 9:30"),
        ]
        let sorted = sortTasks(entries, by: .priority)
        #expect(sorted.map(\.id) == ["early", "late"])
    }

    // MARK: - groupTasks

    @Test("Group by none: single group with all items")
    func groupByNone() {
        let tasks = [makeTask(id: "a"), makeTask(id: "b")]
        let groups = groupTasks(tasks, by: .none)
        #expect(groups.count == 1)
        #expect(groups[0].items.count == 2)
    }

    @Test("Group by category")
    func groupByCategory() {
        let tasks = [
            makeTask(id: "w1", category: "Work"),
            makeTask(id: "p1", category: "Personal"),
            makeTask(id: "w2", category: "Work"),
        ]
        let groups = groupTasks(tasks, by: .category)
        #expect(groups.count == 2)
        let labels = groups.map(\.label)
        #expect(labels.contains("Work"))
        #expect(labels.contains("Personal"))
        let work = groups.first(where: { $0.label == "Work" })!
        #expect(work.items.count == 2)
    }

    @Test("Group by priority: 'No Priority' sorts last")
    func groupByPriority() {
        let tasks = [
            makeTask(id: "none", priority: nil),
            makeTask(id: "b", priority: "B"),
            makeTask(id: "a", priority: "A"),
        ]
        let groups = groupTasks(tasks, by: .priority)
        #expect(groups.last?.label == "No Priority")
        #expect(groups.first?.label == "Priority A")
    }

    @Test("Group by state: uppercased labels")
    func groupByState() {
        let tasks = [
            makeTask(id: "t", todoState: "TODO"),
            makeTask(id: "d", todoState: "DONE"),
        ]
        let groups = groupTasks(tasks, by: .state)
        let labels = groups.map(\.label)
        #expect(labels.contains("TODO"))
        #expect(labels.contains("DONE"))
    }

    @Test("Group by tag: item appears in multiple groups")
    func groupByTag() {
        let tasks = [
            makeTask(id: "multi", tags: ["work", "urgent"]),
            makeTask(id: "single", tags: ["work"]),
        ]
        let groups = groupTasks(tasks, by: .tag)
        let urgentGroup = groups.first(where: { $0.label == "urgent" })
        #expect(urgentGroup?.items.count == 1)
        let workGroup = groups.first(where: { $0.label == "work" })
        #expect(workGroup?.items.count == 2)
    }

    @Test("Group by tag: untagged items go to 'Untagged'")
    func groupByTagUntagged() {
        let tasks = [
            makeTask(id: "tagged", tags: ["work"]),
            makeTask(id: "bare", tags: []),
        ]
        let groups = groupTasks(tasks, by: .tag)
        let untagged = groups.first(where: { $0.label == "Untagged" })
        #expect(untagged?.items.count == 1)
    }

    @Test("Group by file: uses filename component")
    func groupByFile() {
        let tasks = [
            makeTask(id: "a", file: "/home/user/org/work.org"),
            makeTask(id: "b", file: "/home/user/org/inbox.org"),
        ]
        let groups = groupTasks(tasks, by: .file)
        let labels = groups.map(\.label)
        #expect(labels.contains("work.org"))
        #expect(labels.contains("inbox.org"))
    }

    @Test("Group by category: empty category becomes 'Uncategorized'")
    func groupByEmptyCategory() {
        let tasks = [makeTask(id: "a", category: "")]
        let groups = groupTasks(tasks, by: .category)
        #expect(groups[0].label == "Uncategorized")
    }

    // MARK: - dedupeAgendaEntries

    @Test("Dedupe preserves unique entries in order")
    func dedupeUnique() {
        let entries = [
            makeAgendaEntry(id: "a", title: "First"),
            makeAgendaEntry(id: "b", title: "Second"),
        ]
        let result = dedupeAgendaEntries(entries)
        #expect(result.count == 2)
        #expect(result.map(\.id) == ["a", "b"])
    }

    @Test("Dedupe keeps entry with time over entry without")
    func dedupePrefersTimed() {
        let ts = makeTimestamp(hour: 14, minute: 30)
        let noTime = makeTimestamp()
        let entries = [
            makeAgendaEntry(id: "same", title: "No time", scheduled: noTime),
            makeAgendaEntry(id: "same", title: "With time", scheduled: ts),
        ]
        let result = dedupeAgendaEntries(entries)
        #expect(result.count == 1)
        #expect(result[0].scheduled?.hasTime == true)
    }

    @Test("Dedupe keeps first entry when both lack time")
    func dedupeKeepsFirstWhenBothNoTime() {
        let entries = [
            makeAgendaEntry(id: "same", title: "First"),
            makeAgendaEntry(id: "same", title: "Second"),
        ]
        let result = dedupeAgendaEntries(entries)
        #expect(result.count == 1)
        #expect(result[0].title == "First")
    }

    @Test("Dedupe handles deadline-timed entry replacing scheduled-untimed")
    func dedupeDeadlineTimedReplacesScheduledUntimed() {
        let dl = makeTimestamp(raw: "<2026-04-18 Sat 17:00>", date: "2026-04-18",
                              year: 2026, month: 4, day: 18, hour: 17, minute: 0)
        let entries = [
            makeAgendaEntry(id: "same", title: "Scheduled"),
            makeAgendaEntry(id: "same", title: "Deadline", deadline: dl),
        ]
        let result = dedupeAgendaEntries(entries)
        #expect(result.count == 1)
        #expect(result[0].deadline?.hasTime == true)
    }
}
