import SwiftUI

struct TaskPriorityPickerPopover: View {
    @Environment(AppSettings.self) private var settings
    @Binding var isPresented: Bool
    let currentPriority: String
    var priorities: OrgPriorities? = nil
    let onSelect: (String) -> Void

    private var priorityList: [String] {
        if let pr = priorities, !pr.all.isEmpty { return pr.all }
        return ["A", "B", "C", "D"]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("PRIORITY")
                .font(.system(size: 9, weight: .heavy)).tracking(0.6)
                .foregroundStyle(Theme.textTertiary)
                .padding(.bottom, 2)
            ForEach(priorityList, id: \.self) { letter in
                priorityRow(letter, isCurrent: letter == currentPriority.uppercased())
            }
            if !currentPriority.isEmpty {
                Divider().padding(.vertical, 2)
                Button {
                    onSelect("")
                    isPresented = false
                } label: {
                    Text("None")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(minWidth: 140)
    }

    private func priorityRow(_ letter: String, isCurrent: Bool) -> some View {
        Button {
            onSelect(letter)
            isPresented = false
        } label: {
            HStack(spacing: 8) {
                priorityBox(letter)
                Text("Priority \(letter)")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textPrimary)
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

    private func priorityBox(_ p: String) -> some View {
        Text(p.uppercased())
            .font(.system(size: 10, weight: .heavy, design: .monospaced))
            .foregroundStyle(.white)
            .frame(width: 16, height: 16)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(settings.resolvedPriorityColor(for: p))
            )
    }
}
