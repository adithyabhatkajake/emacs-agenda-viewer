import SwiftUI

@MainActor
struct RowActionFactory {
    let store: TasksStore
    let settings: AppSettings
    let selection: Selection
    let clocks: ClockManager
    let sync: CalendarSync?

    /// Compute checklist progress for a task using cached notes only.
    /// Returns nil when notes aren't cached yet or contain no checklist.
    /// Reads `notesCacheRevision` so the @Observable framework tracks
    /// dictionary mutations through the parent view's body.
    func progress(for task: any TaskDisplayable) -> ChecklistProgress? {
        _ = store.notesCacheRevision
        guard let notes = store.cachedNotes(file: task.file, pos: task.pos) else { return nil }
        return ChecklistProgress.compute(from: notes)
    }

    /// Prefetch closure to wire as `MacTaskRow.onAppear`. Idempotent — does
    /// nothing if already cached or already in flight.
    func prefetch(for task: any TaskDisplayable) -> () -> Void {
        let store = self.store
        let client = self.settings.apiClient
        let file = task.file
        let pos = task.pos
        return {
            guard let client else { return }
            store.prefetchNotes(file: file, pos: pos, using: client)
        }
    }

    func make(for task: any TaskDisplayable) -> TaskRowActions {
        let id = task.id
        let file = task.file
        let pos = task.pos
        let store = self.store
        let settings = self.settings
        let selection = self.selection
        let clocks = self.clocks
        let snapshot: TaskSnapshot = TaskSnapshot(task: task)
        return TaskRowActions(
            toggleDone: {
                Task { @MainActor in
                    guard let client = settings.apiClient else { return }
                    let wasDone = store.isDoneState(snapshot.todoState)
                    await store.toggleDone(snapshot, file: file, pos: pos, using: client)
                    // If we just transitioned into a done state, log and clear any running clock.
                    if !wasDone, clocks.isClocked(taskId: id) {
                        await clocks.stop(taskId: id, using: client, store: store)
                    }
                }
            },
            setPriority: { p in
                Task { @MainActor in
                    guard let client = settings.apiClient else { return }
                    await store.setPriority(taskId: id, file: file, pos: pos, priority: p, using: client)
                }
            },
            setState: { s in
                Task { @MainActor in
                    guard let client = settings.apiClient else { return }
                    await store.setState(taskId: id, file: file, pos: pos, state: s, using: client)
                    if store.isDoneState(s), clocks.isClocked(taskId: id) {
                        await clocks.stop(taskId: id, using: client, store: store)
                    }
                }
            },
            schedule: { date in
                Task { @MainActor in
                    guard let client = settings.apiClient else { return }
                    let ts = date.map { OrgTimestampFormat.string(date: $0, includeTime: false) } ?? ""
                    await store.setScheduled(taskId: id, file: file, pos: pos, timestamp: ts, using: client)
                    if let updated = store.allTasks.value?.first(where: { $0.id == id }) {
                        sync?.pushIfLinked(task: updated)
                    }
                }
            },
            setDeadline: { date in
                Task { @MainActor in
                    guard let client = settings.apiClient else { return }
                    let ts = date.map { OrgTimestampFormat.string(date: $0, includeTime: false) } ?? ""
                    await store.setDeadline(taskId: id, file: file, pos: pos, timestamp: ts, using: client)
                }
            },
            scheduleAt: { date, withTime in
                Task { @MainActor in
                    guard let client = settings.apiClient else { return }
                    let ts = date.map { OrgTimestampFormat.string(date: $0, includeTime: withTime) } ?? ""
                    await store.setScheduled(taskId: id, file: file, pos: pos, timestamp: ts, using: client)
                    if let updated = store.allTasks.value?.first(where: { $0.id == id }) {
                        sync?.pushIfLinked(task: updated)
                    }
                }
            },
            setDeadlineAt: { date, withTime in
                Task { @MainActor in
                    guard let client = settings.apiClient else { return }
                    let ts = date.map { OrgTimestampFormat.string(date: $0, includeTime: withTime) } ?? ""
                    await store.setDeadline(taskId: id, file: file, pos: pos, timestamp: ts, using: client)
                }
            },
            clockIn: {
                clocks.start(task: snapshot)
            },
            clockOut: {
                Task { @MainActor in
                    guard let client = settings.apiClient else { return }
                    await clocks.stop(taskId: id, using: client, store: store)
                }
            },
            openInspector: {
                if selection.taskId == id {
                    selection.taskId = nil
                } else {
                    selection.taskId = id
                }
            },
            editInspector: {
                selection.taskId = id
                selection.editingTaskId = id
                selection.editingTitle = snapshot.title
            },
            refile: {
                selection.refileTask = snapshot
            },
            setTags: { newTags in
                Task { @MainActor in
                    guard let client = settings.apiClient else { return }
                    await store.setTags(taskId: id, file: file, pos: pos, tags: newTags, using: client)
                }
            },
            saveTitle: { newTitle in
                let trimmed = newTitle.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, trimmed != snapshot.title else {
                    selection.editingTaskId = nil
                    return
                }
                Task { @MainActor in
                    guard let client = settings.apiClient else { return }
                    await store.setTitle(taskId: id, file: file, pos: pos, title: trimmed, using: client)
                    selection.editingTaskId = nil
                }
            }
        )
    }

    func isClocked(_ task: any TaskDisplayable) -> Bool {
        if clocks.isClocked(taskId: task.id) { return true }
        return store.clock?.clocking == true
            && store.clock?.file == task.file
            && store.clock?.pos == task.pos
    }
}

/// A frozen copy of the displayable fields of a task, so closures can reference
/// task data without keeping the originating model around.
struct TaskSnapshot: TaskDisplayable, Identifiable {
    let id: String
    let title: String
    let todoState: String?
    let priority: String?
    let tags: [String]
    let inheritedTags: [String]
    let scheduled: OrgTimestamp?
    let deadline: OrgTimestamp?
    let category: String
    let file: String
    let pos: Int

    init(task: any TaskDisplayable) {
        self.id = task.id
        self.title = task.title
        self.todoState = task.todoState
        self.priority = task.priority
        self.tags = task.tags
        self.inheritedTags = task.inheritedTags
        self.scheduled = task.scheduled
        self.deadline = task.deadline
        self.category = task.category
        self.file = task.file
        self.pos = task.pos
    }
}
