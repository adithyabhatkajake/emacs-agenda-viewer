import SwiftUI

struct AllTasksView: View {
    @Environment(AppSettings.self) private var settings
    let store: TasksStore

    @State private var expandedIds: Set<String> = []
    @State private var expandedHabitIds: Set<String> = []

    @State private var includeDone = false
    @State private var searchText = ""

    var body: some View {
        @Bindable var bindable = settings
        NavigationStack {
            content
                .navigationTitle("All Tasks")
                .navigationBarTitleDisplayMode(.large)
                .toolbarBackground(Theme.background, for: .navigationBar)
                .background(Theme.background)
                .searchable(text: $searchText, prompt: "Search tasks")
                .toolbar {
                    SortMenuToolbar(options: SortKey.listOptions, selection: $bindable.listSort)
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
        .captureFAB(store: store)
        .task(id: settings.serverURLString) { await loadIfNeeded(); await loadHabitsIfNeeded() }
    }

    @ViewBuilder
    private var content: some View {
        if !settings.isConfigured {
            UnconfiguredStateView()
        } else if let tasks = store.allTasks.value {
            let filtered = filter(tasks)
            let activeHabits = filteredHabits()
            if filtered.isEmpty && activeHabits.isEmpty {
                EmptyStateView(title: searchText.isEmpty ? "No tasks" : "No matches", systemImage: "tray")
            } else {
                list(tasks: filtered, habits: activeHabits)
            }
        } else if store.allTasks.isLoading {
            DelayedProgressView()
        } else if let msg = store.allTasks.error {
            ErrorStateView(message: msg) { Task { await load() } }
        } else {
            Color.clear
        }
    }

    private func filter(_ tasks: [OrgTask]) -> [OrgTask] {
        let doneStates = Set((store.keywords?.allDone ?? []).map { $0.uppercased() })
        let base: [OrgTask]
        if includeDone {
            base = tasks
        } else {
            base = tasks.filter { task in
                guard let state = task.todoState else { return true }
                return !doneStates.contains(state.uppercased())
            }
        }
        guard !searchText.isEmpty else { return base }
        let needle = searchText.lowercased()
        return base.filter { task in
            task.title.lowercased().contains(needle)
                || task.tags.contains(where: { $0.lowercased().contains(needle) })
                || task.category.lowercased().contains(needle)
        }
    }

    private func filteredHabits() -> [Habit] {
        guard let habits = store.habits.value else { return [] }
        let active = habits.filter { $0.active }
        guard !searchText.isEmpty else { return active }
        let needle = searchText.lowercased()
        return active.filter { habit in
            habit.title.lowercased().contains(needle)
                || habit.tags.contains(where: { $0.lowercased().contains(needle) })
                || (habit.category ?? "").lowercased().contains(needle)
        }
    }

    private func list(tasks: [OrgTask], habits: [Habit]) -> some View {
        let doneStates = Set((store.keywords?.allDone ?? []).map { $0.uppercased() })
        let sortedItems = buildSortedItems(tasks: tasks, habits: habits, by: settings.listSort)
        return List(sortedItems) { item in
            switch item {
            case .task(let task):
                TaskRowItem(
                    task: task, doneStates: doneStates, store: store,
                    expandedIds: $expandedIds
                )
                .listRowBackground(Theme.surface)
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                .listRowSeparatorTint(Theme.borderSubtle)
            case .habit(let habit):
                HabitExpandableRow(
                    habit: habit,
                    store: store,
                    expandedIds: $expandedHabitIds
                )
                .listRowBackground(Theme.surface)
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                .listRowSeparatorTint(Theme.borderSubtle)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
    }

    /// Merge tasks and habits into a single sorted list using the same sort key.
    private func buildSortedItems(tasks: [OrgTask], habits: [Habit], by key: SortKey) -> [AllTasksItem] {
        let taskItems = sortTasks(tasks, by: key).map { AllTasksItem.task($0) }
        let habitItems = habits.map { AllTasksItem.habit($0) }
        let all = taskItems + habitItems

        // For the default sort (tasks already sorted, habits appended after),
        // return as-is — tasks stay in their natural sort order with habits at end.
        // For explicit keys, produce a unified interleaved sort so a habit with
        // priority B appears among tasks of priority B.
        guard key != .default else { return all }

        return all.sorted { a, b in
            switch key {
            case .priority:
                let rA = allTasksItemPriorityRank(a)
                let rB = allTasksItemPriorityRank(b)
                if rA != rB { return rA < rB }
                return allTasksItemTitle(a) < allTasksItemTitle(b)
            case .deadline:
                let dA = allTasksItemDeadlineRaw(a)
                let dB = allTasksItemDeadlineRaw(b)
                if dA != dB { return dA < dB }
                return allTasksItemTitle(a) < allTasksItemTitle(b)
            case .state:
                let sA = allTasksItemState(a)
                let sB = allTasksItemState(b)
                if sA != sB { return sA < sB }
                return allTasksItemTitle(a) < allTasksItemTitle(b)
            case .category:
                let cA = allTasksItemCategory(a)
                let cB = allTasksItemCategory(b)
                if cA != cB { return cA.localizedCompare(cB) == .orderedAscending }
                return allTasksItemTitle(a) < allTasksItemTitle(b)
            case .scheduled:
                let sA = allTasksItemScheduledRaw(a)
                let sB = allTasksItemScheduledRaw(b)
                if sA != sB { return sA < sB }
                return allTasksItemTitle(a) < allTasksItemTitle(b)
            case .default:
                return false
            }
        }
    }

    private func allTasksItemPriorityRank(_ item: AllTasksItem) -> Int {
        switch item {
        case .task(let t):  return priorityOrdinal(t.priority)
        case .habit(let h): return priorityOrdinal(h.priority)
        }
    }

    private func allTasksItemTitle(_ item: AllTasksItem) -> String {
        switch item {
        case .task(let t):  return t.title
        case .habit(let h): return h.title
        }
    }

    private func allTasksItemDeadlineRaw(_ item: AllTasksItem) -> String {
        switch item {
        case .task(let t):  return t.deadline?.raw ?? t.scheduled?.raw ?? ""
        case .habit(let h): return h.nextDue ?? ""
        }
    }

    private func allTasksItemScheduledRaw(_ item: AllTasksItem) -> String {
        switch item {
        case .task(let t):  return t.scheduled?.raw ?? ""
        case .habit(let h): return h.nextDue ?? ""
        }
    }

    private func allTasksItemState(_ item: AllTasksItem) -> String {
        switch item {
        case .task(let t):  return t.todoState ?? ""
        case .habit(let h): return h.state ?? ""
        }
    }

    private func allTasksItemCategory(_ item: AllTasksItem) -> String {
        switch item {
        case .task(let t):  return t.category
        case .habit(let h): return h.category ?? ""
        }
    }

    private func priorityOrdinal(_ p: String?) -> Int {
        switch p?.uppercased() {
        case "A": return 0
        case "B": return 1
        case "C": return 2
        case "D": return 3
        default:  return 4
        }
    }

    private func load() async {
        guard let client = settings.apiClient else { return }
        await store.loadAllTasks(using: client, includeDone: includeDone)
    }

    private func loadIfNeeded() async {
        if store.allTasks.value == nil { await load() }
    }

    private func loadHabitsIfNeeded() async {
        guard let client = settings.apiClient else { return }
        if store.habits.value == nil {
            await store.loadHabits(using: client)
        }
    }
}

// MARK: - AllTasksItem

private enum AllTasksItem: Identifiable {
    case task(OrgTask)
    case habit(Habit)

    var id: String {
        switch self {
        case .task(let t):  return "task-\(t.id)"
        case .habit(let h): return "habit-\(h.id)"
        }
    }
}

