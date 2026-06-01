import Foundation
import Observation

enum LoadState<T> {
    case idle
    case loading
    case loaded(T)
    case failed(String)

    var value: T? {
        if case .loaded(let v) = self { return v }
        return nil
    }

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    var error: String? {
        if case .failed(let msg) = self { return msg }
        return nil
    }
}

@Observable
@MainActor
final class TasksStore {
    var today: LoadState<[AgendaEntry]> = .idle
    var upcoming: LoadState<[AgendaEntry]> = .idle
    var allTasks: LoadState<[OrgTask]> = .idle
    var habits: LoadState<[Habit]> = .idle
    var files: [AgendaFile] = []
    var keywords: TodoKeywords?
    var priorities: OrgPriorities?
    var listConfig: OrgListConfig?
    var clock: ClockStatus?

    /// The app's clock mirror, wired once at launch by RootView. Completing a
    /// task/habit closes its clock on the server; we also drop it from this
    /// local mirror right away so the dock stops ticking instantly instead of
    /// waiting on the `clock-changed` SSE echo. `@ObservationIgnored` because
    /// it's a wiring reference, not observable UI state.
    @ObservationIgnored weak var clockManager: ClockManager?

    /// Last server-side error from a mutation, if any. Surfaced by views.
    var lastMutationError: String?

    /// Non-destructive transient-error channel for *refreshes*. Set when a
    /// background refetch of an already-loaded slice fails (we keep the stale
    /// data rather than blanking the screen — stale-while-revalidate). Cleared
    /// on the next fully-successful refresh. Distinct from a slice's
    /// `LoadState.failed`, which is reserved for cold-load failure.
    private(set) var lastRefreshError: String?

    /// Live SSE connection state, fed by the owning view from EventSubscriber.
    /// Drives the "connecting / offline — showing last update" banner so the
    /// user knows the displayed data may be behind the server (e.g. right after
    /// the app wakes and before the reconnect+refresh completes).
    var connectionState: SSEConnectionState = .disconnected {
        didSet { if connectionState == .connected { sseEverConnected = true } }
    }

    /// True once the SSE stream has connected at least once this session. Used
    /// to gate the "reconnecting" banner so it doesn't flash on cold launch
    /// (before the first connect) or sit forever on the legacy Express backend,
    /// which has no `/api/events` endpoint to connect to.
    private(set) var sseEverConnected = false
    /// Debug: the most recent TODO state passed to org-todo via toggleDone.
    /// Helps surface what we sent when the round-trip silently returns ok.
    var lastToggledState: String?

    /// Notes cache keyed by "file::pos".
    var notesCache: [String: String] = [:] {
        didSet { notesCacheRevision &+= 1 }
    }
    /// Bumped on every `notesCache` mutation. Views can read this in their
    /// body so the Observation framework tracks the dependency reliably even
    /// when the cache lookup happens through a helper closure.
    var notesCacheRevision: UInt = 0

    var refileTargets: [RefileTarget] = []
    var refileTargetsLoaded = false

    var initialized = false

    private let upcomingDays = 14

    // MARK: - Loads

    func loadToday(using client: APIClient) async {
        if today.value == nil { today = .loading }
        do {
            let entries = try await client.fetchAgendaDay(DateQuery.today())
            today = .loaded(entries)
        } catch {
            recordLoadFailure(into: &today, error: error)
        }
    }

    func loadUpcoming(using client: APIClient) async {
        if upcoming.value == nil { upcoming = .loading }
        let start = DateQuery.offset(days: 1)
        let end = DateQuery.offset(days: upcomingDays)
        do {
            let entries = try await client.fetchAgendaRange(start: start, end: end)
            upcoming = .loaded(entries)
        } catch {
            recordLoadFailure(into: &upcoming, error: error)
        }
    }

    /// Stale-while-revalidate failure handling. If the slice already holds a
    /// loaded value, this was a *refresh* — keep the last-good value and only
    /// record `lastRefreshError`, so the UI shows stale data + a banner instead
    /// of blanking to a full-screen error. Only a cold load (no cached value)
    /// transitions to `.failed`.
    private func recordLoadFailure<T>(into slice: inout LoadState<T>, error: Error) {
        if slice.value != nil {
            lastRefreshError = error.message
        } else {
            slice = .failed(error.message)
        }
    }

    /// The `includeDone` setting most recently used to load `allTasks`.
    /// Stored so that automatic refreshes (post-mutation, SSE invalidations)
    /// preserve the caller's intent — without this, the Logbook view would
    /// load with `includeDone=true`, then any mutation would trigger a
    /// `refreshLoaded` with the default `false` and wipe the done tasks
    /// out from under the user.
    private(set) var allTasksIncludeDone: Bool = false

