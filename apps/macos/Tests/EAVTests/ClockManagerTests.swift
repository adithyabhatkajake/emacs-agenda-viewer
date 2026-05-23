import Testing
import Foundation
@testable import EAVCore

// MARK: - Minimal TaskDisplayable stub

private struct StubTask: TaskDisplayable {
    var id: String
    var title: String
    var todoState: String? = "TODO"
    var priority: String? = nil
    var tags: [String] = []
    var inheritedTags: [String] = []
    var scheduled: OrgTimestamp? = nil
    var deadline: OrgTimestamp? = nil
    var category: String = "Test"
    var file: String = "/test.org"
    var pos: Int = 1
}

// MARK: - Minimal APIClient
// _logClockEntry is always overridden in tests so no real network calls occur.
private func makeClient() -> APIClient {
    APIClient(baseURLString: "http://127.0.0.1:39999")!
}

// MARK: - Test isolation helpers

// ClockManager persists sessions to UserDefaults; clear before and after each test.
private let clockStorageKey = "activeClocks_v1"

// Session shape mirroring ClockManager.Session's Codable fields.
private struct SeedSession: Codable {
    let id: String; let file: String; let pos: Int
    let title: String; let category: String; let startedAt: Date
}

/// Returns a fresh ClockManager with UserDefaults cleared, then seeds one session
/// whose startedAt is `secondsAgo` seconds in the past so stop() reliably takes
/// the non-zero-duration path.
@MainActor
private func freshManager(taskId: String = "test::1",
                           title: String = "Test",
                           file: String = "/test.org",
                           pos: Int = 1,
                           category: String = "Test",
                           secondsAgo: Double = 10) -> ClockManager {
    UserDefaults.standard.removeObject(forKey: clockStorageKey)
    let seed = SeedSession(
        id: taskId, file: file, pos: pos,
        title: title, category: category,
        startedAt: Date(timeIntervalSinceNow: -secondsAgo)
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .deferredToDate
    if let data = try? encoder.encode([seed]) {
        UserDefaults.standard.set(data, forKey: clockStorageKey)
    }
    return ClockManager()
}

/// Returns a fresh ClockManager with UserDefaults cleared and NO sessions.
@MainActor
private func emptyManager() -> ClockManager {
    UserDefaults.standard.removeObject(forKey: clockStorageKey)
    return ClockManager()
}

// MARK: - Test Suite

@Suite("ClockManager")
struct ClockManagerTests {

    // MARK: Case 1: stop succeeds — session removed, no duplicate

    @Test("stop success removes session without duplicate")
    @MainActor func stopSuccessRemovesSession() async {
        let manager = freshManager(taskId: "a::1", title: "Alpha")
        defer { UserDefaults.standard.removeObject(forKey: clockStorageKey) }
        #expect(manager.sessions.count == 1)

        manager._logClockEntry = { _, _, _, _ in }
        let duration = await manager.stop(taskId: "a::1", using: makeClient())

        #expect(duration != nil && duration! > 0, "successful stop returns positive duration")
        #expect(manager.sessions.isEmpty, "session must be removed after successful stop")
        #expect(manager.lastStopError == nil)

        // Confirm no ghost: starting again (via full start) produces exactly one session.
        let task = StubTask(id: "a::1", title: "Alpha")
        manager.start(task: task)
        #expect(manager.sessions.count == 1)
    }

    // MARK: Case 2: stop fails — session reinstated exactly once, no duplicate

    @Test("stop failure reinstates session exactly once")
    @MainActor func stopFailureReinstatesSession() async {
        let manager = freshManager(taskId: "b::2", title: "Beta")
        defer { UserDefaults.standard.removeObject(forKey: clockStorageKey) }
        #expect(manager.sessions.count == 1)

        struct FakeError: LocalizedError {
            var errorDescription: String? { "network gone" }
        }
        manager._logClockEntry = { _, _, _, _ in throw FakeError() }
        let duration = await manager.stop(taskId: "b::2", using: makeClient())

        #expect(duration == nil, "failed stop returns nil")
        #expect(manager.sessions.count == 1, "exactly one session after failed stop")
        #expect(manager.sessions.first?.id == "b::2")
        #expect(manager.sessions.first?.stoppingSince == nil,
                "stoppingSince cleared on rollback so user can retry")
        #expect(manager.lastStopError != nil)
    }

    // MARK: Case 3: reentrancy guard — start and second stop blocked while stop is mid-await
    //
    // The reentrancy guard sets stoppingSince on the session BEFORE calling
    // _logClockEntry. _logClockEntry therefore runs while stoppingSince is set,
    // making it the ideal synchronous observation point: all invariant checks
    // happen from within the closure, on @MainActor, without needing cross-actor
    // concurrency or blocking primitives.

    @Test("reentrancy guard blocks start and second stop while stop is mid-_logClockEntry")
    @MainActor func reentrancyGuardBlocksStartAndSecondStop() async {
        let manager = freshManager(taskId: "c::3", title: "Gamma")
        defer { UserDefaults.standard.removeObject(forKey: clockStorageKey) }
        #expect(manager.sessions.count == 1)

        // Invariant observations captured from inside _logClockEntry.
        var stoppingSinceObserved: Date? = nil
        var isClockedObserved = false
        var sessionCountAfterStart = -1
        var secondStopReturnedNil = false
        var networkCallCount = 0

        // _logClockEntry is called by stop() AFTER stoppingSince is set on the session.
        // Invariant checks run here, synchronously on @MainActor.
        manager._logClockEntry = { [manager] _, _, _, _ in
            stoppingSinceObserved = manager.sessions.first(where: { $0.id == "c::3" })?.stoppingSince
            isClockedObserved = manager.isClocked(taskId: "c::3")

            // start() for the same task must be a no-op while stoppingSince is set.
            let task = StubTask(id: "c::3", title: "Gamma")
            manager.start(task: task)
            sessionCountAfterStart = manager.sessions.count

            // A second stop() must return nil: reentrancy guard fires before
            // _logClockEntry, so networkCallCount must stay 0.
            manager._logClockEntry = { _, _, _, _ in networkCallCount += 1 }
            let r = await manager.stop(taskId: "c::3", using: makeClient())
            secondStopReturnedNil = (r == nil)
        }

        _ = await manager.stop(taskId: "c::3", using: makeClient())

        #expect(stoppingSinceObserved != nil,
                "stoppingSince must be non-nil when _logClockEntry is called")
        #expect(isClockedObserved,
                "isClocked must return true while stop is mid-_logClockEntry")
        #expect(sessionCountAfterStart == 1,
                "start must not add duplicate while stoppingSince is set")
        #expect(secondStopReturnedNil,
                "second stop() returns nil (reentrancy guard fires before network call)")
        #expect(networkCallCount == 0,
                "second stop must not reach _logClockEntry")
        #expect(manager.sessions.isEmpty,
                "session removed after stop completes")
    }

    // MARK: Case 4: zero-duration stop clears lastStopError

    @Test("zero-duration stop clears stale lastStopError")
    @MainActor func zeroDurationBranchClearsError() async {
        // Seed a session whose startedAt is in the future so that
        // Int(end) <= Int(startedAt), reliably triggering the zero-duration guard.
        // ClockManager restores sessions from UserDefaults on init — the only
        // path that lets us inject an arbitrary startedAt.
        let futureDate = Date(timeIntervalSinceNow: 300)
        let seed = SeedSession(
            id: "d::4", file: "/t.org", pos: 1,
            title: "Delta", category: "Test", startedAt: futureDate
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .deferredToDate
        let data = try! encoder.encode([seed])

        UserDefaults.standard.removeObject(forKey: clockStorageKey)
        UserDefaults.standard.set(data, forKey: clockStorageKey)
        defer { UserDefaults.standard.removeObject(forKey: clockStorageKey) }

        let manager = ClockManager()
        manager.lastStopError = "old error from previous attempt"

        #expect(manager.sessions.count == 1)
        #expect(manager.isClocked(taskId: "d::4"))

        let duration = await manager.stop(taskId: "d::4", using: makeClient())

        #expect(duration == 0, "zero-duration stop returns 0")
        #expect(manager.sessions.isEmpty, "zero-duration stop removes the session")
        #expect(manager.lastStopError == nil,
                "zero-duration stop must clear stale lastStopError")
    }
}
