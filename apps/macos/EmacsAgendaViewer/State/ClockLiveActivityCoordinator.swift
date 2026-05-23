#if !os(macOS)
import ActivityKit
import Foundation
import Observation

/// Bridges `ClockManager.sessions` to iOS `Activity<ClockActivityAttributes>`.
/// One Live Activity per clocked session; lifecycle is request/end only —
/// the displayed elapsed timer self-ticks via SwiftUI's
/// `Text(timerInterval:)` reading `attributes.startedAt`, so we never push
/// per-second updates.
///
/// The map `taskId → activityId` lives in UserDefaults so reconnecting on
/// cold start can match surviving Activities to existing sessions instead
/// of orphaning + re-requesting.
@MainActor
@Observable
final class ClockLiveActivityCoordinator {
    private static let mapStorageKey = "clockLiveActivityMap_v1"

    /// `ClockManager.Session.id` → `Activity.id`. Persisted so cold-start
    /// reconciliation can re-pair iOS-owned activities with our sessions.
    private var activityIdByTaskId: [String: String] = [:] {
        didSet { persist() }
    }

    /// Surfaces failures (permission off, concurrent-limit exceeded, …) so
    /// the app can show them in Settings or near the ClockCard. Set in the
    /// failing `try`/`catch` arm; cleared on the next successful op.
    var lastError: String?

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.mapStorageKey),
           let restored = try? JSONDecoder().decode([String: String].self, from: data) {
            activityIdByTaskId = restored
        }
    }

    /// Diff sessions vs. the tracked map and request/end Activities to match.
    /// Safe to call on every change; idempotent.
    func sync(sessions: [ClockManager.Session]) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            // No permission — bail without touching state.
            return
        }
        let wantedIds = Set(sessions.map(\.id))
        let trackedIds = Set(activityIdByTaskId.keys)

        // End anything tracked that's no longer a live session.
        for staleId in trackedIds.subtracting(wantedIds) {
            await endActivity(for: staleId)
        }

        // Request a new Activity for any session we're not tracking yet.
        for session in sessions where activityIdByTaskId[session.id] == nil {
            await requestActivity(for: session)
        }
    }

    /// On cold-start: surviving iOS Activities should be re-paired to
    /// ClockManager sessions where the id matches, ended otherwise. Any
    /// session without a paired Activity gets a fresh request.
    func reconcileOnLaunch(sessions: [ClockManager.Session]) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let active = Activity<ClockActivityAttributes>.activities
        let sessionsById = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })

        // Walk surviving Activities. Keep those whose taskId is still in
        // sessions; end the rest.
        var rebuiltMap: [String: String] = [:]
        for activity in active {
            let taskId = activity.attributes.taskId
            if sessionsById[taskId] != nil {
                rebuiltMap[taskId] = activity.id
            } else {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
        activityIdByTaskId = rebuiltMap

        // Request Activities for any sessions without a paired one.
        for session in sessions where activityIdByTaskId[session.id] == nil {
            await requestActivity(for: session)
        }
    }

    // MARK: - Private

    private func requestActivity(for session: ClockManager.Session) async {
        let attrs = ClockActivityAttributes(
            taskId: session.id,
            title: session.title,
            category: session.category,
            startedAt: session.startedAt
        )
        let initialState = ClockActivityAttributes.ContentState()
        do {
            let activity = try Activity<ClockActivityAttributes>.request(
                attributes: attrs,
                content: ActivityContent(state: initialState, staleDate: nil),
                pushType: nil
            )
            activityIdByTaskId[session.id] = activity.id
            lastError = nil
        } catch {
            // Hit the per-app concurrent-LA limit, lost permission, etc.
            // Leave ClockManager session running; we just don't get an LA.
            lastError = error.localizedDescription
        }
    }

    private func endActivity(for taskId: String) async {
        defer { activityIdByTaskId.removeValue(forKey: taskId) }
        guard let activityId = activityIdByTaskId[taskId] else { return }
        guard let activity = Activity<ClockActivityAttributes>.activities
            .first(where: { $0.id == activityId })
        else { return }
        await activity.end(nil, dismissalPolicy: .immediate)
    }

    private func persist() {
        if activityIdByTaskId.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.mapStorageKey)
        } else if let data = try? JSONEncoder().encode(activityIdByTaskId) {
            UserDefaults.standard.set(data, forKey: Self.mapStorageKey)
        }
    }
}
#endif