    /// Bumped after every successful `loadAllTasks` (and after mutation
    /// refreshes, since `refreshLoaded` calls it). External observers — e.g.
    /// `NotificationService` — `.task(id: store.allTasksRevision)` to
    /// re-sync whenever the task set changes.
    ///
    /// ## "Refresh on change" convention
    ///
    /// The codebase has three patterns for reacting to upstream changes. They
    /// are intentionally different and should not be collapsed into one:
    ///
    /// 1. `.task(id: store.allTasksRevision)` — SwiftUI view modifier used
    ///    when the reactor is an async function that should cancel-and-restart
    ///    cleanly on every change (e.g. iOS NotificationService sync). The
    ///    `id:` form is the idiomatic SwiftUI tool for this; do not replace it
    ///    with `.onChange` + unstructured Task when cancellation matters.
    ///
    /// 2. `.onChange(of: value) { _, new in Task { ... } }` — SwiftUI view
    ///    modifier used for fire-and-forget async reactions to non-store state
    ///    (e.g. ClockManager.sessions → LiveActivity sync). The value being
    ///    observed belongs to a different observable, not TasksStore, so
    ///    allTasksRevision cannot serve as the trigger.
    ///
    /// 3. `Task { @MainActor in ... }` inside EventSubscriber callbacks — the
    ///    only viable pattern for bridging a synchronous SSE callback to async
    ///    store methods. EventSubscriber is not a SwiftUI view; `.task` and
    ///    `.onChange` are unavailable. Do not add an `onInvalidate` closure
    ///    registry to TasksStore to "unify" this — it would entangle State/
    ///    with Networking/ and add lifecycle complexity for no gain.
    private(set) var allTasksRevision: Int = 0

    func loadAllTasks(using client: APIClient, includeDone: Bool = false) async {
        allTasksIncludeDone = includeDone
        if allTasks.value == nil { allTasks = .loading }
        do {
            let tasks = try await client.fetchTasks(includeAll: includeDone)
            allTasks = .loaded(tasks)
            allTasksRevision &+= 1
        } catch {
            recordLoadFailure(into: &allTasks, error: error)
        }
    }

    func loadHabits(using client: APIClient) async {
        if habits.value == nil { habits = .loading }
        do {
            let fetched = try await client.fetchHabits()
            habits = .loaded(fetched)
        } catch {
            recordLoadFailure(into: &habits, error: error)
        }
    }

    func loadMetadata(using client: APIClient, settings: AppSettings? = nil) async {
        async let filesResult = try? client.fetchFiles()
        async let keywordsResult = try? client.fetchKeywords()
        async let prioritiesResult = try? client.fetchPriorities()
        async let listConfigResult = try? client.fetchListConfig()
        async let clockResult = try? client.fetchClockStatus()
        self.files = (await filesResult) ?? []
        self.keywords = await keywordsResult
        self.priorities = await prioritiesResult
        self.listConfig = await listConfigResult
        self.clock = await clockResult
        if let settings, let kw = self.keywords,
           let pr = self.priorities {
            _ = settings.syncFromServer(keywords: kw, priorities: pr)
            initialized = true
        }
    }

    func ensureInitialized(using client: APIClient, settings: AppSettings) async {
        guard !initialized else { return }
        await loadMetadata(using: client, settings: settings)
    }

    func refreshClock(using client: APIClient) async {
        self.clock = try? await client.fetchClockStatus()
    }

    // Coalescing state for `refreshLoaded`. Two simultaneous callers (e.g.
    // a user mutation completing while an SSE-driven invalidation arrives)
    // would otherwise launch overlapping task groups: the earlier-fired
    // group can finish *after* the later-fired one and overwrite fresher
    // server state with staler data. Instead we serialize: at most one
    // refresh runs at a time, and a pending flag schedules exactly one
    // re-run if more requests arrive during it. Result: last-result-wins
    // is actually true in time order, and a burst of N events causes at
    // most 2 refreshes, not N.
    private var refreshInFlight = false
    private var refreshPending = false
    private var pendingIncludeDone = false

