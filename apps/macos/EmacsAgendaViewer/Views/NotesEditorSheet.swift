#if !os(macOS)
import SwiftUI

/// Plain-text org-notes editor surfaced via long-press → "Edit notes…"
/// from `ExpandableTaskRow` or `TaskDetailView`. Mirrors the existing
/// sheet pattern (Cancel / Save toolbar, spinner overlay, error section).
/// Persists through `store.setNotes` so the cache + Today/Upcoming caches
/// stay in sync.
struct NotesEditorSheet: View {
    let task: any TaskDisplayable
    let store: TasksStore
    let initialNotes: String
    /// Called with the saved-back body so the parent can update its local
    /// render copy without re-fetching `/api/notes`.
    let onSaved: (String) -> Void

    @Environment(AppSettings.self) private var settings

    @State private var draft: String = ""
    @State private var isMutating: Bool = false
    @State private var errorMessage: String?

    private var client: APIClient? { settings.apiClient }
    private var saveDisabled: Bool { client == nil || draft == initialNotes }

    var body: some View {
        PickerSheetScaffold(
            title: "Edit Notes",
            isMutating: isMutating,
            saveAction: { await save() },
            saveDisabled: saveDisabled
        ) {
            Form {
                Section {
                    TextEditor(text: $draft)
                        .font(.system(size: 14, design: .monospaced))
                        .frame(minHeight: 240)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.sentences)
                } header: {
                    Text("Notes")
                } footer: {
                    Text("Raw org-mode markup. Checklists, bullets, links and \u{002A}emphasis\u{002A} are rendered when you save.")
                }

                ErrorSection(errorMessage)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .onAppear { draft = initialNotes }
    }

    private func save() async -> Bool {
        guard let client else { return false }
        isMutating = true
        errorMessage = nil
        let ok = await store.setNotes(
            file: task.file, pos: task.pos,
            notes: draft, using: client
        )
        isMutating = false
        if ok {
            onSaved(store.notesCache["\(task.file)::\(task.pos)"] ?? draft)
        } else {
            errorMessage = store.lastMutationError ?? "Couldn't save notes"
        }
        return ok
    }
}
#endif
