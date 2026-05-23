import SwiftUI

/// Pinned ("My Day") view for iOS: shows tasks whose :PINNED: property equals
/// today's date (YYYY-MM-DD). Yesterday's pins silently disappear at midnight.
struct PinnedView: View {
    @Environment(AppSettings.self) private var settings
    let store: TasksStore

    @State private var expandedIds: Set<String> = []

    var body: some View {
        @Bindable var bindable = settings
        NavigationStack {
            content
                .navigationTitle("Pinned")
                .navigationBarTitleDisplayMode(.large)
                .toolbarBackground(Theme.background, for: .navigationBar)
                .background(Theme.background)
                .refreshable { await load() }
                .toolbar {
                    SortMenuToolbar(options: SortKey.listOptions, selection: $bindable.listSort)
                }
        }
        .captureFAB(store: store)
        .task(id: settings.serverURLString) { await loadIfNeeded() }
    }

    @ViewBuilder
    private var content: some View {
        if !settings.isConfigured {
            UnconfiguredStateView()
        } else if let tasks = store.allTasks.value {
            let pinned = tasks.filter { TaskFilters.isPinnedToday($0) }
            if pinned.isEmpty {
                EmptyStateView(title: "Nothing pinned for today", systemImage: "pin.slash")
            } else {
                pinnedList(pinned)
            }
        } else if store.allTasks.isLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let msg = store.allTasks.error {
            ErrorStateView(message: msg) { Task { await load() } }
        } else {
            Color.clear
        }
    }

    private func pinnedList(_ tasks: [OrgTask]) -> some View {
        let doneStates = Set((store.keywords?.allDone ?? []).map { $0.uppercased() })
        let sorted = sortTasks(tasks, by: settings.listSort)
        return List(sorted) { task in
            TaskRowItem(
                task: task, doneStates: doneStates, store: store,
                expandedIds: $expandedIds
            )
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
        await store.loadAllTasks(using: client, includeDone: false)
    }

    private func loadIfNeeded() async {
        if store.allTasks.value == nil { await load() }
    }
}
