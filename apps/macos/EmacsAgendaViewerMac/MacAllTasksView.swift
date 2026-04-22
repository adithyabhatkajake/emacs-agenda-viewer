import SwiftUI

struct MacAllTasksView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(Selection.self) private var selection
    @Environment(ClockManager.self) private var clocks
    @Environment(CalendarSync.self) private var sync
    let store: TasksStore

    @State private var includeDone = false
    @State private var searchText = ""
    @State private var collapsedGroups: Set<String> = []

    var body: some View {
        @Bindable var bindable = settings
        content
            .navigationTitle("All Tasks")
            .searchable(text: $searchText, placement: .toolbar, prompt: "Search tasks")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    SortMenu(options: SortKey.listOptions, selection: $bindable.listSort)
                }
                ToolbarItem(placement: .primaryAction) {
                    GroupMenu(selection: $bindable.listGroup)
                }
                ToolbarItem(placement: .primaryAction) {
                    Toggle(isOn: $includeDone) {
                        Label("Include completed", systemImage: "checkmark.circle")
                    }
                    .toggleStyle(.button)
                    .disabled(!settings.isConfigured)
                }
                ToolbarItem(placement: .primaryAction) {
                    ReloadButton(action: { Task { await load() } }, disabled: !settings.isConfigured)
                }
            }
            .onChange(of: includeDone) { _, _ in
                Task { await load() }
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
        let filtered: [OrgTask]
        if searchText.isEmpty {
            filtered = tasks
        } else {
            let needle = searchText.lowercased()
            filtered = tasks.filter { task in
                task.title.lowercased().contains(needle)
                    || task.tags.contains(where: { $0.lowercased().contains(needle) })
                    || task.category.lowercased().contains(needle)
            }
        }
        return sortTasks(filtered, by: settings.listSort)
    }

    private func list(_ tasks: [OrgTask]) -> some View {
        let doneStates = Set((store.keywords?.allDone ?? []).map { $0.uppercased() })
        let factory = RowActionFactory(store: store, settings: settings, selection: selection, clocks: clocks, sync: sync)
        let groups = groupTasks(tasks, by: settings.listGroup)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(groups) { group in
                    GroupSection(
                        label: group.label,
                        items: group.items,
                        doneStates: doneStates,
                        factory: factory,
                        selection: selection,
                        store: store,
                        collapsed: $collapsedGroups
                    )
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
