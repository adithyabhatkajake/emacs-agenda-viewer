import SwiftUI

/// Logbook view: completed and killed tasks (any keyword in
/// `keywords.allDone`), grouped by their CLOSED timestamp. Mirrors
/// Things 3's logbook — a place to look back at what got done and to
/// retire entries you no longer care to keep around via
/// `org-archive-subtree`.
///
/// Archive is exposed ONLY here (not in Inbox / Today / Upcoming / All
/// Tasks): it moves the heading to `<file>.org_archive`, which is not
/// indexed by eavd, so the task disappears everywhere. Reversal means
/// opening the archive file in Emacs and refiling back — destructive
/// enough that it deserves a confirmation dialog and a single,
/// intentional surface.
struct MacLogbookView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(Selection.self) private var selection
    @Environment(ClockManager.self) private var clocks
    @Environment(CalendarSync.self) private var sync
    let store: TasksStore

    @State private var searchText = ""
    @State private var collapsedGroups: Set<String> = []
    @State private var pendingArchive: TaskSnapshot?
    @State private var archiveError: String?

    var body: some View {
        content
            .navigationTitle("Logbook")
            .searchable(text: $searchText, placement: .toolbar, prompt: "Search logbook")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    ReloadButton(action: { Task { await load() } }, disabled: !settings.isConfigured)
                }
            }
            .task(id: settings.serverURLString) { await loadIfNeeded() }
            .confirmationDialog(
                pendingArchive.map { "Archive \"\($0.title)\"?" } ?? "Archive task?",
                isPresented: Binding(
                    get: { pendingArchive != nil },
                    set: { if !$0 { pendingArchive = nil } }
                ),
                presenting: pendingArchive
            ) { task in
                Button("Archive", role: .destructive) {
                    archive(task)
                }
                Button("Cancel", role: .cancel) {}
            } message: { task in
                let name = (task.file as NSString).lastPathComponent
                Text("This runs org-archive-subtree on the heading, moving it out of "
                     + "\(name) into the configured archive location. "
                     + "It will stop appearing in every view and reversing requires editing in Emacs.")
            }
            .alert("Archive failed", isPresented: Binding(
                get: { archiveError != nil },
                set: { if !$0 { archiveError = nil } }
            ), presenting: archiveError) { _ in
                Button("OK", role: .cancel) {}
            } message: { msg in
                Text(msg)
            }
    }

    @ViewBuilder
    private var content: some View {
        if !settings.isConfigured {
            UnconfiguredStateView()
        } else if let tasks = store.allTasks.value {
            let filtered = filter(tasks)
            if filtered.isEmpty {
                EmptyStateView(
                    title: searchText.isEmpty ? "Nothing logged yet" : "No matches",
                    systemImage: searchText.isEmpty ? "book.closed.fill" : "magnifyingglass"
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

    /// Logbook shows ONLY done-state tasks (DONE, KILL, CANCELLED, …
    /// whatever the user's `org-todo-keywords` flags as done). When the
    /// store hasn't loaded keywords yet we fall back to a safe pair so
    /// the view isn't empty on first paint.
    private func filter(_ tasks: [OrgTask]) -> [OrgTask] {
        let done: Set<String> = {
            let configured = store.keywords?.allDone ?? []
            if configured.isEmpty { return ["DONE", "KILL"] }
            return Set(configured.map { $0.uppercased() })
        }()
        let doneOnly = tasks.filter { task in
            guard let s = task.todoState?.uppercased() else { return false }
            return done.contains(s)
        }
        guard !searchText.isEmpty else { return doneOnly }
        let needle = searchText.lowercased()
        return doneOnly.filter { task in
            task.title.lowercased().contains(needle)
                || task.tags.contains(where: { $0.lowercased().contains(needle) })
                || task.category.lowercased().contains(needle)
        }
    }

    private func list(_ tasks: [OrgTask]) -> some View {
        let doneStates = Set((store.keywords?.allDone ?? []).map { $0.uppercased() })
        var factory = RowActionFactory(
            store: store, settings: settings, selection: selection, clocks: clocks, sync: sync
        )
        factory.onRequestArchive = { snapshot in
            pendingArchive = snapshot
        }
        let eisCtx = EisenhowerGroupContext(urgencyDays: settings.eisenhowerUrgencyDays, priorities: store.priorities)
        let groups = groupTasksByClosedDate(tasks)
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

    private func archive(_ task: TaskSnapshot) {
        Task {
            guard let client = settings.apiClient else { return }
            // The daemon's file watcher picks up both the source-file write
            // (heading removed) and the archive-file write; SSE invalidations
            // refresh the list automatically. `runMutation` also runs a
            // belt-and-suspenders refresh on success.
            let ok = await store.archive(task, using: client)
            if !ok {
                // Surface the failure visibly. Without this the user sees
                // nothing happen (the row stays put because the daemon
                // never wrote the change). `lastMutationError` carries
                // whatever the daemon returned — usually an elisp message
                // from the bridge.
                archiveError = store.lastMutationError ?? "Unknown error from daemon"
            }
        }
    }

    private func load() async {
        // Logbook must see done states — force includeDone=true on every load.
        // Won't touch the per-view toggle in MacAllTasksView; that view has
        // its own `includeDone` @State.
        guard let client = settings.apiClient else { return }
        await store.ensureInitialized(using: client, settings: settings)
        await store.loadAllTasks(using: client, includeDone: true)
    }

    private func loadIfNeeded() async {
        // Even if allTasks is loaded, it may have been loaded with
        // includeDone=false and therefore omit logbook content. Detect
        // that by checking whether the cached list contains any done
        // states; reload with includeDone=true otherwise.
        let alreadyHasDone = store.allTasks.value?.contains(where: { store.isDoneState($0.todoState) }) ?? false
        if store.allTasks.value == nil || !alreadyHasDone {
            await load()
        }
    }
}
