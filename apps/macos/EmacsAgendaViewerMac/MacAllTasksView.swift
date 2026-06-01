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
                    GroupMenu(primary: $bindable.listGroup, secondary: $bindable.listGroupSecondary)
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
            let habits = store.habits.value ?? []
            let activeHabits = habits.filter { $0.active }
            let combined = buildCombined(tasks: tasks, habits: activeHabits)
            if combined.isEmpty {
                EmptyStateView(title: searchText.isEmpty ? "No tasks" : "No matches", systemImage: "tray")
            } else {
                list(combined)
            }
        } else if store.allTasks.isLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let msg = store.allTasks.error {
            ErrorStateView(message: msg) { Task { await load() } }
        } else {
            Color.clear
        }
    }

    // MARK: - AllTasksItem: unified task + habit

    private enum AllTasksItem: Identifiable {
        case task(OrgTask)
        case habit(Habit)

        var id: String {
            switch self {
            case .task(let t):  return "task-\(t.id)"
            case .habit(let h): return "habit-\(h.id)"
            }
        }

        var priority: String? {
            switch self {
            case .task(let t):  return t.priority
            case .habit(let h): return h.priority
            }
        }

        var category: String {
            switch self {
            case .task(let t):  return t.category
            case .habit(let h): return h.category ?? ""
            }
        }

        var todoState: String? {
            switch self {
            case .task(let t):  return t.todoState
            case .habit(let h): return h.state
            }
        }

        var tags: [String] {
            switch self {
            case .task(let t):  return t.tags + t.inheritedTags.filter { !t.tags.contains($0) }
            case .habit(let h): return h.tags
            }
        }

        var file: String {
            switch self {
            case .task(let t): return t.file
            case .habit:       return ""
            }
        }

        var title: String {
            switch self {
            case .task(let t): return t.title
            case .habit(let h): return h.title
            }
        }

        var scheduledMs: Double {
            switch self {
            case .task(let t):
                if let raw = t.scheduled?.raw, !raw.isEmpty,
                   let d = OrgTimestamp.parseDateString(raw) {
                    return d.timeIntervalSince1970 * 1000
                }
                if let raw = t.deadline?.raw, !raw.isEmpty,
                   let d = OrgTimestamp.parseDateString(raw) {
                    return d.timeIntervalSince1970 * 1000
                }
                return Double.infinity
            case .habit(let h):
                guard let nd = h.nextDue, !nd.isEmpty,
                      let d = OrgTimestamp.parseDateString(nd)
                else { return Double.infinity }
                return d.timeIntervalSince1970 * 1000
            }
        }
    }

    // MARK: - Build combined list

    private func buildCombined(tasks: [OrgTask], habits: [Habit]) -> [AllTasksItem] {
        let taskItems = filterTasks(tasks).map { AllTasksItem.task($0) }
        let habitItems = filterHabits(habits).map { AllTasksItem.habit($0) }
        let all = taskItems + habitItems
        return sortCombined(all, by: settings.listSort)
    }

    private func filterTasks(_ tasks: [OrgTask]) -> [OrgTask] {
        guard !searchText.isEmpty else { return tasks }
        let needle = searchText.lowercased()
        return tasks.filter { task in
            task.title.lowercased().contains(needle)
                || task.tags.contains(where: { $0.lowercased().contains(needle) })
                || task.category.lowercased().contains(needle)
        }
    }

    private func filterHabits(_ habits: [Habit]) -> [Habit] {
        guard !searchText.isEmpty else { return habits }
        let needle = searchText.lowercased()
        return habits.filter { h in
            h.title.lowercased().contains(needle)
                || (h.category ?? "").lowercased().contains(needle)
                || h.tags.contains(where: { $0.lowercased().contains(needle) })
        }
    }

    private func sortCombined(_ items: [AllTasksItem], by key: SortKey) -> [AllTasksItem] {
        items.sorted { a, b in
            switch key {
            case .priority:
                let rA = priorityOrd(a.priority)
                let rB = priorityOrd(b.priority)
                if rA != rB { return rA < rB }
                if a.scheduledMs != b.scheduledMs { return a.scheduledMs < b.scheduledMs }
                return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            case .scheduled, .deadline:
                if a.scheduledMs != b.scheduledMs { return a.scheduledMs < b.scheduledMs }
                return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            case .category:
                if a.category != b.category {
                    return a.category.localizedCaseInsensitiveCompare(b.category) == .orderedAscending
                }
                return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            case .state:
                let sA = a.todoState ?? ""
                let sB = b.todoState ?? ""
                if sA != sB { return sA.localizedCaseInsensitiveCompare(sB) == .orderedAscending }
                return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            default:
                return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            }
        }
    }

    private func priorityOrd(_ p: String?) -> Int {
        switch p?.uppercased() {
        case "A": return 0
        case "B": return 1
        case "C": return 2
        case "D": return 3
        default:  return 4
        }
    }

    // MARK: - Grouping

    private struct AllTasksGroup: Identifiable {
        let id: String
        let label: String
        let items: [AllTasksItem]
    }

    private func groupCombined(
        _ items: [AllTasksItem],
        by key: GroupKey,
        eisenhower: EisenhowerGroupContext
    ) -> [AllTasksGroup] {
        guard key != .none else {
            return [AllTasksGroup(id: "_all", label: "", items: items)]
        }
        var buckets: [String: [AllTasksItem]] = [:]
        var order: [String] = []

        func push(_ groupLabel: String, _ item: AllTasksItem) {
            if buckets[groupLabel] == nil { buckets[groupLabel] = []; order.append(groupLabel) }
            buckets[groupLabel]?.append(item)
        }

        for item in items {
            switch key {
            case .priority:
                let label = item.priority.map { "Priority \($0.uppercased())" } ?? "No Priority"
                push(label, item)
            case .category:
                push(item.category.isEmpty ? "Uncategorized" : item.category, item)
            case .state:
                push((item.todoState?.isEmpty == false ? item.todoState! : "—").uppercased(), item)
            case .tag:
                let combined = item.tags
                if combined.isEmpty {
                    push("Untagged", item)
                } else {
                    for tag in combined { push(tag, item) }
                }
            case .file:
                if case .task(let t) = item {
                    let name = (t.file as NSString).lastPathComponent
                    push(name.isEmpty ? "Unknown file" : name, item)
                } else {
                    push("Habits", item)
                }
            case .eisenhower:
                if case .task(let t) = item {
                    push(eisenhowerQuadrant(for: t, context: eisenhower), item)
                } else {
                    let isImportant = eisenhower.importantPriorities.contains(item.priority?.uppercased() ?? "")
                    push(isImportant ? "Schedule" : "Eliminate", item)
                }
            case .none:
                break
            }
        }

        let sortedKeys: [String]
        switch key {
        case .priority:
            sortedKeys = order.sorted { lhs, rhs in
                if lhs == "No Priority" { return false }
                if rhs == "No Priority" { return true }
                return lhs < rhs
            }
        case .eisenhower:
            let quadrantOrder = ["Do First", "Schedule", "Delegate", "Eliminate"]
            sortedKeys = order.sorted { lhs, rhs in
                (quadrantOrder.firstIndex(of: lhs) ?? 99) < (quadrantOrder.firstIndex(of: rhs) ?? 99)
            }
        default:
            sortedKeys = order.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        }
        return sortedKeys.map { AllTasksGroup(id: $0, label: $0, items: buckets[$0] ?? []) }
    }

    // MARK: - List rendering

    private func list(_ items: [AllTasksItem]) -> some View {
        let doneStates = Set((store.keywords?.allDone ?? []).map { $0.uppercased() })
        let factory = RowActionFactory(store: store, settings: settings, selection: selection, clocks: clocks, sync: sync)
        let eisCtx = EisenhowerGroupContext(urgencyDays: settings.eisenhowerUrgencyDays, priorities: store.priorities)
        let groups = groupCombined(items, by: settings.listGroup, eisenhower: eisCtx)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(groups) { group in
                        allTasksGroupSection(group, doneStates: doneStates, factory: factory)
                    }
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, minHeight: 600, alignment: .leading)
                .background(
                    Rectangle()
                        .fill(Theme.background)
                        .contentShape(Rectangle())
                        .onTapGesture { selection.taskId = nil }
                )
            }
            .background(Theme.background)
            .onChange(of: selection.revealTaskId) { _, new in
                consumeReveal(new, proxy: proxy)
            }
            .onAppear { consumeReveal(selection.revealTaskId, proxy: proxy) }
        }
    }

    @ViewBuilder
    private func allTasksGroupSection(
        _ group: AllTasksGroup,
        doneStates: Set<String>,
        factory: RowActionFactory
    ) -> some View {
        let isCollapsed = group.label.isEmpty ? false : collapsedGroups.contains(group.label)
        VStack(alignment: .leading, spacing: 6) {
            if !group.label.isEmpty {
                Button {
                    if collapsedGroups.contains(group.label) {
                        collapsedGroups.remove(group.label)
                    } else {
                        collapsedGroups.insert(group.label)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                        Text(group.label)
                            .font(.system(size: 11, weight: .semibold))
                            .tracking(0.6)
                            .textCase(.uppercase)
                            .foregroundStyle(Theme.textSecondary)
                        Text("\(group.items.count)")
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(Theme.textTertiary)
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
                .padding(.leading, 14)
                .padding(.bottom, 2)
            }
            if !isCollapsed {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(group.items) { item in
                        switch item {
                        case .task(let t):
                            let rowActions = factory.make(for: t)
                            if selection.taskId == t.id {
                                TaskExpandedCard(
                                    store: store,
                                    task: t,
                                    actions: rowActions,
                                    doneStates: doneStates
                                )
                                .id(item.id)
                            } else {
                                MacTaskRow(
                                    task: t,
                                    isClocked: factory.isClocked(t),
                                    isSelected: false,
                                    doneStates: doneStates,
                                    actions: rowActions,
                                    progress: factory.progress(for: t),
                                    keywords: store.keywords,
                                    priorities: store.priorities,
                                    onAppear: factory.prefetch(for: t)
                                )
                                .id(item.id)
                            }
                        case .habit(let h):
                            TodayHabitRow(habit: h, store: store, clocks: clocks)
                                .environment(settings)
                                .id(item.id)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Reveal / scroll

    private func consumeReveal(_ id: String?, proxy: ScrollViewProxy) {
        guard let id else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            proxy.scrollTo(id, anchor: .center)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            if selection.revealTaskId == id { selection.revealTaskId = nil }
        }
    }

    // MARK: - Loads

    private func load() async {
        guard let client = settings.apiClient else { return }
        await store.ensureInitialized(using: client, settings: settings)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await store.loadAllTasks(using: client, includeDone: self.includeDone) }
            group.addTask { await store.loadHabits(using: client) }
        }
    }

    private func loadIfNeeded() async {
        if store.allTasks.value == nil { await load() }
    }
}
