import Foundation
import Observation

@MainActor
@Observable
final class ClockManager {
    // MARK: - Session mirrors server Clock rows (end == nil → running)

    private(set) var sessions: [Clock] = []

    /// Last error from a stop or cancel operation — surfaced in the dock UI.
    var lastStopError: String?

    // MARK: - Load

    /// Inject sessions directly — used only by unit tests.
    func _setSessions(_ clocks: [Clock]) {
        sessions = clocks
    }

    /// Populate `sessions` from the server's active-clocks endpoint.
    func loadActiveClocks(using client: APIClient) async {
        do {
            sessions = try await client.fetchActiveClocks()
        } catch {
            // Silent — stale sessions are better than a crash on startup.
        }
    }

    /// Remove any open clock rows for `taskId` from the local mirror WITHOUT a
    /// network call. Completing a task/habit already closes its clock on the
    /// server (patch_state / post_habit_complete), so the dock must stop
    /// ticking immediately rather than waiting for the `clock-changed` SSE to
    /// echo back — that echo can be missed, debounced, or fail silently inside
    /// `loadActiveClocks`, which would otherwise leave a phantom clock ticking
    /// forever with no recovery.
    func dropLocalClock(taskId: String) {
        sessions.removeAll { $0.taskId == taskId }
    }

    // MARK: - Queries

    func isClocked(taskId: String) -> Bool {
        sessions.contains(where: { $0.taskId == taskId })
    }

    func clockFor(taskId: String) -> Clock? {
        sessions.first(where: { $0.taskId == taskId })
    }

    // MARK: - Clock in

    /// Start a server-side clock for `task`. No-op when the task is already
    /// clocked. The server opens an open-ended row and fires `clock-changed`
    /// SSE; `loadActiveClocks` on the SSE event drives the local mirror.
    func clockIn(task: any TaskDisplayable, using client: APIClient) async {
        guard !isClocked(taskId: task.id) else { return }
        do {
            let clock = try await client.clockIn(
                file: task.file,
                pos: task.pos,
                title: task.title
            )
            // Optimistic insert so the dock responds before the SSE round-trip.
            // Dedupe by server id: the `clock-changed` SSE can drive
            // `loadActiveClocks` (which already contains this row) in between
            // the await above and this line, which would otherwise double it.
            if !sessions.contains(where: { $0.id == clock.id }) {
                sessions.append(clock)
            }
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            lastStopError = "Couldn't clock in to \(task.title): \(msg)"
        }
    }

    /// Start a server-side clock for a DB-backed habit (clocked by habit id).
    /// No-op when the habit is already clocked.
    func clockInHabit(id: String, title: String?, using client: APIClient) async {
        guard !isClocked(taskId: id) else { return }
        do {
            let clock = try await client.clockInHabit(id: id, title: title)
            if !sessions.contains(where: { $0.id == clock.id }) {
                sessions.append(clock)
            }
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            lastStopError = "Couldn't clock in to \(title ?? id): \(msg)"
        }
    }

    // MARK: - Clock out

    /// Stop a running clock by its server id. Returns the elapsed seconds.
    @discardableResult
    func clockOut(clockId: Int64, using client: APIClient) async -> Int? {
        guard let session = sessions.first(where: { $0.id == clockId }) else { return nil }
        do {
            try await client.clockOut(id: clockId)
            lastStopError = nil
            sessions.removeAll(where: { $0.id == clockId })
            let elapsed = Int(Date().timeIntervalSince1970) - Int(session.start)
            return max(0, elapsed)
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            lastStopError = "Couldn't stop clock for \(session.title ?? "task"): \(msg)"
            return nil
        }
    }

    /// Convenience: stop by taskId. Used from row actions.
    @discardableResult
    func stop(taskId: String, using client: APIClient, store: TasksStore? = nil) async -> Int? {
        guard let session = sessions.first(where: { $0.taskId == taskId }) else { return nil }
        return await clockOut(clockId: session.id, using: client)
    }

    // MARK: - Cancel

    /// Cancel a running clock without persisting the interval.
    func cancel(clockId: Int64, using client: APIClient) async {
        do {
            try await client.cancelClock(id: clockId)
            sessions.removeAll(where: { $0.id == clockId })
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            lastStopError = "Couldn't cancel clock: \(msg)"
        }
    }

    /// Convenience: cancel by taskId.
    func cancel(taskId: String, using client: APIClient) async {
        guard let session = sessions.first(where: { $0.taskId == taskId }) else { return }
        await cancel(clockId: session.id, using: client)
    }
}

extension ClockManager {
    /// Elapsed seconds since `clock.start`. Pure computation; no actor state.
    nonisolated static func elapsed(for clock: Clock, now: Date = Date()) -> TimeInterval {
        max(0, now.timeIntervalSince1970 - Double(clock.start))
    }

    nonisolated static func formatElapsed(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}
