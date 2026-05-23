import SwiftUI

/// A single color-picker row used in the TODO-state, priority, and category
/// color sections of SettingsView.  The label content varies per row type,
/// so it is supplied as a @ViewBuilder closure.  `defaultIndicator` is the
/// string shown when no custom color is set ("default" for states/priorities,
/// "auto" for categories).
struct ColorEditRow<Label: View>: View {
    let currentHex: String?
    let currentColor: Color
    let defaultIndicator: String
    let pickerLabel: String
    let onSet: (String) -> Void
    let onReset: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        HStack {
            ColorPicker("", selection: Binding(
                get: { currentColor },
                set: { newValue in
                    if let hex = newValue.hexString() { onSet(hex) }
                }
            ), supportsOpacity: false)
            .labelsHidden()
            .accessibilityLabel("Color for \(pickerLabel)")
#if os(macOS)
            .frame(width: 36)
#endif

            label()

            Spacer()

            if currentHex != nil {
#if os(macOS)
                Text("custom")
                    .font(.caption2)
                    .foregroundStyle(Theme.textTertiary)
                Button("Reset", action: onReset)
                    .controlSize(.small)
#else
                Button("Reset", action: onReset)
                    .buttonStyle(.borderless)
#endif
            } else {
                Text(defaultIndicator)
                    .font(.caption2)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }
}