    /// Refresh whichever lists currently hold data. Called after mutations
    /// and on SSE `file-changed` / `task-changed` events.
    func refreshLoaded(using client: APIClient, includeDone: Bool = false) async {
        if refreshInFlight {
            refreshPending = true
            pendingIncludeDone = pendingIncludeDone || includeDone
            return
        }
        refreshInFlight = true
        var include = includeDone
        repeat {
            // Snapshot and clear the pending flags before awaiting so any
            // concurrent caller that sets them during runRefresh triggers
            // another iteration — and so the accumulated includeDone upgrade
            // is captured before pendingIncludeDone is zeroed.
            let nextInclude = pendingIncludeDone
            refreshPending = false
            pendingIncludeDone = false
            await runRefresh(using: client, includeDone: include)
            // Carry forward any includeDone=true upgrade that arrived while
            // runRefresh was awaiting. Never downgrade: once include is true
            // it stays true for the remaining iterations.
            include = include || nextInclude
        } while refreshPending
        refreshInFlight = false
    }

    private func runRefresh(using client: APIClient, includeDone: Bool) async {
        // Optimistically clear; any slice that fails this round re-sets it via
        // recordLoadFailure. Because the task group awaits all loads before we
        // resume, lastRefreshError is non-nil after this iff a refresh failed.
        lastRefreshError = nil
        await withTaskGroup(of: Void.self) { group in
            if today.value != nil {
                group.addTask { await self.loadToday(using: client) }
            }
            if upcoming.value != nil {
                group.addTask { await self.loadUpcoming(using: client) }
            }
            if allTasks.value != nil {
                // Preserve the existing include-done setting on refresh —
                // explicit `includeDone: true` from the caller upgrades but
                // never downgrades. The Logbook view sets the flag to true
                // on initial load; we must not silently drop done tasks
                // when an unrelated mutation triggers a refresh.
                let include = includeDone || self.allTasksIncludeDone
                group.addTask { await self.loadAllTasks(using: client, includeDone: include) }
            }
            if habits.value != nil {
                group.addTask { await self.loadHabits(using: client) }
            }
            group.addTask { await self.refreshClock(using: client) }
        }
        // Re-apply any still-in-flight optimistic patches on top of the freshly
        // loaded server data, so a refresh that fired (e.g. from an unrelated
        // SSE event) mid-mutation doesn't transiently revert the pending row.
        reapplyInflightPatches()
    }

    /// Re-apply each in-flight optimistic patch to the loaded slices, in the
    /// order they were issued. A patch is dropped from the list by
    /// `runMutation` once its write completes (so the authoritative server
    /// value then wins on the next refresh).
    private func reapplyInflightPatches() {
        guard !inflightPatches.isEmpty else { return }
        for patch in inflightPatches {
            if case .loaded(let entries) = today {
                today = .loaded(entries.map { $0.id == patch.id ? $0.patching(patch.field) : $0 })
            }
            if case .loaded(let entries) = upcoming {
                upcoming = .loaded(entries.map { $0.id == patch.id ? $0.patching(patch.field) : $0 })
            }
            if case .loaded(let tasks) = allTasks {
                allTasks = .loaded(tasks.map { $0.id == patch.id ? $0.patching(patch.field) : $0 })
            }
        }
    }

    // MARK: - Optimistic patch helpers

    /// Describes one field-level change to apply immediately to cached arrays.
    /// Sentinel strings use `@TODO`/`@DONE` conventions from the org bridge,
    /// but the optimistic layer never maps sentinels — it only stores the
    /// concrete display value the caller chose. Sentinels appear only in the
    /// wire request, not in the cache patch.
    enum OptimisticField {
        case todoState(String?)
        case priority(String?)
        case scheduled(OrgTimestamp?)
        case deadline(OrgTimestamp?)
        /// Key-value pair for the `properties` dict on OrgTask. Absent from
        /// AgendaEntry, so patching today/upcoming is a no-op for this case.
        case property(key: String, value: String)
    }

    /// Pre-image snapshots saved before an optimistic write, keyed by task id.
    /// Used for rollback when the network call fails.
    private struct PreImage {
        var todayEntries: [AgendaEntry]?
        var upcomingEntries: [AgendaEntry]?
        var allTasksList: [OrgTask]?
        /// Identifies the in-flight optimistic patch this image belongs to, so
        /// `runMutation` can drop it from `inflightPatches` on completion.
        var patchToken: UUID?
    }

    /// Optimistic patches whose network write hasn't completed yet. A refresh
    /// triggered by an UNRELATED SSE event while a mutation is in flight would
    /// otherwise reload server data that doesn't yet reflect the pending write,
    /// briefly reverting the row until the write's own refresh lands. We
    /// re-apply these on top of every refresh so the optimistic value survives
    /// until the real write is acknowledged. (concurrency #2: slow-mutation
    /// clobber.)
    private var inflightPatches: [(token: UUID, id: String, field: OptimisticField)] = []

