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

        func elapsed(now: Date = Date()) -> TimeInterval {
            max(0, now.timeIntervalSince(startedAt))
        }
    }

    private static let storageKey = "activeClocks_v1"

    private(set) var sessions: [Session] = [] {
        didSet { persist() }
    }
    /// Updated by a 1Hz ticker so views re-render elapsed labels.
    var tick: Int = 0
    private var timerTask: Task<Void, Never>?

    init() {
        // Restore any clocks that were running when the app last quit.
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let restored = try? JSONDecoder().decode([Session].self, from: data) {
            sessions = restored
        }
        startTicker()
    }

    private func persist() {
        if sessions.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.storageKey)
        } else if let data = try? JSONEncoder().encode(sessions) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    private func startTicker() {
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await MainActor.run { self?.tick &+= 1 }
            }
        }
    }

    func isClocked(taskId: String) -> Bool {
        sessions.contains(where: { $0.id == taskId })
    }

    func start(task: any TaskDisplayable) {
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

    /// Stop a session and push the entry to the server. Returns the duration in seconds.
    /// `store` is consulted to refresh the heading position in case earlier clock
    /// log writes shifted the file.
    @discardableResult
    func stop(taskId: String, using client: APIClient, store: TasksStore? = nil) async -> Int? {
        guard let s = sessions.first(where: { $0.id == taskId }) else { return nil }
        let end = Date()
        let startEpoch = Int(s.startedAt.timeIntervalSince1970)
        let endEpoch = Int(end.timeIntervalSince1970)
        guard endEpoch > startEpoch else {
            sessions.removeAll(where: { $0.id == taskId })
            return 0
        }

        // Refresh the store FIRST so currentPos reflects any earlier mutations
        // from this batch (each clock-out shifts the file).
        if let store, let allTasks = store.allTasks.value, !allTasks.isEmpty {
            await store.loadAllTasks(using: client)
        }
        let pos = currentPos(for: s, store: store) ?? s.pos

        // Re-resolve the index after the await — the array may have mutated during suspension.
        guard let idx = sessions.firstIndex(where: { $0.id == taskId }) else { return nil }
        // Optimistically remove from the dock; reinsert on failure so the user can retry.
        sessions.remove(at: idx)
        do {
            try await client.logClockEntry(file: s.file, pos: pos, start: startEpoch, end: endEpoch)
            lastStopError = nil
            // Refresh again so any subsequent clock-out sees the inserted CLOCK line shift.
            if let store { await store.refreshLoaded(using: client) }
            return endEpoch - startEpoch
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            lastStopError = "Couldn't log clock for \(s.title): \(msg)"
            let safeIdx = min(idx, sessions.count)
            sessions.insert(s, at: safeIdx)
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
