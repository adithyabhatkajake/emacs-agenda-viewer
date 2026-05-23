#if !os(macOS)
import SwiftUI

struct StatePickerSheet: View {
    let task: any TaskDisplayable
    let store: TasksStore

    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings

    @State private var isMutating: Bool = false
    @State private var errorMessage: String?

    private var client: APIClient? { settings.apiClient }

    private var activeStates: [String] { store.keywords?.allActive ?? [] }
    private var doneStates: [String] { store.keywords?.allDone ?? [] }

    var body: some View {
        PickerSheetScaffold(
            title: "State",
            isMutating: isMutating,
            saveAction: nil
        ) {
            List {
                if !activeStates.isEmpty {
                    Section("Active") {
                        ForEach(activeStates, id: \.self) { state in
                            stateRow(state)
                        }
                    }
                }

                if !doneStates.isEmpty {
                    Section("Done") {
                        ForEach(doneStates, id: \.self) { state in
                            stateRow(state)
                        }
                    }
                }

                if activeStates.isEmpty && doneStates.isEmpty {
                    Section {
                        Text("No keyword states available.")
                            .foregroundStyle(.secondary)
                    }
                }

                ErrorSection(errorMessage)
            }
        }
    }

    @ViewBuilder
    private func stateRow(_ state: String) -> some View {
        Button {
            Task { await pick(state) }
        } label: {
            HStack {
                Text(state)
                    .foregroundStyle(.primary)
                Spacer()
                if task.todoState?.uppercased() == state.uppercased() {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
        }
        .disabled(isMutating || client == nil)
    }

    private func pick(_ state: String) async {
        guard let client else { return }
        isMutating = true
        errorMessage = nil
        let ok = await store.setState(taskId: task.id, file: task.file, pos: task.pos, state: state, using: client)
        isMutating = false
        if ok {
            dismiss()
        } else {
            errorMessage = store.lastMutationError ?? "Couldn't save change"
        }
    }
}
#endif