    /// Apply `field` to every element matching `taskId` in the loaded arrays,
    /// returning a pre-image for rollback. The sentinel strings `@TODO`/`@DONE`
    /// are never passed here — callers resolve them (or leave them unresolved)
    /// before deciding which concrete field value to optimistically show. For
    /// `toggleDone` we use `nil` so the state clears instantly (correct for
    /// the toggle-off case; less precise for toggle-on, but the reconcile
    /// after the round-trip corrects it).
    private func applyOptimistic(taskId: String, _ field: OptimisticField) -> PreImage {
        let token = UUID()
        inflightPatches.append((token: token, id: taskId, field: field))
        let pre = PreImage(
            todayEntries: today.value,
            upcomingEntries: upcoming.value,
            allTasksList: allTasks.value,
            patchToken: token
        )
        if case .loaded(let entries) = today {
            today = .loaded(entries.map { e in
                guard e.id == taskId else { return e }
                return e.patching(field)
            })
        }
        if case .loaded(let entries) = upcoming {
            upcoming = .loaded(entries.map { e in
                guard e.id == taskId else { return e }
                return e.patching(field)
            })
        }
        if case .loaded(let tasks) = allTasks {
            allTasks = .loaded(tasks.map { t in
                guard t.id == taskId else { return t }
                return t.patching(field)
            })
        }
        return pre
    }

    private func rollback(_ pre: PreImage) {
        if let entries = pre.todayEntries { today = .loaded(entries) }
        if let entries = pre.upcomingEntries { upcoming = .loaded(entries) }
        if let tasks = pre.allTasksList { allTasks = .loaded(tasks) }
    }

    // MARK: - Mutations

    @discardableResult
    func toggleDone(_ task: any TaskDisplayable, file: String, pos: Int, using client: APIClient) async -> Bool {
        let isDone = isDoneState(task.todoState)
        // Use the bridge's `@DONE`/`@TODO` sentinels so org-todo advances
        // to *this task's own* done/todo state. Hand-picking a keyword
        // ("DONE") from the global allDone list fails silently when the
        // task lives in a sequence that uses a different done keyword
        // (e.g. a file-local `#+TODO: TODO | DELIVERED` header, or one of
        // several `org-todo-keywords` sequences that doesn't include
        // "DONE"). See `eav-set-todo-state` for the sentinel handling.
        let nextState = isDone ? "@TODO" : "@DONE"
        lastToggledState = nextState
        // Optimistically clear / set the done indicator so the row reacts
        // before the daemon round-trip. We can't know the resolved keyword
        // (the bridge picks it from the heading's own sequence), so we use
        // nil for "clear" (going to-do) and the first known done keyword for
        // "mark done". The reconcile after the round-trip always corrects it.
        let optimisticState: String? = isDone ? nil : (keywords?.allDone.first ?? "DONE")
        // setState handles unpinning on completion (shared by every completion
        // path); @TODO is not a completion so un-completing won't re-pin.
        return await setState(
            taskId: task.id, file: file, pos: pos, state: nextState,
            optimisticTodoState: optimisticState, using: client
        )
    }

    @discardableResult
    func setState(taskId: String, file: String, pos: Int, state: String, using client: APIClient) async -> Bool {
        await setState(taskId: taskId, file: file, pos: pos, state: state,
                       optimisticTodoState: state, using: client)
    }

    @discardableResult
    private func setState(taskId: String, file: String, pos: Int, state: String,
                          optimisticTodoState: String?, using client: APIClient) async -> Bool {
        // Capture pin status before the mutation: completing a task should
        // unpin it from My Day. A repeating task resets to TODO and keeps its
        // :PINNED: property, so we key off the *requested* state (a completion
        // intent) rather than the resolved post-repeat state.
        let wasPinnedToday = allTasks.value?.first { $0.id == taskId }
            .map(TaskFilters.isPinnedToday) ?? false
        let pre = applyOptimistic(taskId: taskId, .todoState(optimisticTodoState))
        let ok = await runMutation(client: client, preImage: pre) {
            try await client.setState(taskId: taskId, file: file, pos: pos, state: state)
        }
        // Any completion path (checkbox/swipe via "@DONE", or an explicit done
        // keyword from the state picker) unpins. Moving to a non-done state or
        // clearing the state does not re-pin.
        if ok, state == "@DONE" || isDoneState(state) {
            if wasPinnedToday {
                _ = await setProperty(
                    taskId: taskId, file: file, pos: pos,
                    key: "PINNED", value: "", using: client
                )
            }
            // The server (patch_state) closes a running clock when the heading
            // becomes done; drop it from the local mirror so the dock stops
            // ticking without waiting on the clock-changed SSE.
            clockManager?.dropLocalClock(taskId: taskId)
        }
        return ok
    }

