import SwiftUI

struct GroupSection<T: TaskDisplayable & Identifiable>: View where T.ID == String {
    let label: String
    let items: [T]
    let doneStates: Set<String>
    let factory: RowActionFactory
    let selection: Selection
    /// Set of group labels currently collapsed. Sections without a label are
    /// never collapsible (no header is shown).
    @Binding var collapsed: Set<String>

    private var isCollapsible: Bool { !label.isEmpty }
    private var isCollapsed: Bool { collapsed.contains(label) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isCollapsible {
                Button {
                    if isCollapsed { collapsed.remove(label) }
                    else { collapsed.insert(label) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                        Text(label)
                            .font(.system(size: 11, weight: .semibold))
                            .tracking(0.6)
                            .textCase(.uppercase)
                            .foregroundStyle(Theme.textSecondary)
                        Text("\(items.count)")
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(Theme.textTertiary)
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
                .padding(.leading, 14)
                .padding(.bottom, 2)
            }
            if !isCollapsed {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                        MacTaskRow(
                            task: item,
                            isClocked: factory.isClocked(item),
                            isSelected: selection.taskId == item.id,
                            doneStates: doneStates,
                            actions: factory.make(for: item)
                        )
                        if idx < items.count - 1 {
                            Divider()
                                .background(Theme.borderSubtle)
                                .padding(.leading, 42)
                        }
                    }
                }
            }
        }
    }
}
