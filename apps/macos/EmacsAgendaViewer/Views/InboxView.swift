import SwiftUI

/// Inbox view for iOS: tasks whose category is "Inbox" (case-insensitive),
/// have an active todo state, and are not in a done state. Uses
/// `TaskFilters.isInbox` — the same predicate as `MacInboxView` — so both
/// platforms show the same triage bucket.
struct InboxView: View {
    @Environment(AppSettings.self) private var settings
    let store: TasksStore

    @State private var expandedIds: Set<String> = []

    var body: some View {
        @Bindable var bindable = settings
        NavigationStack {
            content
                .navigationTitle("Inbox")
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
            let doneStates = TaskFilters.resolvedDoneSet(store.keywords)
            let filtered = tasks.filter { TaskFilters.isInbox($0, doneStates: doneStates) }
            let inbox = sortTasks(filtered, by: settings.listSort)
            if inbox.isEmpty {
                EmptyStateView(title: "Inbox empty", systemImage: "tray")
            } else {
                inboxList(inbox, doneStates: doneStates)
            }
        } else if store.allTasks.isLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let msg = store.allTasks.error {
            ErrorStateView(message: msg) { Task { await load() } }
        } else {
            Color.clear
        }
    }

    private func inboxList(_ tasks: [OrgTask], doneStates: Set<String>) -> some View {
        List(tasks) { task in
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

    /// Lower rank = higher priority. A=0, B=1, C=2, nil=3.
    private func priorityRank(_ p: String?) -> Int {
        switch p?.uppercased() {
        case "A": return 0
        case "B": return 1
        case "C": return 2
        default:  return 3
        }
    }

    private func load() async {
        guard let client = settings.apiClient else { return }
        await store.loadAllTasks(using: client, includeDone: false)
    }

    private func loadIfNeeded() async {
        if store.allTasks.value == nil { await load() }
    }
}