    @discardableResult
    func setPriority(taskId: String, file: String, pos: Int, priority: String, using client: APIClient) async -> Bool {
        let pre = applyOptimistic(taskId: taskId, .priority(priority.isEmpty ? nil : priority))
        return await runMutation(client: client, preImage: pre) {
            try await client.setPriority(taskId: taskId, file: file, pos: pos, priority: priority)
        }
    }

    @discardableResult
    func setTitle(taskId: String, file: String, pos: Int, title: String, using client: APIClient) async -> Bool {
        await runMutation(client: client) {
            try await client.setTitle(taskId: taskId, file: file, pos: pos, title: title)
        }
    }

    @discardableResult
    func setTags(taskId: String, file: String, pos: Int, tags: [String], using client: APIClient) async -> Bool {
        await runMutation(client: client) {
            try await client.setTags(taskId: taskId, file: file, pos: pos, tags: tags)
        }
    }

    func tidyClocks(file: String, pos: Int, using client: APIClient) async {
        do {
            try await client.tidyClocks(file: file, pos: pos)
            // Invalidate the cached notes so the rendered/raw views show the
            // freshly-folded LOGBOOK drawer.
            notesCache.removeValue(forKey: "\(file)::\(pos)")
            await refreshLoaded(using: client)
        } catch {
            // Silent fail; the user can retry.
        }
    }

    @discardableResult
    func setScheduled(taskId: String, file: String, pos: Int, timestamp: String, using client: APIClient) async -> Bool {
        let parsed = OrgTimestamp.parseDateString(timestamp).flatMap { _ in
            // Build a minimal OrgTimestamp from the raw string so the row
            // shows the new date immediately. Full parse happens on reconcile.
            OrgTimestamp(rawString: timestamp)
        }
        let pre = applyOptimistic(taskId: taskId, .scheduled(parsed))
        return await runMutation(client: client, preImage: pre) {
            try await client.setScheduled(taskId: taskId, file: file, pos: pos, timestamp: timestamp)
        }
    }

    @discardableResult
    func setDeadline(taskId: String, file: String, pos: Int, timestamp: String, using client: APIClient) async -> Bool {
        let parsed = OrgTimestamp.parseDateString(timestamp).flatMap { _ in
            OrgTimestamp(rawString: timestamp)
        }
        let pre = applyOptimistic(taskId: taskId, .deadline(parsed))
        return await runMutation(client: client, preImage: pre) {
            try await client.setDeadline(taskId: taskId, file: file, pos: pos, timestamp: timestamp)
        }
    }

    @discardableResult
    func setProperty(taskId: String, file: String, pos: Int, key: String, value: String, using client: APIClient) async -> Bool {
        let pre = applyOptimistic(taskId: taskId, .property(key: key, value: value))
        return await runMutation(client: client, preImage: pre) {
            try await client.setProperty(taskId: taskId, file: file, pos: pos, key: key, value: value)
        }
    }

    @discardableResult
    func loadRefileTargets(using client: APIClient) async -> Bool {
        lastMutationError = nil
        do {
            refileTargets = try await client.fetchRefileTargets()
            refileTargetsLoaded = true
            return true
        } catch {
            lastMutationError = error.message
            // Flip the loaded flag even on failure so the view can leave
            // its "loading…" state and surface an error UI. Otherwise a
            // bridge 5xx leaves the RefileSheet spinning forever.
            refileTargetsLoaded = true
            return false
        }
    }

    @discardableResult
    func refile(sourceFile: String, sourcePos: Int, target: RefileTarget, using client: APIClient) async -> Bool {
        await runMutation(client: client) {
            try await client.refileTask(sourceFile: sourceFile, sourcePos: sourcePos,
                                        targetFile: target.file, targetPos: target.pos)
        }
    }

    /// Move the heading out of the agenda files via `org-archive-subtree`.
    /// Destructive in practice — the archive file isn't indexed by eavd, so
    /// the task disappears from every view. Reversal requires opening the
    /// `.org_archive` file in Emacs and refiling back. UI gates this action
    /// to the Logbook view for that reason.
    @discardableResult
    func archive(_ task: any TaskDisplayable, using client: APIClient) async -> Bool {
        await runMutation(client: client) {
            try await client.archiveTask(id: task.id, file: task.file, pos: task.pos)
        }
    }

