#if !os(macOS)
import SwiftUI

/// Logbook view: DONE/KILL tasks grouped by their CLOSED timestamp,
/// descending (most recent bucket first). iOS counterpart of MacLogbookView.
struct LogbookView: View {
    @Environment(AppSettings.self) private var settings
    let store: TasksStore

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
                EmptyStateView(title: "No completed tasks yet", systemImage: "checkmark.seal")
            } else {
                groupedList(filtered)
            }
        } else if store.allTasks.isLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
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
                        NavigationLink {
                            TaskDetailView(task: task, doneStates: doneStates, store: store)
                        } label: {
                            TaskRow(task: task, doneStates: doneStates)
                        }
                        .listRowBackground(Theme.background)
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
#endif
