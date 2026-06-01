import Testing
import Foundation
@testable import EAVCore

// MARK: - Helpers

private func makeClock(
    id: Int64,
    taskId: String,
    file: String = "/test.org",
    title: String? = nil,
    startSecondsAgo: Double = 10
) -> Clock {
    Clock(
        id: id,
        taskId: taskId,
        file: file,
        title: title,
        start: Int64(Date(timeIntervalSinceNow: -startSecondsAgo).timeIntervalSince1970),
        end: nil,
        note: nil
    )
}

// MARK: - Test Suite

@Suite("ClockManager")
struct ClockManagerTests {

    // MARK: isClocked

    @Test("isClocked returns false when sessions empty")
    @MainActor func isClockedEmptySessions() {
        let manager = ClockManager()
        #expect(!manager.isClocked(taskId: "a::1"))
    }

    @Test("isClocked returns true for a matching taskId")
    @MainActor func isClockedHit() {
        let manager = ClockManager()
        manager._setSessions([makeClock(id: 1, taskId: "a::1")])
        #expect(manager.isClocked(taskId: "a::1"))
        #expect(!manager.isClocked(taskId: "b::2"))
    }

    // MARK: clockFor

    @Test("clockFor returns correct Clock or nil")
    @MainActor func clockForLookup() {
        let manager = ClockManager()
        let c = makeClock(id: 42, taskId: "x::5", title: "My Task")
        manager._setSessions([c])
        #expect(manager.clockFor(taskId: "x::5")?.id == 42)
        #expect(manager.clockFor(taskId: "missing") == nil)
    }

    // MARK: elapsed

    @Test("elapsed is positive for a past start time")
    @MainActor func elapsedPositive() {
        let clock = makeClock(id: 1, taskId: "t::1", startSecondsAgo: 30)
        let e = ClockManager.elapsed(for: clock)
        #expect(e >= 29 && e <= 32, "elapsed should be ~30 s")
    }

    @Test("elapsed is zero for a future start time")
    @MainActor func elapsedFuture() {
        let future = Clock(
            id: 2,
            taskId: "f::1",
            file: "/f.org",
            title: nil,
            start: Int64(Date(timeIntervalSinceNow: 300).timeIntervalSince1970),
            end: nil,
            note: nil
        )
        #expect(ClockManager.elapsed(for: future) == 0)
    }

    // MARK: formatElapsed

    @Test("formatElapsed sub-hour")
    @MainActor func formatSubHour() {
        #expect(ClockManager.formatElapsed(75) == "1:15")
    }

    @Test("formatElapsed exactly one hour")
    @MainActor func formatOneHour() {
        #expect(ClockManager.formatElapsed(3600) == "1:00:00")
    }

    @Test("formatElapsed multi-hour")
    @MainActor func formatMultiHour() {
        #expect(ClockManager.formatElapsed(7384) == "2:03:04")
    }

    // MARK: _setSessions guard

    @Test("_setSessions replaces all sessions")
    @MainActor func setSessionsReplaces() {
        let manager = ClockManager()
        manager._setSessions([
            makeClock(id: 10, taskId: "a::1"),
            makeClock(id: 11, taskId: "b::2"),
        ])
        #expect(manager.sessions.count == 2)
        manager._setSessions([makeClock(id: 10, taskId: "a::1")])
        #expect(manager.sessions.count == 1)
    }
}
