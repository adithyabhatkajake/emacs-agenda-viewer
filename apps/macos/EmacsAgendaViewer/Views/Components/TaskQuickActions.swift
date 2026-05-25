#if !os(macOS)
import SwiftUI

/// Shared quick-action helpers for swipe actions and the context menu.
/// Extracting pin here keeps both entry points on the same store call path.
@MainActor
struct TaskQuickActions {
    let task: any TaskDisplayable
    let store: TasksStore
    let client: APIClient?

    var isPinnedToday: Bool {
        store.allTasks.value?.first { $0.id == task.id }.map(TaskFilters.isPinnedToday) ?? false
    }

    func togglePin() {
        guard let client else { return }
        let value = isPinnedToday ? "" : DateQuery.today()
        Task {
            _ = await store.setProperty(
                taskId: task.id, file: task.file, pos: task.pos,
                key: "PINNED", value: value, using: client
            )
        }
    }
}
#endif
