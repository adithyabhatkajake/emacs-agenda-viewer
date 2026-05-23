import Foundation
import Observation

@MainActor
@Observable
final class ClockManager {
    struct Session: Identifiable, Hashable, Codable {
        let id: String           // taskId
        let file: String
        let pos: Int
        let title: String
        let category: String
        let startedAt: Date
        // Non-nil while a stop() call is mid-await for this session.
        // Excluded from persistence; rehydrated sessions are never mid-stop.
        var stoppingSince: Date?

        func elapsed(now: Date = Date()) -> TimeInterval {
            max(0, now.timeIntervalSince(startedAt))
        }

        // Exclude stoppingSince from UserDefaults persistence.
        private enum CodingKeys: String, CodingKey {
            case id, file, pos, title, category, startedAt
        }

        static func == (lhs: Session, rhs: Session) -> Bool {
            lhs.id == rhs.id
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(id)
        }
    }

    private static let storageKey = "activeClocks_v1"

    private(set) var sessions: [Session] = [] {
        didSet { persist() }
    }
    init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let restored = try? JSONDecoder().decode([Session].self, from: data) {
            sessions = restored
        }
    }

    private func persist() {
        if sessions.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.storageKey)
        } else if let data = try? JSONEncoder().encode(sessions) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    func isClocked(taskId: String) -> Bool {
        sessions.contains(where: { $0.id == taskId })
    }

    func start(task: any TaskDisplayable) {
        // isClocked returns true while a stop() is mid-await, blocking concurrent start.
        guard !isClocked(taskId: task.id) else { return }
        sessions.append(Session(
            id: task.id,
            file: task.file,
            pos: task.pos,
            title: task.title,
            category: task.category,
            startedAt: Date()
        ))
    }

    /// Last error encountered when trying to stop a clock — surfaced in the dock UI.
    var lastStopError: String?

    // Overridable for unit tests; nil means use client.logClockEntry in production.
    var _logClockEntry: ((String, Int, Int, Int) async throws -> Void)?

    /// Stop a session and push the entry to the server. Returns the duration in seconds.
    /// `store` is consulted to refresh the heading position in case earlier clock
    /// log writes shifted the file.
    @discardableResult
    func stop(taskId: String, using client: APIClient, store: TasksStore? = nil) async -> Int? {
        guard let s = sessions.first(where: { $0.id == taskId }) else { return nil }
        // Reentrancy guard: if a stop() is already in flight for this task, do nothing.
        guard s.stoppingSince == nil else { return nil }

        let end = Date()
        let startEpoch = Int(s.startedAt.timeIntervalSince1970)
        let endEpoch = Int(end.timeIntervalSince1970)
        guard endEpoch > startEpoch else {
            lastStopError = nil
            sessions.removeAll(where: { $0.id == taskId })
            return 0
        }

        // Mark the session as stopping — keeps isClocked true, blocking concurrent start().
        guard let idx = sessions.firstIndex(where: { $0.id == taskId }) else { return nil }
        sessions[idx].stoppingSince = end

        // Refresh the store FIRST so currentPos reflects any earlier mutations
        // from this batch (each clock-out shifts the file).
        if let store, let allTasks = store.allTasks.value, !allTasks.isEmpty {
            await store.loadAllTasks(using: client)
        }
        // Re-resolve the index after the await — safe because stoppingSince prevents
        // any concurrent stop() from touching this session.
        guard let currentIdx = sessions.firstIndex(where: { $0.id == taskId }) else { return nil }
        let pos = currentPos(for: sessions[currentIdx], store: store) ?? s.pos

        do {
            let log = _logClockEntry ?? { file, p, start, end in
                try await client.logClockEntry(file: file, pos: p, start: start, end: end)
            }
            try await log(s.file, pos, startEpoch, endEpoch)
            lastStopError = nil
            sessions.removeAll(where: { $0.id == taskId })
            // Refresh again so any subsequent clock-out sees the inserted CLOCK line shift.
            if let store { await store.refreshLoaded(using: client) }
            return endEpoch - startEpoch
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            lastStopError = "Couldn't log clock for \(s.title): \(msg)"
            // Clear the stopping marker so the user can retry from the dock.
            if let rollbackIdx = sessions.firstIndex(where: { $0.id == taskId }) {
                sessions[rollbackIdx].stoppingSince = nil
            }
            return nil
        }
    }

    private func currentPos(for session: Session, store: TasksStore?) -> Int? {
        guard let store else { return nil }
        if let t = store.allTasks.value?.first(where: { $0.file == session.file && $0.title == session.title }) {
            return t.pos
        }
        if let t = store.today.value?.first(where: { $0.file == session.file && $0.title == session.title }) {
            return t.pos
        }
        if let t = store.upcoming.value?.first(where: { $0.file == session.file && $0.title == session.title }) {
            return t.pos
        }
        return nil
    }

    func cancel(taskId: String) {
        sessions.removeAll(where: { $0.id == taskId })
    }
}

extension ClockManager {
    static func formatElapsed(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}