    func loadNotes(file: String, pos: Int, using client: APIClient) async -> String {
        let key = "\(file)::\(pos)"
        if let cached = notesCache[key] { return cached }
        do {
            let notes = try await client.fetchNotes(file: file, pos: pos)
            notesCache[key] = notes
            return notes
        } catch {
            return ""
        }
    }

    /// Synchronous lookup for cached notes — used by views that want to render
    /// at-a-glance progress without triggering a network round-trip per row.
    func cachedNotes(file: String, pos: Int) -> String? {
        notesCache["\(file)::\(pos)"]
    }

    /// Maximum number of concurrent prefetch tasks. Caps server load when a
    /// large list renders many rows at once (e.g. scrolling a 500-row view).
    private static let prefetchConcurrencyLimit = 8

    /// In-flight prefetch tasks keyed by "file::pos". Cancelling via this map
    /// before inserting a new task prevents stale completions from overwriting
    /// newer cached values, and bounds memory when tasks are recycled quickly.
    private var notesInFlight: [String: Task<Void, Never>] = [:]

    /// Background refresh for a task's notes. Skips if the notes are already
    /// cached. Cancels any existing in-flight request for the same key before
    /// starting a new one. Bounded to `prefetchConcurrencyLimit` concurrent
    /// fetches so that scrolling a large list doesn't saturate the server.
    func prefetchNotes(file: String, pos: Int, using client: APIClient) {
        let key = "\(file)::\(pos)"
        // Skip when the cache is already warm — callers that want a forced
        // refresh should use loadNotes(file:pos:using:) directly.
        if notesCache[key] != nil { return }
        // Cancel any stale in-flight request so only the latest wins.
        notesInFlight[key]?.cancel()
        // Enforce total concurrency bound. Count active (non-cancelled) tasks.
        if notesInFlight.values.filter({ !$0.isCancelled }).count >= Self.prefetchConcurrencyLimit {
            return
        }
        notesInFlight[key] = Task { [weak self] in
            do {
                let notes = try await client.fetchNotes(file: file, pos: pos)
                await MainActor.run {
                    guard let self else { return }
                    self.notesCache[key] = notes
                    self.notesInFlight.removeValue(forKey: key)
                }
            } catch {
                _ = await MainActor.run { self?.notesInFlight.removeValue(forKey: key) }
            }
        }
    }

    @discardableResult
    func setNotes(file: String, pos: Int, notes: String, using client: APIClient) async -> Bool {
        let key = "\(file)::\(pos)"
        lastMutationError = nil
        do {
            let final = try await client.setNotes(file: file, pos: pos, notes: notes)
            notesCache[key] = final
            await refreshLoaded(using: client)
            return true
        } catch {
            lastMutationError = error.message
            return false
        }
    }

    // MARK: - Helpers

    func isDoneState(_ state: String?) -> Bool {
        guard let state else { return false }
        let upper = state.uppercased()
        return (keywords?.allDone ?? []).contains(where: { $0.uppercased() == upper })
    }

    /// Run a mutation closure, refreshing loaded data on success. Returns
    /// `true` if the mutation succeeded. Always clears `lastMutationError`
    /// on entry so callers reading it after this call see ONLY this
    /// mutation's outcome — without this, a stale error from an earlier
    /// failed mutation would block dismissal of a successful sheet.
    ///
    /// When `preImage` is supplied the arrays were already patched
    /// optimistically; on failure the pre-image is restored before surfacing
    /// the error so the UI snaps back atomically.
    @discardableResult
    private func runMutation(client: APIClient,
                             preImage: PreImage? = nil,
                             _ op: () async throws -> Void) async -> Bool {
        lastMutationError = nil
        do {
            try await op()
            // Drop this mutation's in-flight patch BEFORE its own refresh so the
            // authoritative server value wins for this task (other tasks' patches
            // stay until their own writes land).
            if let token = preImage?.patchToken {
                inflightPatches.removeAll { $0.token == token }
            }
            await refreshLoaded(using: client)
            return true
        } catch {
            if let pre = preImage { rollback(pre) }
            if let token = preImage?.patchToken {
                inflightPatches.removeAll { $0.token == token }
            }
            lastMutationError = error.message
            return false
        }
    }

