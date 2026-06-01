#if !os(macOS)
import SwiftUI

/// Quick-action menu attached to task rows via `.contextMenu`. The unified
/// "Edit…" entry opens `EditTaskSheet` for full edits (title, state, priority,
/// tags, scheduled, deadline, notes). Mark Done / Clock / Pin are left as
/// direct quick-toggles because they don't benefit from a form sheet.
struct TaskRowMenu: View {
    let task: any TaskDisplayable
    let store: TasksStore
    let doneStates: Set<String>
    /// Invoked when the user picks "Edit…". Sheet presentation lives on the
    /// enclosing row (`ExpandableTaskRow`); the menu just signals.
    var onEdit: (() -> Void)? = nil
    /// Kept for backward compatibility — no longer wired to a menu item, but
    /// callers that set it are still valid and will not crash.
    var onEditNotes: (() -> Void)? = nil

    @Environment(AppSettings.self) private var settings
    @Environment(ClockManager.self) private var clocks
    var onClockToggle: (() -> Void)? = nil
    var onPinToggle: (() -> Void)? = nil
    private var client: APIClient? { settings.apiClient }

    private var isDone: Bool {
        guard let s = task.todoState else { return false }
        return doneStates.contains(s.uppercased())
    }

    private var isPinnedToday: Bool {
        guard let task = currentTask() else { return false }
        return TaskFilters.isPinnedToday(task)
    }

    private func currentTask() -> OrgTask? {
        store.allTasks.value?.first { $0.id == task.id }
    }

    var body: some View {
        // Edit — unified sheet for title / state / priority / tags /
        // scheduled / deadline / notes. Shown first so it's the primary
        // discoverable action on long-press.
        if let onEdit {
            Button(action: onEdit) {
                Label("Edit\u{2026}", systemImage: "square.and.pencil")
            }
        }

        // Mark Done / Reopen — kept as a direct toggle so the user can tick
        // tasks off without opening the full edit sheet.
        Button {
            run { try await client?._toggleDone(task: task, store: store, doneStates: doneStates) }
        } label: {
            Label(isDone ? "Reopen" : "Mark Done",
                  systemImage: isDone ? "arrow.uturn.backward.circle" : "checkmark.circle")
        }

        Divider()

        // Clock In / Out via ClockManager (server-side clocks — start fires
        // a POST /api/clock/in; stop fires POST /api/clock/out and persists
        // the finished CLOCK: line to the task's LOGBOOK drawer via the daemon).
        Button {
            onClockToggle?()
            if isClockedHere {
                run { _ = await clocks.stop(taskId: task.id, using: client!, store: store) }
            } else {
                run { await clocks.clockIn(task: task, using: client!) }
            }
        } label: {
            Label(isClockedHere ? "Clock Out" : "Clock In",
                  systemImage: isClockedHere ? "stop.circle" : "play.circle")
        }

        // Pin to My Day — delegates to TaskQuickActions so the swipe and
        // context-menu paths stay on the same store call.
        Button {
            onPinToggle?()
            TaskQuickActions(task: task, store: store, client: client).togglePin()
        } label: {
            Label(isPinnedToday ? "Unpin from My Day" : "Pin to My Day",
                  systemImage: isPinnedToday ? "pin.slash" : "pin")
        }
    }

    private var isClockedHere: Bool {
        clocks.isClocked(taskId: task.id)
    }

    // Fire-and-forget — contextMenu actions must return synchronously, so
    // every closure spawns a Task. Failures surface via store.lastMutationError
    // (silent at the row level by design; the user can retry via the sheet
    // if the action fails).
    private func run(_ op: @escaping () async throws -> Void) {
        guard client != nil else { return }
        Task { try? await op() }
    }

}

// Thin shim so the contextMenu closure can reuse the store.toggleDone helper
// without re-implementing the keyword lookup inline.
private extension APIClient {
    func _toggleDone(task: any TaskDisplayable, store: TasksStore, doneStates: Set<String>) async throws {
        _ = await store.toggleDone(task, file: task.file, pos: task.pos, using: self)
    }
}
#endif
