import Foundation

/// Shared filter predicates used across iOS and Mac views.
///
/// Each function is a pure transformation over model types so it can be tested
/// without SwiftUI or AppKit dependencies.
enum TaskFilters {

    // MARK: - Pinned ("My Day")

    /// True when `task` has a :PINNED: property equal to today's date string.
    ///
    /// The comparison is strict equality — yesterday's pins silently disappear
    /// at midnight because `DateQuery.today()` returns a new value after
    /// the calendar day rolls over.
    static func isPinnedToday(_ task: OrgTask) -> Bool {
        task.properties?["PINNED"] == DateQuery.today()
    }

    // MARK: - Inbox

    /// True when `task` belongs in the Inbox view: captured into the "Inbox"
    /// category (case-insensitive), has an active todo state (nil or empty
    /// state is excluded — bare headings aren't triageable tasks), and is not
    /// yet in a done state.
    ///
    /// Both platforms use this single predicate so the Inbox filter stays
    /// consistent across iOS and Mac.
    static func isInbox(_ task: OrgTask, doneStates: Set<String>) -> Bool {
        guard task.category.caseInsensitiveCompare("Inbox") == .orderedSame else { return false }
        guard let state = task.todoState, !state.isEmpty else { return false }
        return !doneStates.contains(state.uppercased())
    }

    // MARK: - Logbook

    /// Tasks whose todo state is in the done set, using the configured keywords
    /// as the authority. Falls back to `["DONE", "KILL"]` when the keyword list
    /// is empty or nil (first paint before keywords load, or a bare-bones org
    /// config that never customized TODO sequences).
    static func doneTasks(from tasks: [OrgTask], keywords: TodoKeywords?) -> [OrgTask] {
        let doneSet = resolvedDoneSet(keywords)
        return tasks.filter { task in
            guard let s = task.todoState?.uppercased() else { return false }
            return doneSet.contains(s)
        }
    }

    /// The canonical done-state set derived from `TodoKeywords`. Callers that
    /// need the set directly (e.g. for a count) can use this instead of going
    /// through `doneTasks`.
    static func resolvedDoneSet(_ keywords: TodoKeywords?) -> Set<String> {
        let configured = keywords?.allDone ?? []
        if configured.isEmpty { return ["DONE", "KILL"] }
        return Set(configured.map { $0.uppercased() })
    }

    // MARK: - Upcoming: day-bucket grouping

    /// Groups agenda entries into ordered day buckets keyed by ISO date string.
    ///
    /// The key for each entry is `effectiveDate ?? scheduled?.date ??
    /// deadline?.date ?? "—"`, matching the behaviour both UpcomingView and
    /// MacUpcomingView relied on before this extraction. Insertion order is
    /// preserved so the caller receives entries in the order they arrived from
    /// the daemon.
    ///
    /// Returns an array of `(key, items)` pairs — callers are responsible for
    /// mapping the ISO key to a display label appropriate for their platform.
    static func groupAgendaEntriesByDay(
        _ entries: [AgendaEntry]
    ) -> [(key: String, items: [AgendaEntry])] {
        var buckets: [String: [AgendaEntry]] = [:]
        var order: [String] = []
        for entry in entries {
            let dayKey = entry.effectiveDate
                ?? entry.scheduled?.date
                ?? entry.deadline?.date
                ?? "—"
            if buckets[dayKey] == nil {
                buckets[dayKey] = []
                order.append(dayKey)
            }
            buckets[dayKey]?.append(entry)
        }
        return order.map { key in (key: key, items: buckets[key] ?? []) }
    }
}
