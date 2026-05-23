#if !os(macOS)
import SwiftUI

/// Attaches a floating "+" button to any tab that should offer quick capture.
/// The button sits in the safe-area inset at `.bottom`, so it clears the tab
/// bar (and the home indicator on Face ID devices) without any hard-coded
/// pixel offsets. The sheet and its presentation state live here — callers
/// just apply `.captureFAB(store:)`.
struct CaptureFABModifier: ViewModifier {
    let store: TasksStore

    @Environment(AppSettings.self) private var settings
    @State private var showCaptureSheet = false

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom) {
                if settings.isConfigured {
                    HStack {
                        Spacer()
                        Button {
                            showCaptureSheet = true
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 56, height: 56)
                                .background(Theme.accent, in: Circle())
                                .shadow(color: Theme.accent.opacity(0.35), radius: 12, x: 0, y: 6)
                                .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
                        }
                        .padding(.trailing, 18)
                        .padding(.bottom, 8)
                        .accessibilityLabel("New task")
                    }
                }
            }
            .sheet(isPresented: $showCaptureSheet) {
                CaptureSheet(store: store)
            }
    }
}

extension View {
    func captureFAB(store: TasksStore) -> some View {
        modifier(CaptureFABModifier(store: store))
    }
}
#endif
