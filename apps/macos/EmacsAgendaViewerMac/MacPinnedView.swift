import SwiftUI

/// Pinned ("My Day") view: tasks the user has explicitly pinned for today.
/// A task appears here iff its :PINNED: property equals today's date string
/// (YYYY-MM-DD). Yesterday's pins silently disappear at midnight because the
/// comparison is strict equality against today's date.
struct MacPinnedView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(Selection.self) private var selection
    @Environment(ClockManager.self) private var clocks
    @Environment(CalendarSync.self) private var sync
    let store: TasksStore

    @State private var searchText = ""
    @State private var collapsedGroups: Set<String> = []

    private var todayString: String { DateQuery.today() }

    var body: some View {
        content
            .navigationTitle("Pinned")
            .searchable(text: $searchText, placement: .toolbar, prompt: "Search pinned")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    ReloadButton(action: { Task { await load() } }, disabled: !settings.isConfigured)
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
                EmptyStateView(
                    title: searchText.isEmpty
                        ? "Nothing pinned for today. Pin a task with \u{2318}\u{21E7}P or right-click \u{2192} Pin to My Day."
                        : "No matches",
                    systemImage: searchText.isEmpty ? "pin.slash" : "magnifyingglass"
                )
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
        let today = todayString
        let pinned = tasks.filter { $0.properties?["PINNED"] == today }
        guard !searchText.isEmpty else { return sortTasks(pinned, by: settings.listSort) }
        let needle = searchText.lowercased()
        let matched = pinned.filter {
            $0.title.lowercased().contains(needle)
                || $0.tags.contains(where: { $0.lowercased().contains(needle) })
        }
        return sortTasks(matched, by: settings.listSort)
    }

    private static let dayHeadFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMM d"
        return f
    }()

    @ViewBuilder
    private func pinnedHead(taskCount: Int) -> some View {
        let dayLabel = MacPinnedView.dayHeadFormatter.string(from: Date())
        VStack(alignment: .leading, spacing: 4) {
            Text("PINNED")
                .font(.system(size: 11, weight: .heavy))
                .tracking(0.6)
                .foregroundStyle(Theme.accent)
            HStack(alignment: .lastTextBaseline, spacing: 12) {
                Text(dayLabel)
                    .font(.system(size: 22, weight: .bold))
                    .tracking(-0.4)
                    .foregroundStyle(Theme.textPrimary)
                Text("\(taskCount) pinned task\(taskCount == 1 ? "" : "s")")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 4)
    }

    private func list(_ tasks: [OrgTask]) -> some View {
        let doneStates = Set((store.keywords?.allDone ?? []).map { $0.uppercased() })
        let factory = RowActionFactory(store: store, settings: settings, selection: selection, clocks: clocks, sync: sync)
        let eisCtx = EisenhowerGroupContext(urgencyDays: settings.eisenhowerUrgencyDays, priorities: store.priorities)
        let groups: [TaskGroup<OrgTask>] = [TaskGroup(id: "_pinned", label: "", items: tasks)]
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    pinnedHead(taskCount: tasks.count)
                    GroupedTaskList(
                        groups: groups,
                        secondaryKey: .none,
                        eisenhower: eisCtx,
                        doneStates: doneStates,
                        factory: factory,
                        selection: selection,
                        store: store,
                        collapsed: $collapsedGroups
                    )
                }
                .padding(.horizontal, 32)
                .padding(.top, 22)
                .padding(.bottom, 40)
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

    private func load() async {
        guard let client = settings.apiClient else { return }
        await store.ensureInitialized(using: client, settings: settings)
        await store.loadAllTasks(using: client, includeDone: false)
    }

    private func loadIfNeeded() async {
        if store.allTasks.value == nil { await load() }
    }
}
