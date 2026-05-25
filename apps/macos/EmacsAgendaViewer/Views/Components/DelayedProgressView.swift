import SwiftUI

/// Shows nothing for `delay` seconds, then reveals the spinner. Prevents a
/// full-screen flash on fast reads (eavd answers locally in <2ms) while still
/// surfacing progress for real network calls.
struct DelayedProgressView: View {
    var delay: Double = 0.25

    @State private var visible = false

    var body: some View {
        Group {
            if visible {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if !Task.isCancelled { visible = true }
        }
    }
}
