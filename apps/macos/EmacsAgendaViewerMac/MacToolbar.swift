import SwiftUI

struct SortMenu: View {
    let options: [SortKey]
    @Binding var selection: SortKey

    var body: some View {
        Menu {
            ForEach(options) { key in
                Button {
                    selection = key
                } label: {
                    if selection == key {
                        Label(key.label, systemImage: "checkmark")
                    } else {
                        Text(key.label)
                    }
                }
            }
        } label: {
            Label("Sort: \(selection.label)", systemImage: "arrow.up.arrow.down")
        }
        .help("Sort by")
    }
}

struct GroupMenu: View {
    @Binding var selection: GroupKey

    var body: some View {
        Menu {
            ForEach(GroupKey.all) { key in
                Button {
                    selection = key
                } label: {
                    if selection == key {
                        Label(key.label, systemImage: "checkmark")
                    } else {
                        Text(key.label)
                    }
                }
            }
        } label: {
            Label("Group: \(selection.label)", systemImage: "rectangle.3.group")
        }
        .help("Group by")
    }
}

struct ReloadButton: View {
    let action: () -> Void
    var disabled: Bool = false

    var body: some View {
        Button(action: action) {
            Label("Reload", systemImage: "arrow.clockwise")
        }
        .keyboardShortcut("r", modifiers: .command)
        .disabled(disabled)
        .help("Reload")
    }
}
