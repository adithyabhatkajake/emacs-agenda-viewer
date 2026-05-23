#if !os(macOS)
import SwiftUI

struct TagEditorSheet: View {
    let task: any TaskDisplayable
    let store: TasksStore

    @Environment(AppSettings.self) private var settings

    @State private var draftTags: [String]
    @State private var newTagText: String = ""
    @State private var isMutating: Bool = false
    @State private var errorMessage: String?

    init(task: any TaskDisplayable, store: TasksStore) {
        self.task = task
        self.store = store
        _draftTags = State(initialValue: task.tags)
    }

    private var client: APIClient? { settings.apiClient }

    var body: some View {
        PickerSheetScaffold(
            title: "Tags",
            isMutating: isMutating,
            saveAction: { await save() }
        ) {
            Form {
                Section("Current Tags") {
                    if draftTags.isEmpty {
                        Text("No tags")
                            .foregroundStyle(.secondary)
                    } else {
                        FlowTagRow(tags: draftTags) { removed in
                            draftTags.removeAll { $0 == removed }
                        }
                    }
                }

                Section("Add Tag") {
                    HStack {
                        TextField("New tag", text: $newTagText)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .submitLabel(.done)
                            .onSubmit { addTag() }
                        Button("Add", action: addTag)
                            .disabled(newTagText.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }

                ErrorSection(errorMessage)
            }
        }
    }

    private func addTag() {
        let trimmed = newTagText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !draftTags.contains(trimmed) else { return }
        draftTags.append(trimmed)
        newTagText = ""
    }

    private func save() async -> Bool {
        guard let client else { return false }
        isMutating = true
        errorMessage = nil
        let ok = await store.setTags(
            taskId: task.id, file: task.file, pos: task.pos,
            tags: draftTags, using: client
        )
        isMutating = false
        if !ok { errorMessage = store.lastMutationError ?? "Couldn't save change" }
        return ok
    }
}

// Vertically stacked chip list. Named "Flow" for historical reasons but uses
// LazyVStack (one chip per row) — sufficient for the typical tag count on iOS.
private struct FlowTagRow: View {
    let tags: [String]
    let onRemove: (String) -> Void

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                HStack(spacing: 4) {
                    Text(tag)
                        .font(.subheadline)
                    Button {
                        onRemove(tag)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(.systemGray5))
                .clipShape(Capsule())
            }
        }
    }
}
#endif
