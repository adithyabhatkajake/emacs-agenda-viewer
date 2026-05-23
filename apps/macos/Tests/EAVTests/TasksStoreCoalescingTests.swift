import Testing
import Foundation
@testable import EAVCore

// TasksStore is @MainActor so all tests that touch it must run on the main actor.
@Suite("TasksStore coalescing")
@MainActor
struct TasksStoreCoalescingTests {

    // Construct an APIClient pointing at a port that is never open.
    // fetchTasks will throw quickly. We use this because allTasksIncludeDone
    // is assigned at the top of loadAllTasks before the failing await, so we
    // can observe it even when the network call fails.
    private func makeFailingClient() -> APIClient {
        APIClient(baseURLString: "http://127.0.0.1:19999")!
    }

    // Prime allTasks to .loaded([]) by directly calling loadAllTasks.
    // Even though the network call fails, the state machine sets allTasks
    // to .failed — but that's a detail; what we care about is the
    // allTasksIncludeDone flag. We set allTasks manually via the public var.
    //
    // (allTasksIncludeDone is private(set), so we prime it via
    //  refreshLoaded with includeDone:true on a store that has allTasks loaded.)

    @Test("refreshLoaded passes includeDone=true when allTasks is loaded")
    func refreshLoadedCarriesIncludeDone() async {
        let store = TasksStore()
        // Pre-populate so runRefresh will call loadAllTasks.
        store.allTasks = .loaded([])

        let client = makeFailingClient()
        // allTasksIncludeDone is set inside loadAllTasks before the network
        // await, so we can read it even though the fetch fails.
        await store.refreshLoaded(using: client, includeDone: true)

        #expect(store.allTasksIncludeDone == true,
            "includeDone=true must survive to loadAllTasks even when network fails")
    }

    @Test("refreshLoaded does not downgrade existing allTasksIncludeDone=true")
    func refreshLoadedDoesNotDowngrade() async {
        let store = TasksStore()
        store.allTasks = .loaded([])

        let client = makeFailingClient()

        // Prime allTasksIncludeDone to true via an explicit includeDone:true call.
        await store.refreshLoaded(using: client, includeDone: true)
        #expect(store.allTasksIncludeDone == true)

        // Now refresh with default (false). The existing flag must be preserved
        // because runRefresh ORs allTasksIncludeDone with the caller's value.
        await store.refreshLoaded(using: client, includeDone: false)

        #expect(store.allTasksIncludeDone == true,
            "includeDone=true must not be downgraded by a subsequent includeDone=false refresh")
    }
}
