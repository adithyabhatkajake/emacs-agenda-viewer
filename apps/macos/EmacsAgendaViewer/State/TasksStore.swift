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
    var clock: ClockStatus?

    /// Last server-side error from a mutation, if any. Surfaced by views.
    var lastMutationError: String?

    /// Notes cache keyed by "file::pos".
    var notesCache: [String: String] = [:]

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

    func loadAllTasks(using client: APIClient, includeDone: Bool = false) async {
        if allTasks.value == nil { allTasks = .loading }
        do {
            let tasks = try await client.fetchTasks(includeAll: includeDone)
            allTasks = .loaded(tasks)
        } catch {
            allTasks = .failed(error.message)
        }
    }

    func loadMetadata(using client: APIClient) async {
        async let filesResult = try? client.fetchFiles()
        async let keywordsResult = try? client.fetchKeywords()
        async let clockResult = try? client.fetchClockStatus()
        self.files = (await filesResult) ?? []
        self.keywords = await keywordsResult
        self.clock = await clockResult
    }

    func refreshClock(using client: APIClient) async {
        self.clock = try? await client.fetchClockStatus()
    }

    /// Refresh whichever lists currently hold data. Called after mutations.
    func refreshLoaded(using client: APIClient, includeDone: Bool = false) async {
        await withTaskGroup(of: Void.self) { group in
            if today.value != nil {
                group.addTask { await self.loadToday(using: client) }
            }
            if upcoming.value != nil {
                group.addTask { await self.loadUpcoming(using: client) }
            }
            if allTasks.value != nil {
                group.addTask { await self.loadAllTasks(using: client, includeDone: includeDone) }
            }
            group.addTask { await self.refreshClock(using: client) }
        }
    }

    // MARK: - Mutations

    func toggleDone(_ task: any TaskDisplayable, file: String, pos: Int, using client: APIClient) async {
        let isDone = isDoneState(task.todoState)
        let nextState: String
        if isDone {
            // Toggle from done back to first active state, fallback "TODO"
            nextState = keywords?.allActive.first ?? "TODO"
        } else {
            nextState = keywords?.allDone.first ?? "DONE"
        }
        await setState(taskId: task.id, file: file, pos: pos, state: nextState, using: client)
    }

    func setState(taskId: String, file: String, pos: Int, state: String, using client: APIClient) async {
        await runMutation(client: client) {
            try await client.setState(taskId: taskId, file: file, pos: pos, state: state)
        }
    }

    func setPriority(taskId: String, file: String, pos: Int, priority: String, using client: APIClient) async {
        await runMutation(client: client) {
            try await client.setPriority(taskId: taskId, file: file, pos: pos, priority: priority)
        }
    }

    func setTitle(taskId: String, file: String, pos: Int, title: String, using client: APIClient) async {
        await runMutation(client: client) {
            try await client.setTitle(taskId: taskId, file: file, pos: pos, title: title)
        }
    }

    func setScheduled(taskId: String, file: String, pos: Int, timestamp: String, using client: APIClient) async {
        await runMutation(client: client) {
            try await client.setScheduled(taskId: taskId, file: file, pos: pos, timestamp: timestamp)
        }
    }

    func setDeadline(taskId: String, file: String, pos: Int, timestamp: String, using client: APIClient) async {
        await runMutation(client: client) {
            try await client.setDeadline(taskId: taskId, file: file, pos: pos, timestamp: timestamp)
        }
    }

    func setProperty(taskId: String, file: String, pos: Int, key: String, value: String, using client: APIClient) async {
        await runMutation(client: client) {
            try await client.setProperty(taskId: taskId, file: file, pos: pos, key: key, value: value)
        }
    }

    func clockIn(file: String, pos: Int, using client: APIClient) async {
        await runMutation(client: client) {
            try await client.clockIn(file: file, pos: pos)
        }
    }

    func clockOut(using client: APIClient) async {
        await runMutation(client: client) {
            try await client.clockOut()
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

    func setNotes(file: String, pos: Int, notes: String, using client: APIClient) async {
        let key = "\(file)::\(pos)"
        do {
            let final = try await client.setNotes(file: file, pos: pos, notes: notes)
            notesCache[key] = final
            await refreshLoaded(using: client)
        } catch {
            lastMutationError = error.message
        }
    }

    // MARK: - Helpers

    func isDoneState(_ state: String?) -> Bool {
        guard let state else { return false }
        let upper = state.uppercased()
        return (keywords?.allDone ?? []).contains(where: { $0.uppercased() == upper })
    }

    private func runMutation(client: APIClient, _ op: () async throws -> Void) async {
        do {
            try await op()
            await refreshLoaded(using: client)
        } catch {
            lastMutationError = error.message
        }
    }
}

private extension Error {
    var message: String {
        (self as? LocalizedError)?.errorDescription ?? localizedDescription
    }
}
