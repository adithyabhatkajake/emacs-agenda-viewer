import SwiftUI

struct GroupedTaskList<T: TaskDisplayable & Identifiable>: View where T.ID == String {
    let groups: [TaskGroup<T>]
    let secondaryKey: GroupKey
    let eisenhower: EisenhowerGroupContext?
    let doneStates: Set<String>
    let factory: RowActionFactory
    let selection: Selection
    let store: TasksStore
    @Binding var collapsed: Set<String>

    var body: some View {
        ForEach(groups) { group in
            if secondaryKey == .none {
                GroupSection(
                    label: group.label,
                    items: group.items,
                    doneStates: doneStates,
                    factory: factory,
                    selection: selection,
                    store: store,
                    collapsed: $collapsed
                )
            } else {
                primarySection(group)
            }
        }
    }

    @ViewBuilder
    private func primarySection(_ group: TaskGroup<T>) -> some View {
        let isCollapsed = group.label.isEmpty ? false : collapsed.contains("p:\(group.label)")
        VStack(alignment: .leading, spacing: 8) {
            if !group.label.isEmpty {
                Button {
                    let key = "p:\(group.label)"
                    if collapsed.contains(key) { collapsed.remove(key) }
                    else { collapsed.insert(key) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Theme.textTertiary)
                        Text(group.label)
                            .font(.system(size: 12, weight: .bold))
                            .tracking(0.6)
                            .textCase(.uppercase)
                            .foregroundStyle(Theme.textPrimary)
                        Text("\(group.items.count)")
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(Theme.textTertiary)
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
                .padding(.leading, 8)
            }
            if !isCollapsed {
                let subgroups = groupTasks(group.items, by: secondaryKey, eisenhower: eisenhower)
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(subgroups) { sub in
                        GroupSection(
                            label: sub.label,
                            items: sub.items,
                            doneStates: doneStates,
                            factory: factory,
                            selection: selection,
                            store: store,
                            collapsed: $collapsed
                        )
                        .padding(.leading, group.label.isEmpty ? 0 : 8)
                    }
                }
            }
        }
    }
}

struct GroupSection<T: TaskDisplayable & Identifiable>: View where T.ID == String {
    let label: String
    let items: [T]
    let doneStates: Set<String>
    let factory: RowActionFactory
    let selection: Selection
    let store: TasksStore
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
                    ForEach(items, id: \.id) { item in
                        let rowActions = factory.make(for: item)
                        if selection.taskId == item.id {
                            TaskExpandedCard(
                                store: store,
                                task: item,
                                actions: rowActions,
                                doneStates: doneStates
                            )
                            .id(item.id)
                        } else {
                            MacTaskRow(
                                task: item,
                                isClocked: factory.isClocked(item),
                                isSelected: false,
                                doneStates: doneStates,
                                actions: rowActions,
                                progress: factory.progress(for: item),
                                keywords: store.keywords,
                                onAppear: factory.prefetch(for: item)
                            )
                            .id(item.id)
                        }
                    }
                }
            }
        }
    }
}
