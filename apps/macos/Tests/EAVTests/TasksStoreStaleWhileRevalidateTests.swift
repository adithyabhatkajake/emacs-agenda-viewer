import Testing
import Foundation
@testable import EAVCore

// TasksStore is @MainActor; touching it requires the main actor.
@Suite("TasksStore stale-while-revalidate")
@MainActor
struct TasksStoreStaleWhileRevalidateTests {

    // A client pointing at a port nothing listens on, so every fetch throws
    // quickly — the same pattern as TasksStoreCoalescingTests.
    private func makeFailingClient() -> APIClient {
        APIClient(baseURLString: "http://127.0.0.1:19999")!
    }

    @Test("Refresh failure keeps last-good allTasks and records lastRefreshError")
    func refreshFailurePreservesAllTasks() async {
        let store = TasksStore()
        let cached = [makeTask(id: "a::1", title: "Cached task")]
        store.allTasks = .loaded(cached)

        await store.loadAllTasks(using: makeFailingClient())

        // Last-good is preserved, not blanked to .failed.
        #expect(store.allTasks.value?.count == 1)
        #expect(store.allTasks.value?.first?.id == "a::1")
        #expect(store.allTasks.error == nil)
        // The transient error surfaces non-destructively.
        #expect(store.lastRefreshError != nil)
    }

    @Test("Refresh failure keeps last-good today entries")
    func refreshFailurePreservesToday() async {
        let store = TasksStore()
        store.today = .loaded([])  // loaded-but-empty still counts as cached

        await store.loadToday(using: makeFailingClient())

        #expect(store.today.value != nil, "an empty .loaded must survive a failed refresh")
        #expect(store.today.error == nil)
        #expect(store.lastRefreshError != nil)
    }

    @Test("Cold load failure still yields .failed")
    func coldFailureStillFails() async {
        let store = TasksStore()
        // No cached value (.idle) — this is a cold load.
        await store.loadAllTasks(using: makeFailingClient())

        #expect(store.allTasks.value == nil)
        #expect(store.allTasks.error != nil, "cold load failure must surface as .failed")
    }

    @Test("Successful refresh clears a prior lastRefreshError")
    func successfulRefreshClearsError() async {
        let store = TasksStore()
        store.allTasks = .loaded([makeTask()])
        // Force a refresh failure to set lastRefreshError.
        await store.refreshLoaded(using: makeFailingClient())
        #expect(store.lastRefreshError != nil)

        // runRefresh clears lastRefreshError optimistically at the start of the
        // round; a round with no live slices to fail leaves it nil.
        store.allTasks = .idle
        store.today = .idle
        store.upcoming = .idle
        await store.refreshLoaded(using: makeFailingClient())
        #expect(store.lastRefreshError == nil,
            "a refresh round that fails no loaded slice must clear the stale error")
    }
}
