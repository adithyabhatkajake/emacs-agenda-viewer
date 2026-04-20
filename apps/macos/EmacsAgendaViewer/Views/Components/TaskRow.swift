import SwiftUI

struct TaskRow: View {
    let task: any TaskDisplayable
    let doneStates: Set<String>

    private var isDone: Bool {
        guard let state = task.todoState else { return false }
        return doneStates.contains(state.uppercased())
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            checkbox
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if let state = task.todoState, !state.isEmpty {
                        TodoStatePill(state: state, isDone: isDone)
                    }
                    if let priority = task.priority, !priority.isEmpty {
                        PriorityBadge(priority: priority)
                    }
                    Text(task.title)
                        .font(.body)
                        .foregroundStyle(isDone ? Theme.textTertiary : Theme.textPrimary)
                        .strikethrough(isDone, color: Theme.textTertiary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }

                let hasMeta = task.scheduled != nil || task.deadline != nil || !task.tags.isEmpty || !task.inheritedTags.isEmpty || !task.category.isEmpty
                if hasMeta {
                    HStack(spacing: 8) {
                        if !task.category.isEmpty {
                            Text(task.category)
                                .font(.caption2)
                                .foregroundStyle(Theme.textTertiary)
                        }
                        if let scheduled = task.scheduled {
                            DateBadge(timestamp: scheduled, kind: .scheduled)
                        }
                        if let deadline = task.deadline {
                            DateBadge(timestamp: deadline, kind: .deadline)
                        }
                        TagChips(tags: task.tags, inheritedTags: task.inheritedTags)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var checkbox: some View {
        let color: Color = isDone ? Theme.doneGreen : Theme.textTertiary
        Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 18, weight: .regular))
            .foregroundStyle(color)
    }
}
