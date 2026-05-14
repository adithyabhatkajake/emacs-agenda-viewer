import SwiftUI

/// Triage view: active tasks captured into the Inbox category, waiting to be
/// refiled into their permanent homes. Mirrors the org-capture-then-refile
/// workflow — `org-capture` lands new headings in the Inbox file, and this
/// view is where you sweep them out into project trees.
///
/// Keyboard flow:
///   1. Click a row to select it (or use ↑/↓).
///   2. ⇧⌘R (or the toolbar Refile button) opens the refile sheet.
///   3. Fuzzy-search the target, hit Enter — the task disappears from the
///      list as soon as the daemon's SSE invalidation fires.
struct MacInboxView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(Selection.self) private var selection
    @Environment(ClockManager.self) private var clocks
    @Environment(CalendarSync.self) private var sync
    let store: TasksStore

    @State private var searchText = ""
    @State private var collapsedGroups: Set<String> = []

    var body: some View {
        content
            .navigationTitle("Inbox")
            .searchable(text: $searchText, placement: .toolbar, prompt: "Search inbox")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        refileSelected()
                    } label: {
                        Label("Refile", systemImage: "tray.and.arrow.up")
                    }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .help("Refile selected task (⇧⌘R)")
                    .disabled(selection.taskId == nil)
                }
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
                    title: searchText.isEmpty ? "Inbox is clear" : "No matches",
                    systemImage: searchText.isEmpty ? "checkmark.circle.fill" : "magnifyingglass"
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

    /// Tasks shown here:
    ///   - category equals "Inbox" (case-insensitive — matches the default
    ///     org-capture target convention without forcing the user to pin a
    ///     specific category string in settings)
    ///   - todo_state is active (filtering done states out keeps the list
    ///     focused on triage; completed captures live in All Tasks)
    private func filter(_ tasks: [OrgTask]) -> [OrgTask] {
        let inboxOnly = tasks.filter { task in
            task.category.caseInsensitiveCompare("Inbox") == .orderedSame
                && !store.isDoneState(task.todoState)
        }
        let filtered: [OrgTask]
        if searchText.isEmpty {
            filtered = inboxOnly
        } else {
            let needle = searchText.lowercased()
            filtered = inboxOnly.filter { task in
                task.title.lowercased().contains(needle)
                    || task.tags.contains(where: { $0.lowercased().contains(needle) })
            }
        }
        return sortTasks(filtered, by: settings.listSort)
    }

    private func list(_ tasks: [OrgTask]) -> some View {
        let doneStates = Set((store.keywords?.allDone ?? []).map { $0.uppercased() })
        let factory = RowActionFactory(store: store, settings: settings, selection: selection, clocks: clocks, sync: sync)
        let eisCtx = EisenhowerGroupContext(urgencyDays: settings.eisenhowerUrgencyDays, priorities: store.priorities)
        // Inbox is small by definition — render as a single ungrouped section
        // so the user sees every entry at once without collapsible noise.
        let groups: [TaskGroup<OrgTask>] = [TaskGroup(id: "_inbox", label: "", items: tasks)]
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
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

    /// Open the refile sheet for whichever task is currently selected. Hands
    /// off to the same RefileSheet driven by `Selection.refileTask`, so the
    /// rest of the refile machinery (target loading, fuzzy search, keyboard
    /// nav, error handling) is reused.
    private func refileSelected() {
        guard let id = selection.taskId,
              let task = store.allTasks.value?.first(where: { $0.id == id })
        else { return }
        selection.refileTask = task
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
