import SwiftUI

@MainActor
struct RowActionFactory {
    let store: TasksStore
    let settings: AppSettings
    let selection: Selection
    let clocks: ClockManager
    let sync: CalendarSync?

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
                    await store.toggleDone(snapshot, file: file, pos: pos, using: client)
                }
            },
            setPriority: { p in
                Task { @MainActor in
                    guard let client = settings.apiClient else { return }
                    await store.setPriority(taskId: id, file: file, pos: pos, priority: p, using: client)
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
                selection.taskId = id
                selection.inspectorVisible = true
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