    // MARK: - Habit mutations (optimistic)
    //
    // Habits render as task-style rows but used to wait two round-trips
    // (`try? await … ; invalidateHabits`) with no local echo and swallowed
    // errors — so every tick felt laggy and a failed tick was invisible.
    // These mirror the task `applyOptimistic`/`runMutation` pattern: patch the
    // `habits` slice immediately, run the op (which returns the authoritative
    // `Habit`), reconcile with the server copy, and on failure roll back and
    // surface the error via `lastMutationError` (the RootView banner). The
    // mixed Today/All-Tasks rows derive from the same `habits` slice, so the
    // patch flows there too without a full `refreshLoaded`.

    /// org-style completion stamp, e.g. `2026-05-31 Sun 14:32`. Matches the
    /// daemon's `%Y-%m-%d %a %H:%M` so optimistic and server completions agree.
    private static let orgStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd EEE HH:mm"
        return f
    }()

    private static let dayStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Apply `transform` to every habit matching `id`, returning the prior list
    /// for rollback (nil when the slice isn't loaded yet).
    @discardableResult
    private func patchHabit(id: String, _ transform: (Habit) -> Habit) -> [Habit]? {
        guard case .loaded(var list) = habits else { return nil }
        let pre = list
        var changed = false
        for i in list.indices where list[i].id == id {
            list[i] = transform(list[i]); changed = true
        }
        if changed { habits = .loaded(list) }
        return pre
    }

    private func reconcileHabit(_ updated: Habit) {
        guard case .loaded(var list) = habits else { return }
        if let idx = list.firstIndex(where: { $0.id == updated.id }) {
            list[idx] = updated
        } else {
            list.append(updated)
        }
        habits = .loaded(list)
    }

    private func restoreHabits(_ pre: [Habit]?) {
        if let pre { habits = .loaded(pre) }
    }

    /// Record a completion. Optimistically marks the habit settled (`state`
    /// ok + a completion stamped now) so it drops out of Today immediately;
    /// resets the checklist locally when the habit opts in, matching the
    /// server. Reconciles with the server's recomputed `nextDue`/`state`.
    @discardableResult
    func completeHabit(_ habit: Habit, using client: APIClient) async -> Bool {
        lastMutationError = nil
        let stamp = Self.orgStampFormatter.string(from: Date())
        let pre = patchHabit(id: habit.id) { h in
            var comps = h.completions
            comps.insert(stamp, at: 0)   // daemon serves completions newest-first
            let notes: String?? = h.resetChecklistOnComplete
                ? .some(h.notes.map { OrgChecklist.resetAll($0) })
                : .none
            return h.copy(state: "ok", completions: comps, notes: notes)
        }
        do {
            reconcileHabit(try await client.completeHabit(id: habit.id, ts: stamp))
            // The server closed any running clock for this habit as part of
            // /complete; mirror that locally so the dock stops immediately.
            clockManager?.dropLocalClock(taskId: habit.id)
            return true
        } catch {
            restoreHabits(pre); lastMutationError = error.message; return false
        }
    }

    /// Undo the most recent completion (the newest stamp the daemon sent).
    @discardableResult
    func uncompleteHabit(_ habit: Habit, using client: APIClient) async -> Bool {
        guard let ts = habit.completions.first else { return false }
        lastMutationError = nil
        let pre = patchHabit(id: habit.id) { h in
            var comps = h.completions
            if !comps.isEmpty { comps.removeFirst() }
            return h.copy(state: "due", completions: comps)
        }
        do {
            reconcileHabit(try await client.uncompleteHabit(id: habit.id, ts: ts))
            return true
        } catch {
            restoreHabits(pre); lastMutationError = error.message; return false
        }
    }

    /// Skip the current period (advance next-due, no credit).
    @discardableResult
    func skipHabit(_ habit: Habit, using client: APIClient) async -> Bool {
        lastMutationError = nil
        let pre = patchHabit(id: habit.id) { $0.copy(state: "ok") }
        do {
            reconcileHabit(try await client.skipHabit(id: habit.id))
            return true
        } catch {
            restoreHabits(pre); lastMutationError = error.message; return false
        }
    }

    /// Set the habit's next-due date explicitly.
    @discardableResult
    func rescheduleHabit(_ habit: Habit, to date: String, using client: APIClient) async -> Bool {
        lastMutationError = nil
        let today = Self.dayStampFormatter.string(from: Date())
        let pre = patchHabit(id: habit.id) { $0.copy(state: date > today ? "ok" : "due", nextDue: date) }
        do {
            reconcileHabit(try await client.rescheduleHabit(id: habit.id, date: date))
            return true
        } catch {
            restoreHabits(pre); lastMutationError = error.message; return false
        }
    }

    /// Persist edited notes (e.g. a checklist toggle from a habit row).
    @discardableResult
    func setHabitNotes(_ habit: Habit, notes: String, using client: APIClient) async -> Bool {
        lastMutationError = nil
        let pre = patchHabit(id: habit.id) { $0.copy(notes: .some(notes)) }
        do {
            reconcileHabit(try await client.updateHabit(id: habit.id, notes: notes))
            return true
        } catch {
            restoreHabits(pre); lastMutationError = error.message; return false
        }
    }

    /// Set (or clear, with nil) a habit's priority inline. The daemon clears
    /// only on an explicit JSON null, so `clearsPriority` drives that request.
    @discardableResult
    func setHabitPriority(_ habit: Habit, priority: String?, using client: APIClient) async -> Bool {
        lastMutationError = nil
        let pre = patchHabit(id: habit.id) { $0.copy(priority: .some(priority)) }
        do {
            reconcileHabit(try await client.updateHabit(
                id: habit.id, priority: priority, clearsPriority: priority == nil))
            return true
        } catch {
            restoreHabits(pre); lastMutationError = error.message; return false
        }
    }

    /// Delete a habit, removing it from the slice immediately.
    @discardableResult
    func deleteHabit(_ habit: Habit, using client: APIClient) async -> Bool {
        lastMutationError = nil
        let pre: [Habit]? = habits.value
        if case .loaded(var list) = habits {
            list.removeAll { $0.id == habit.id }
            habits = .loaded(list)
        }
        do {
            try await client.deleteHabit(id: habit.id)
            return true
        } catch {
            restoreHabits(pre); lastMutationError = error.message; return false
        }
    }

    // MARK: - Daemon-driven invalidation
    //
    // The daemon's SSE channel pushes fine-grained events; these helpers map
    // each event to the smallest refresh that keeps the view consistent.

    /// Refresh just the cached list slices that contain tasks from FILE.
    /// Drops the corresponding notes-cache entries so opening a task after
    /// an external edit doesn't show a stale body.
    func invalidate(file: String, using client: APIClient) async {
        let prefix = "\(file)::"
        notesCache.keys
            .filter { $0.hasPrefix(prefix) }
            .forEach { notesCache.removeValue(forKey: $0) }
        await refreshLoaded(using: client)
    }

    /// Refresh just the data backing TASKID. For now this falls through to
    /// `invalidate(file:)` because every list slice we maintain contains
    /// the task; once we have per-id storage we'll narrow the refresh.
    func invalidate(taskId: String, file: String, pos: Int, using client: APIClient) async {
        notesCache.removeValue(forKey: "\(file)::\(pos)")
        _ = taskId
        await refreshLoaded(using: client)
    }

    /// Reload the habits slice. Triggered by `habits-changed` SSE events.
    func invalidateHabits(using client: APIClient) async {
        await loadHabits(using: client)
    }

    /// Reload metadata (files, keywords, priorities). Triggered by
    /// `config-changed` events from the daemon.
    func invalidateConfig(using client: APIClient, settings: AppSettings) async {
        initialized = false
        await loadMetadata(using: client, settings: settings)
    }
}

