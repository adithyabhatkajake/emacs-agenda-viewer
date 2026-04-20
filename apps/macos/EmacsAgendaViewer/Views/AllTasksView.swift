import SwiftUI

struct AllTasksView: View {
    @Environment(AppSettings.self) private var settings
    let store: TasksStore

    @State private var includeDone = false
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("All Tasks")
                .navigationBarTitleDisplayMode(.large)
                .toolbarBackground(Theme.background, for: .navigationBar)
                .background(Theme.background)
                .searchable(text: $searchText, prompt: "Search tasks")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Toggle("Include completed", isOn: $includeDone)
                        } label: {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                        }
                    }
                }
                .refreshable { await load() }
                .onChange(of: includeDone) { _, _ in
                    Task { await load() }
                }
        }
        .task(id: settings.serverURLString) { await loadIfNeeded() }
    }

    @ViewBuilder
    private var content: some View {
        if !settings.isConfigured {
            UnconfiguredStateView()
        } else if let tasks = store.allTasks.value {
            let filtered = filter(tasks)
            if filtered.isEmpty {
                EmptyStateView(title: searchText.isEmpty ? "No tasks" : "No matches", systemImage: "tray")
            } else {
                list(filtered)
            }
        } else if store.allTasks.isLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let msg = store.allTasks.error {
            ErrorStateView(message: msg) { Task { await load() } }
        } else {
            Color.clear
        }
    }

    private func filter(_ tasks: [OrgTask]) -> [OrgTask] {
        guard !searchText.isEmpty else { return tasks }
        let needle = searchText.lowercased()
        return tasks.filter { task in
            task.title.lowercased().contains(needle)
                || task.tags.contains(where: { $0.lowercased().contains(needle) })
                || task.category.lowercased().contains(needle)
        }
    }

    private func list(_ tasks: [OrgTask]) -> some View {
        let doneStates = Set((store.keywords?.allDone ?? []).map { $0.uppercased() })
        return List(tasks) { task in
            TaskRow(task: task, doneStates: doneStates)
                .listRowBackground(Theme.background)
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                .listRowSeparatorTint(Theme.borderSubtle)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
    }

    private func load() async {
        guard let client = settings.apiClient else { return }
        await store.loadAllTasks(using: client, includeDone: includeDone)
    }

    private func loadIfNeeded() async {
        if store.allTasks.value == nil { await load() }
    }
}
