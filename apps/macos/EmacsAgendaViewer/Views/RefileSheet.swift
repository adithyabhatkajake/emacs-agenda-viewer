#if !os(macOS)
import SwiftUI

/// Refile sheet (iOS): move a task subtree under a different parent
/// heading in any agenda file. Mirrors Mac's RefileSheet but uses iOS
/// idioms — NavigationStack + .searchable + plain List.
///
/// Not using PickerSheetScaffold: this sheet has a .searchable modifier
/// and a conditional content view (loading / error / empty / list states)
/// that don't fit the scaffold's NavigationStack+ZStack pattern without
/// adding leaky escape hatches.
struct RefileSheet: View {
    let task: any TaskDisplayable
    let store: TasksStore

    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings

    @State private var searchText = ""
    @State private var isMutating = false
    @State private var errorMessage: String?
    // Tracks a failure from the refile-target load specifically. Using the
    // store-wide lastMutationError is wrong because any unrelated successful
    // mutation clears it (TasksStore.runMutation always resets it on entry),
    // leaving refileTargets empty but the error nil — which rendered as the
    // misleading "No refile targets — configure org-refile-targets" state.
    @State private var loadError: String?

    private var client: APIClient? { settings.apiClient }

    private var filteredTargets: [RefileTarget] {
        let needle = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return store.refileTargets }
        // Substring-AND across whitespace tokens — "ira okr" matches names
        // containing both "ira" and "okr" in any order.
        let tokens = needle.split(separator: " ").map(String.init)
        return store.refileTargets.filter { target in
            let hay = target.name.lowercased()
            return tokens.allSatisfy { hay.contains($0) }
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                content
                if isMutating {
                    ProgressView()
                        .controlSize(.large)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.ultraThinMaterial)
                }
            }
            .navigationTitle("Refile")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search refile targets")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isMutating)
                }
            }
            .task {
                guard !store.refileTargetsLoaded, let client else { return }
                let ok = await store.loadRefileTargets(using: client)
                if !ok {
                    loadError = store.lastMutationError ?? "Couldn't load refile targets"
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !store.refileTargetsLoaded {
            ProgressView("Loading targets\u{2026}")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.refileTargets.isEmpty, let err = loadError {
            // Bridge / network failure (e.g. one of the agenda buffers in
            // org-refile-get-targets is in a non-org major mode). Surface
            // the error and let the user retry without dismissing the sheet.
            ContentUnavailableView {
                Label("Couldn't load refile targets", systemImage: "exclamationmark.triangle")
            } description: {
                Text(err)
            } actions: {
                Button("Retry") {
                    Task {
                        guard let client else { return }
                        store.refileTargetsLoaded = false
                        loadError = nil
                        let ok = await store.loadRefileTargets(using: client)
                        if !ok {
                            loadError = store.lastMutationError ?? "Couldn't load refile targets"
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        } else if store.refileTargets.isEmpty {
            ContentUnavailableView(
                "No refile targets",
                systemImage: "doc.text.magnifyingglass",
                description: Text("Configure org-refile-targets in Emacs.")
            )
        } else if filteredTargets.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            List {
                if let err = errorMessage {
                    Section {
                        Text(err)
                            .foregroundStyle(Theme.priorityA)
                            .font(.footnote)
                    }
                }
                Section {
                    ForEach(filteredTargets) { target in
                        targetRow(target)
                    }
                } footer: {
                    Text("Moving “\(task.title)” to the selected heading.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
    }

    @ViewBuilder
    private func targetRow(_ target: RefileTarget) -> some View {
        Button { Task { await refile(to: target) } } label: {
            HStack(spacing: 12) {
                Image(systemName: "arrow.turn.right.down")
                    .font(.body)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(target.name)
                        .font(.body)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                    Text(fileLabel(target.file))
                        .font(.caption.monospaced())
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isMutating)
    }

    private func fileLabel(_ file: String) -> String {
        URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent
    }

    private func refile(to target: RefileTarget) async {
        guard let client else { return }
        isMutating = true
        errorMessage = nil
        let ok = await store.refile(
            sourceFile: task.file, sourcePos: task.pos,
            target: target, using: client
        )
        isMutating = false
        if ok {
            dismiss()
        } else {
            errorMessage = store.lastMutationError ?? "Couldn't refile"
        }
    }
}
#endif