private extension Error {
    var message: String {
        (self as? LocalizedError)?.errorDescription ?? localizedDescription
    }
}

private extension Habit {
    /// Returns a copy with selected fields overridden, for optimistic patches.
    /// `state` / `nextDue` / `completions` / `active` follow "nil = keep".
    /// `priority` and `notes` are double optionals so a caller can distinguish
    /// keep (`.none`) from clear-to-nil (`.some(nil)`).
    func copy(
        state: String? = nil,
        nextDue: String? = nil,
        completions: [String]? = nil,
        priority: String?? = .none,
        notes: String?? = .none,
        active: Bool? = nil
    ) -> Habit {
        let newPriority: String?
        if case .some(let p) = priority { newPriority = p } else { newPriority = self.priority }
        let newNotes: String?
        if case .some(let n) = notes { newNotes = n } else { newNotes = self.notes }
        return Habit(
            id: id,
            title: title,
            cadence: cadence,
            category: category,
            priority: newPriority,
            tags: tags,
            notes: newNotes,
            anchorDate: anchorDate,
            active: active ?? self.active,
            resetChecklistOnComplete: resetChecklistOnComplete,
            completions: completions ?? self.completions,
            nextDue: nextDue ?? self.nextDue,
            state: state ?? self.state
        )
    }
}
