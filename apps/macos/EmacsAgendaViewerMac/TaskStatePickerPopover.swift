import SwiftUI

struct TaskStatePickerPopover: View {
    @Environment(AppSettings.self) private var settings
    @Binding var isPresented: Bool
    let activeStates: [String]
    let doneStates: [String]
    let currentState: String
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !activeStates.isEmpty {
                Text("ACTIVE")
                    .font(.system(size: 9, weight: .heavy)).tracking(0.6)
                    .foregroundStyle(Theme.textTertiary)
                ForEach(activeStates, id: \.self) { s in
                    stateRow(s, isCurrent: s.uppercased() == currentState.uppercased(), isDone: false)
                }
            }
            if !doneStates.isEmpty {
                Text("DONE")
                    .font(.system(size: 9, weight: .heavy)).tracking(0.6)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.top, 4)
                ForEach(doneStates, id: \.self) { s in
                    stateRow(s, isCurrent: s.uppercased() == currentState.uppercased(), isDone: true)
                }
            }
            if !currentState.isEmpty {
                Divider()
                Button {
                    onSelect("")
                    isPresented = false
                } label: {
                    Text("Clear state")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.priorityA)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(minWidth: 160)
    }

    private func stateRow(_ state: String, isCurrent: Bool, isDone: Bool) -> some View {
        Button {
            onSelect(state)
            isPresented = false
        } label: {
            HStack(spacing: 8) {
                let _ = settings.colorRevision
                let color = settings.resolvedTodoStateColor(for: state, isDone: isDone)
                Text(state.uppercased())
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                    .tracking(0.5)
                    .foregroundStyle(color)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(color.opacity(0.14))
                    )
                Spacer()
                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.accent)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
