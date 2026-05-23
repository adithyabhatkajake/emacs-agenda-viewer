import Foundation

/// Coalesces rapid calls into a single invocation after a quiescent window.
///
/// All methods must be called on `@MainActor`. Typical use:
///
///     private let debouncer = Debouncer(interval: .milliseconds(500))
///     debouncer.schedule { await self.expensiveWork() }
@MainActor
final class Debouncer {
    private let interval: Duration
    private var pending: Task<Void, Never>?

    init(interval: Duration) {
        self.interval = interval
    }

    /// Cancel any pending invocation and schedule a new one after `interval`.
    func schedule(_ work: @Sendable @escaping @MainActor () async -> Void) {
        pending?.cancel()
        let captured = interval
        pending = Task { [weak self] in
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: captured)
            guard !Task.isCancelled else { return }
            await work()
            if let self { self.pending = nil }
        }
    }

    /// Cancel any pending invocation without running it.
    func cancel() {
        pending?.cancel()
        pending = nil
    }
}
