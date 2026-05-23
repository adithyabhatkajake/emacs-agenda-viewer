#if !os(macOS)
import SwiftUI

/// Standard scaffold for modal picker/editor sheets.
///
/// Wraps content in NavigationStack → ZStack, overlays a ProgressView
/// when `isMutating` is true, disables the content during mutation,
/// and wires Cancel (always) plus an optional Save button.
///
/// `saveAction` — nil means no Save button; a non-nil closure is called
/// on Save tap, must return `true` to auto-dismiss, `false` to stay open
/// (so the sheet can surface an error).
///
/// `saveDisabled` — additional predicate to disable Save independently of
/// `isMutating` (e.g. "draft unchanged").
///
/// Error display: drop `ErrorSection(errorMessage)` at the end of your
/// Form/List content — keeping the error inline with the form rows.
struct PickerSheetScaffold<Content: View>: View {
    let title: String
    let isMutating: Bool
    let saveAction: (() async -> Bool)?
    var saveDisabled: Bool = false
    @ViewBuilder let content: Content

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                content
                    .disabled(isMutating)

                if isMutating {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(1.5)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.ultraThinMaterial)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isMutating)
                }
                if let action = saveAction {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            Task {
                                let shouldDismiss = await action()
                                if shouldDismiss { dismiss() }
                            }
                        }
                        .disabled(isMutating || saveDisabled)
                    }
                }
            }
        }
    }
}

/// Renders a form error row. Drop inside a `Form` or `List` when
/// `message` is non-nil; produces `EmptyView` otherwise.
@ViewBuilder
func ErrorSection(_ message: String?) -> some View {
    if let msg = message {
        Section {
            Text(msg)
                .foregroundStyle(.red)
                .font(.footnote)
        }
    }
}
#endif
