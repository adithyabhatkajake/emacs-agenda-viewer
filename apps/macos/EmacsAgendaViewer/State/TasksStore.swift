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
    var files: [AgendaFile] = []
    var keywords: TodoKeywords?
    var priorities: OrgPriorities?
    var listConfig: OrgListConfig?
    var clock: ClockStatus?

    /// Last server-side error from a mutation, if any. Surfaced by views.
    var lastMutationError: String?

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
            today = .failed(error.message)
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
            upcoming = .failed(error.message)
        }
    }

    /// The `includeDone` setting most recently used to load `allTasks`.
    /// Stored so that automatic refreshes (post-mutation, SSE invalidations)
    /// preserve the caller's intent — without this, the Logbook view would
    /// load with `includeDone=true`, then any mutation would trigger a
    /// `refreshLoaded` with the default `false` and wipe the done tasks
    /// out from under the user.
    private(set) var allTasksIncludeDone: Bool = false

    func loadAllTasks(using client: APIClient, includeDone: Bool = false) async {
        allTasksIncludeDone = includeDone
        if allTasks.value == nil { allTasks = .loading }
        do {
            let tasks = try await client.fetchTasks(includeAll: includeDone)
            allTasks = .loaded(tasks)
        } catch {
            allTasks = .failed(error.message)
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
            refreshPending = false
            pendingIncludeDone = false
            await runRefresh(using: client, includeDone: include)
            include = pendingIncludeDone
        } while refreshPending
        refreshInFlight = false
    }

    private func runRefresh(using client: APIClient, includeDone: Bool) async {
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
            group.addTask { await self.refreshClock(using: client) }
        }
    }

    // MARK: - Mutations

    @discardableResult
    func toggleDone(_ task: any TaskDisplayable, file: String, pos: Int, using client: APIClient) async -> Bool {
        let isDone = isDoneState(task.todoState)
        let nextState: String
        if isDone {
            // Toggle from done back to first active state, fallback "TODO"
            nextState = keywords?.allActive.first ?? "TODO"
        } else {
            nextState = keywords?.allDone.first ?? "DONE"
        }
        return await setState(taskId: task.id, file: file, pos: pos, state: nextState, using: client)
    }

    @discardableResult
    func setState(taskId: String, file: String, pos: Int, state: String, using client: APIClient) async -> Bool {
        await runMutation(client: client) {
            try await client.setState(taskId: taskId, file: file, pos: pos, state: state)
        }
    }

    @discardableResult
    func setPriority(taskId: String, file: String, pos: Int, priority: String, using client: APIClient) async -> Bool {
        await runMutation(client: client) {
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
        await runMutation(client: client) {
            try await client.setScheduled(taskId: taskId, file: file, pos: pos, timestamp: timestamp)
        }
    }

    @discardableResult
    func setDeadline(taskId: String, file: String, pos: Int, timestamp: String, using client: APIClient) async -> Bool {
        await runMutation(client: client) {
            try await client.setDeadline(taskId: taskId, file: file, pos: pos, timestamp: timestamp)
        }
    }

    @discardableResult
    func setProperty(taskId: String, file: String, pos: Int, key: String, value: String, using client: APIClient) async -> Bool {
        await runMutation(client: client) {
            try await client.setProperty(taskId: taskId, file: file, pos: pos, key: key, value: value)
        }
    }

    @discardableResult
    func clockIn(file: String, pos: Int, using client: APIClient) async -> Bool {
        await runMutation(client: client) {
            try await client.clockIn(file: file, pos: pos)
        }
    }

    @discardableResult
    func clockOut(using client: APIClient) async -> Bool {
        await runMutation(client: client) {
            try await client.clockOut()
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

    /// Background refresh for a task's notes. Always re-fetches so that views
    /// reflect the live state even when the cache is stale (e.g., after an
    /// out-of-band edit in Emacs). De-dupes overlapping requests via an
    /// in-flight set so scrolling doesn't spam the server.
    private var notesInFlight: Set<String> = []
    func prefetchNotes(file: String, pos: Int, using client: APIClient) {
        let key = "\(file)::\(pos)"
        if notesInFlight.contains(key) { return }
        notesInFlight.insert(key)
        Task { [weak self] in
            do {
                let notes = try await client.fetchNotes(file: file, pos: pos)
                await MainActor.run {
                    self?.notesCache[key] = notes
                    self?.notesInFlight.remove(key)
                }
            } catch {
                await MainActor.run { self?.notesInFlight.remove(key) }
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
    private func runMutation(client: APIClient, _ op: () async throws -> Void) async -> Bool {
        lastMutationError = nil
        do {
            try await op()
            await refreshLoaded(using: client)
            return true
        } catch {
            lastMutationError = error.message
            return false
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
