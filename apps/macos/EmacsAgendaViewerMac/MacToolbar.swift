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
    @Binding var primary: GroupKey
    @Binding var secondary: GroupKey

    var body: some View {
        Menu {
            Section("Group by") {
                ForEach(GroupKey.all) { key in
                    Button {
                        primary = key
                        if key == .none { secondary = .none }
                    } label: {
                        if primary == key {
                            Label(key.label, systemImage: "checkmark")
                        } else {
                            Text(key.label)
                        }
                    }
                }
            }
            if primary != .none {
                Section("Then by") {
                    ForEach(GroupKey.all.filter { $0 != primary }) { key in
                        Button {
                            secondary = key
                        } label: {
                            if secondary == key {
                                Label(key.label, systemImage: "checkmark")
                            } else {
                                Text(key.label)
                            }
                        }
                    }
                }
            }
        } label: {
            Label(menuLabel, systemImage: "rectangle.3.group")
        }
        .help("Group by")
    }

    private var menuLabel: String {
        if primary == .none { return "Group: None" }
        if secondary == .none { return "Group: \(primary.label)" }
        return "Group: \(primary.label) / \(secondary.label)"
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
