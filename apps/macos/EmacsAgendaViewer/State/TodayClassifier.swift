import Foundation

/// Canonical Today-view rule, shared between iOS and Mac.
///
/// The "what belongs in Today" decision used to live inside `TodayView` (iOS)
/// and `MacTodayView` (Mac) as two diverging copies. This module is the single
/// source of truth — both views call into `TodayClassifier.buildItems(...)` and
/// then layer view-specific concerns (sorting, grouping, hour-of-day layout,
/// event-tag hiding) on top of the resulting `TodayItems`.
///
/// The web client mirrors these rules in `src/utils/today.ts`.
///
/// Rules:
/// - Events (`timestamp` / `block` / `sexp` with no TODO state) go in the
///   `events` bucket.
/// - `agendaType == "upcoming-deadline"` is ALWAYS dropped from Today. The
///   user's Today view is strict — deadline previews surface in Upcoming, not
///   in Today.
/// - A task qualifies for `main` if any of:
///     * its scheduled timestamp is today
///     * its deadline timestamp is today
///     * its scheduled timestamp is in the past (overdue)
///     * its deadline timestamp is in the past (overdue) — e.g. a repeating
///       deadline like a Weekly Review that slipped past its due date stays
///       in Today until it's done, mirroring org-agenda's past-due deadlines.
/// - Habits are dropped when `hideHabits == true`.
/// - Tasks whose `todoState` is in `doneStates` (case-insensitive) are dropped.
///   The daemon may include them when `org-agenda-skip-scheduled-if-done` is
///   nil — which is the org default for repeating tasks — but Today never
///   wants them.
/// - Dedupe by task id. When the daemon emits both a scheduled-today AND a
///   deadline-today entry for the same heading, the deadline variant wins.
/// - Overdue tasks not already present in `today` are pulled in from the
///   `all` task list (the /api/tasks fetch). Done tasks are always skipped;
///   habits are skipped from the overdue pull only when `hideHabits == true`,
///   matching how habit agenda entries are filtered above.
///
/// The classifier is intentionally pure — no SwiftUI, no settings access, no
/// network. Caller is responsible for fetching both inputs and for any
/// view-specific filtering (e.g. tag-based event hiding lives in the view
/// because it doesn't affect the main list).
enum TodayClassifier {

    /// Result of running the canonical Today rule on the daemon's response.
    ///
    /// `events` holds calendar-style entries (no TODO state) intended for a
    /// banner/timeline UI. `main` is the heterogeneous list of task rows —
    /// `OrgTask` for overdue pulls, `AgendaEntry` for today-anchored rows.
    struct TodayItems {
        let events: [AgendaEntry]
        let main: [any TaskDisplayable]
    }

    static func buildItems(
        today: [AgendaEntry],
        all: [OrgTask],
        doneStates: Set<String>,
        hideHabits: Bool
    ) -> TodayItems {
        var events: [AgendaEntry] = []
        var byId: [String: AgendaEntry] = [:]
        var insertionOrder: [String] = []

        for entry in today {
            if AgendaEntryClassification.isEvent(entry) {
                events.append(entry)
                continue
            }
            // Strict "today only": drop deadline previews unconditionally.
            if entry.agendaType == "upcoming-deadline" { continue }

            let isTodayScheduled = matchesToday(entry.scheduled?.start)
            let isTodayDeadline = matchesToday(entry.deadline?.start)
            let isOverdueScheduled = isPast(entry.scheduled?.start)
            // A past-due deadline (no scheduled date, or a future one) must
            // still surface in Today — org-agenda keeps overdue deadlines on
            // the day view until done. Without this, a repeating deadline like
            // "Weekly Review" <…+1w> that slipped past Friday vanished entirely.
            let isOverdueDeadline = isPast(entry.deadline?.start)
            guard isTodayScheduled || isTodayDeadline || isOverdueScheduled || isOverdueDeadline else { continue }

            if hideHabits && entry.isHabit { continue }

            if let s = entry.todoState, doneStates.contains(s.uppercased()) { continue }

            if let existing = byId[entry.id] {
                // Prefer the deadline variant when both forms surface for the
                // same heading — deadlines tend to be more actionable.
                if entry.agendaType == "deadline" && existing.agendaType != "deadline" {
                    byId[entry.id] = entry
                }
            } else {
                byId[entry.id] = entry
                insertionOrder.append(entry.id)
            }
        }

        let todayIds = Set(byId.keys)

        let overdue: [OrgTask] = all.filter { task in
            guard (!hideHabits || !task.isHabit),
                  let comp = task.scheduled?.start,
                  isPast(comp),
                  !todayIds.contains(task.id),
                  let state = task.todoState, !state.isEmpty,
                  !doneStates.contains(state.uppercased())
            else { return false }
            return true
        }

        var main: [any TaskDisplayable] = []
        main.append(contentsOf: overdue.map { $0 as any TaskDisplayable })
        for id in insertionOrder {
            if let entry = byId[id] {
                main.append(entry as any TaskDisplayable)
            }
        }
        return TodayItems(events: events, main: main)
    }

    /// True when `item.scheduled.start` is strictly before today (local calendar).
    /// Exposed so views that need an "is this row overdue" decision don't
    /// duplicate the timestamp-component arithmetic.
    static func isOverdue(_ item: any TaskDisplayable) -> Bool {
        isPast(item.scheduled?.start)
    }

    /// True when the timestamp component's date is today (local calendar).
    static func matchesToday(_ comp: OrgTimestamp.Component?) -> Bool {
        guard let c = comp else { return false }
        let cal = Calendar.current
        let now = cal.dateComponents([.year, .month, .day], from: Date())
        return c.year == now.year && c.month == now.month && c.day == now.day
    }

    /// True when the timestamp component's date is strictly before today.
    static func isPast(_ comp: OrgTimestamp.Component?) -> Bool {
        guard let c = comp else { return false }
        var dc = DateComponents()
        dc.year = c.year; dc.month = c.month; dc.day = c.day
        let cal = Calendar.current
        guard let date = cal.date(from: dc) else { return false }
        return cal.startOfDay(for: date) < cal.startOfDay(for: Date())
    }
}
