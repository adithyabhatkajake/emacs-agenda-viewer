#if !os(macOS)
import ActivityKit
import Foundation
import Observation

/// Bridges ClockManager.sessions ([Clock]) to a single roster-driven
/// Activity<ClockActivityAttributes>.
///
/// One Activity covers all concurrent clocks. iOS only surfaces one Activity
/// in the Dynamic Island regardless of how many are requested, so a per-task
/// model silently hides all but one. Instead we maintain exactly one Activity
/// whose ContentState.clocks mirrors the full session roster ordered
/// most-recently-started first.
///
/// Lifecycle: if sessions is non-empty → ensure one Activity exists and
/// update its ContentState; if sessions is empty → end the Activity.
/// ContentState is pushed only on roster changes (start/stop), never
/// per-second — elapsed time self-ticks via Text(timerInterval:).
@MainActor
@Observable
final class ClockLiveActivityCoordinator {
    private static let sessionActivityIdKey = "clockSessionActivityId_v2"
    private static let sessionId = "clock-session"

    /// Persisted across launches so reconcileOnLaunch can find a surviving
    /// Activity without requesting a duplicate.
    private var sessionActivityId: String? {
        didSet { persistActivityId() }
    }

    /// Surfaces failures (permission off, concurrent-limit exceeded, …)
    /// so the app can surface them in Settings or near the ClockCard.
    var lastError: String?

    init() {
        sessionActivityId = UserDefaults.standard.string(forKey: Self.sessionActivityIdKey)
    }

    // MARK: - Public API (same call sites as before)

    /// Diff the desired roster against the live Activity and request/update/end
    /// as needed. Safe to call on every ClockManager.sessions mutation.
    func sync(sessions: [Clock]) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        if sessions.isEmpty {
            await endSessionActivity()
        } else {
            let state = contentState(from: sessions)
            if let activityId = sessionActivityId,
               let existing = Activity<ClockActivityAttributes>.activities
                   .first(where: { $0.id == activityId }) {
                await existing.update(ActivityContent(state: state, staleDate: nil))
                lastError = nil
            } else {
                await requestSessionActivity(state: state)
            }
        }
    }

    /// On cold-start: if an Activity survived from a previous launch and
    /// sessions are still active, re-pair and update; end orphans. Any session
    /// without a live Activity gets a fresh request.
    func reconcileOnLaunch(sessions: [Clock]) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let active = Activity<ClockActivityAttributes>.activities

        if sessions.isEmpty {
            // End any orphaned Activities.
            for activity in active {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            sessionActivityId = nil
            return
        }

        let state = contentState(from: sessions)

        // If the persisted id still refers to a live Activity, update it.
        if let storedId = sessionActivityId,
           let surviving = active.first(where: { $0.id == storedId }) {
            await surviving.update(ActivityContent(state: state, staleDate: nil))
            lastError = nil
            // End any extras (shouldn't exist, but be defensive).
            for activity in active where activity.id != storedId {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            return
        }

        // No matching survivor — end anything stale and request fresh.
        for activity in active {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        sessionActivityId = nil
        await requestSessionActivity(state: state)
    }

    // MARK: - Private

    private func contentState(from sessions: [Clock]) -> ClockActivityAttributes.ContentState {
        // Sort most-recently-started first so [0] is the "primary" clock shown
        // in compact/minimal regions.
        let sorted = sessions.sorted { $0.start > $1.start }
        let entries = sorted.map { clock in
            ClockActivityAttributes.ContentState.Entry(
                taskId: clock.taskId,
                title: clock.title ?? clock.taskId,
                startedAt: Date(timeIntervalSince1970: Double(clock.start))
            )
        }
        return ClockActivityAttributes.ContentState(clocks: entries)
    }

    private func requestSessionActivity(state: ClockActivityAttributes.ContentState) async {
        let attrs = ClockActivityAttributes(sessionId: Self.sessionId)
        do {
            let activity = try Activity<ClockActivityAttributes>.request(
                attributes: attrs,
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil
            )
            sessionActivityId = activity.id
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func endSessionActivity() async {
        defer { sessionActivityId = nil }
        guard let activityId = sessionActivityId,
              let activity = Activity<ClockActivityAttributes>.activities
                  .first(where: { $0.id == activityId })
        else {
            // Also end any orphaned Activities not in our map.
            for activity in Activity<ClockActivityAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            return
        }
        await activity.end(nil, dismissalPolicy: .immediate)
        // End any extras defensively.
        for activity in Activity<ClockActivityAttributes>.activities where activity.id != activityId {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    private func persistActivityId() {
        if let id = sessionActivityId {
            UserDefaults.standard.set(id, forKey: Self.sessionActivityIdKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.sessionActivityIdKey)
        }
    }
}
#endif
