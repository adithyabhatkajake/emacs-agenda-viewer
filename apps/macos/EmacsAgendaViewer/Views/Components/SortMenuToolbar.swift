import SwiftUI

/// Reusable toolbar menu that exposes a SortKey picker. Used by Today /
/// Upcoming / Pinned / Inbox / All Tasks so each view gets the same
/// affordance with one line. iOS-only — Mac has its own `SortMenu` in
/// `MacToolbar.swift` with different styling.
#if !os(macOS)
struct SortMenuToolbar: ToolbarContent {
    let options: [SortKey]
    @Binding var selection: SortKey

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("Sort by", selection: $selection) {
                    ForEach(options) { key in
                        Text(key.label).tag(key)
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down.circle")
            }
        }
    }
}
#endif
