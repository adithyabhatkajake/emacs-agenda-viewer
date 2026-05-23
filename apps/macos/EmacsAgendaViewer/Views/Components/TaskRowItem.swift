#if !os(macOS)
import SwiftUI

/// Single source-of-truth row used by Today / Upcoming / Pinned / Inbox /
/// AllTasks. Interaction model:
///  - **Tap the row** → toggle inline expansion of notes (checklists + prose)
///  - **Tap the checkbox** → toggle done state
///  - **Long-press the row** → context menu (state / priority / schedule /
///    clock / pin / edit notes)
///
/// `expandedIds` lives in the parent list view so scroll-off row recycling
/// doesn't reset state mid-session and tab-switches naturally collapse
/// everything.
struct TaskRowItem: View {
    let task: any TaskDisplayable
    let doneStates: Set<String>
    let store: TasksStore
    @Binding var expandedIds: Set<String>

    private var isExpandedBinding: Binding<Bool> {
        Binding(
            get: { expandedIds.contains(task.id) },
            set: { wants in
                if wants { expandedIds.insert(task.id) }
                else { expandedIds.remove(task.id) }
            }
        )
    }

    var body: some View {
        ExpandableTaskRow(
            task: task,
            doneStates: doneStates,
            store: store,
            isExpanded: isExpandedBinding
        )
    }
}
#endif
