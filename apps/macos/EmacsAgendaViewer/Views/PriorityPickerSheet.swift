#if !os(macOS)
import SwiftUI

struct PriorityPickerSheet: View {
    let task: any TaskDisplayable
    let store: TasksStore

    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings

    @State private var isMutating: Bool = false
    @State private var errorMessage: String?

    private var client: APIClient? { settings.apiClient }

    /// Ordered list from store if available, otherwise the conventional A/B/C defaults.
    private var availablePriorities: [String] {
        if let pr = store.priorities, !pr.all.isEmpty {
            return pr.all
        }
        return ["A", "B", "C"]
    }

    var body: some View {
        PickerSheetScaffold(
            title: "Priority",
            isMutating: isMutating,
            saveAction: nil
        ) {
            List {
                // "(none)" clears priority
                priorityRow(label: "(none)", value: "")

                ForEach(availablePriorities, id: \.self) { p in
                    priorityRow(label: p, value: p)
                }

                ErrorSection(errorMessage)
            }
        }
    }

    @ViewBuilder
    private func priorityRow(label: String, value: String) -> some View {
        Button {
            Task { await pick(value) }
        } label: {
            HStack {
                Text(label)
                    .foregroundStyle(.primary)
                Spacer()
                if task.priority == (value.isEmpty ? nil : value) {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
        }
        .disabled(isMutating || client == nil)
    }

    private func pick(_ value: String) async {
        guard let client else { return }
        isMutating = true
        errorMessage = nil
        let ok = await store.setPriority(
            taskId: task.id, file: task.file, pos: task.pos,
            priority: value, using: client
        )
        isMutating = false
        if ok {
            dismiss()
        } else {
            errorMessage = store.lastMutationError ?? "Couldn't save change"
        }
    }
}
#endif
