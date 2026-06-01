#if !os(macOS)
import SwiftUI

/// Logbook view: DONE/KILL tasks grouped by their CLOSED timestamp,
/// descending (most recent bucket first). iOS counterpart of MacLogbookView.
struct LogbookView: View {
    @Environment(AppSettings.self) private var settings
    let store: TasksStore

    @State private var expandedIds: Set<String> = []

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Logbook")
                .navigationBarTitleDisplayMode(.large)
                .toolbarBackground(Theme.background, for: .navigationBar)
                .background(Theme.background)
                .refreshable { await load() }
        }
        .task(id: settings.serverURLString) { await loadIfNeeded() }
    }

    @ViewBuilder
    private var content: some View {
        if !settings.isConfigured {
            UnconfiguredStateView()
        } else if let tasks = store.allTasks.value {
            let filtered = doneTasks(from: tasks)
            if filtered.isEmpty {
                EmptyStateView(title: "No completed tasks yet", systemImage: "book.closed.fill")
            } else {
                groupedList(filtered)
            }
        } else if store.allTasks.isLoading {
            DelayedProgressView()
        } else if let msg = store.allTasks.error {
            ErrorStateView(message: msg) { Task { await load() } }
        } else {
            Color.clear
        }
    }

    private func doneTasks(from tasks: [OrgTask]) -> [OrgTask] {
        TaskFilters.doneTasks(from: tasks, keywords: store.keywords)
    }

    private func groupedList(_ tasks: [OrgTask]) -> some View {
        let groups = groupTasksByClosedDate(tasks)
        let doneStates = Set((store.keywords?.allDone ?? []).map { $0.uppercased() })
        return List {
            ForEach(groups, id: \.id) { group in
                Section {
                    ForEach(group.items, id: \.id) { task in
                        LogbookRow(
                            task: task, doneStates: doneStates, store: store,
                            expandedIds: $expandedIds
                        )
                        .listRowBackground(Theme.surface)
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                        .listRowSeparatorTint(Theme.borderSubtle)
                    }
                } header: {
                    Text(group.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .textCase(nil)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
    }

    private func load() async {
        guard let client = settings.apiClient else { return }
        await store.loadAllTasks(using: client, includeDone: true)
    }

    private func loadIfNeeded() async {
        let alreadyHasDone = store.allTasks.value?.contains(where: { store.isDoneState($0.todoState) }) ?? false
        if store.allTasks.value == nil || !alreadyHasDone {
            await load()
        }
    }
}

/// Single logbook row: `TaskRowItem` interaction (tap = expand, long-press =
/// context menu with Reopen + Archive). Archive is gated here and not surfaced
/// anywhere else because `org-archive-subtree` is destructive — the heading
/// moves to the `.org_archive` file and disappears from every eavd index view.
private struct LogbookRow: View {
    let task: OrgTask
    let doneStates: Set<String>
    let store: TasksStore
    @Binding var expandedIds: Set<String>

    @Environment(AppSettings.self) private var settings
    @State private var showArchiveConfirm = false

    private var client: APIClient? { settings.apiClient }

    var body: some View {
        TaskRowItem(
            task: task, doneStates: doneStates, store: store,
            expandedIds: $expandedIds
        )
        .contextMenu {
            TaskRowMenu(
                task: task, store: store, doneStates: doneStates
            )
            Divider()
            Button(role: .destructive) {
                showArchiveConfirm = true
            } label: {
                Label("Archive\u{2026}", systemImage: "archivebox")
            }
        }
        .confirmationDialog(
            "Archive this task?",
            isPresented: $showArchiveConfirm,
            titleVisibility: .visible
        ) {
            Button("Archive", role: .destructive) {
                guard let client else { return }
                Task { _ = await store.archive(task, using: client) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The heading will be moved to the org archive file. This cannot be undone from the app.")
        }
    }
}
#endif
