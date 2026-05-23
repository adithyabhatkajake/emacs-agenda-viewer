import Testing
import Foundation
@testable import EAVCore

@Suite("Debouncer")
struct DebouncerTests {

    // MARK: - 5 rapid calls within a short window produce exactly 1 invocation

    @Test("5 calls within 100ms coalesce into 1 invocation")
    @MainActor func rapidCallsCoalesce() async {
        let debouncer = Debouncer(interval: .milliseconds(200))
        var count = 0

        for _ in 0..<5 {
            debouncer.schedule { count += 1 }
            // Spacing within 100ms total; each new call cancels the previous.
            try? await Task.sleep(for: .milliseconds(15))
        }

        // Wait long enough for the final debounce window to fire.
        try? await Task.sleep(for: .milliseconds(300))

        #expect(count == 1, "5 rapid calls must coalesce into exactly 1 invocation")
    }

    // MARK: - Calls spaced further than the window apart each invoke separately

    @Test("calls spaced beyond window each invoke separately")
    @MainActor func spacedCallsEachFire() async {
        let debouncer = Debouncer(interval: .milliseconds(100))
        var count = 0

        for _ in 0..<3 {
            debouncer.schedule { count += 1 }
            // Wait longer than the window before the next call.
            try? await Task.sleep(for: .milliseconds(200))
        }

        // Final window already elapsed in the loop; no extra wait needed,
        // but add a small buffer for scheduler jitter.
        try? await Task.sleep(for: .milliseconds(50))

        #expect(count == 3, "3 calls spaced beyond the window must each fire")
    }

    // MARK: - cancel() prevents the pending invocation

    @Test("cancel prevents pending invocation")
    @MainActor func cancelPreventsInvocation() async {
        let debouncer = Debouncer(interval: .milliseconds(150))
        var count = 0

        debouncer.schedule { count += 1 }
        debouncer.cancel()

        try? await Task.sleep(for: .milliseconds(300))

        #expect(count == 0, "cancel must prevent the scheduled invocation from running")
    }
}
