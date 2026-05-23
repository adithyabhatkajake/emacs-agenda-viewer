import SwiftUI

struct TaskRow: View {
    let task: any TaskDisplayable
    let doneStates: Set<String>
    /// When non-nil, the checkbox becomes tappable and calls this to toggle
    /// the task's done state. Parents that don't want a tappable checkbox
    /// (e.g. read-only previews) leave this nil.
    var onToggleDone: (() -> Void)? = nil
    /// Caller-side flag for layouts that render the checkbox externally
    /// (outside a NavigationLink, so taps aren't swallowed by the link).
    /// When false, this row skips the checkbox entirely.
    var showsCheckbox: Bool = true

    private var isDone: Bool {
        guard let state = task.todoState else { return false }
        return doneStates.contains(state.uppercased())
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if showsCheckbox {
                checkbox
                    .padding(.top, 3)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if let state = task.todoState, !state.isEmpty {
                        TodoStatePill(state: state, isDone: isDone)
                    }
                    if let priority = task.priority, !priority.isEmpty {
                        PriorityBadge(priority: priority)
                    }
                    // Render org-mode emphasis in the title (same renderer
                    // as notes). `isDone` still applies a strike on top.
                    Text(renderInline(task.title))
                        .font(.body)
                        .foregroundStyle(isDone ? Theme.textTertiary : Theme.textPrimary)
                        .strikethrough(isDone, color: Theme.textTertiary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }

                let repeatLabel = RepeaterFormatter.label(task.scheduled?.repeater ?? task.deadline?.repeater)
                let hasMeta = task.scheduled != nil || task.deadline != nil
                    || !task.tags.isEmpty || !task.inheritedTags.isEmpty
                    || !task.category.isEmpty || repeatLabel != nil
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
                        if let repeatLabel {
                            HStack(spacing: 2) {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .accessibilityHidden(true)
                                Text(repeatLabel)
                            }
                            .font(.caption2)
                            .foregroundStyle(Theme.textTertiary)
                        }
                        TagChips(tags: task.tags, inheritedTags: task.inheritedTags)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(rowAccessibilityLabel)
    }

    private var rowAccessibilityLabel: String {
        var parts: [String] = []

        if let state = task.todoState, !state.isEmpty {
            parts.append("State: \(state)")
        }
        if let priority = task.priority, !priority.isEmpty {
            parts.append("Priority \(priority.uppercased())")
        }
        parts.append(task.title)

        if let scheduled = task.scheduled, let date = scheduled.parsedDate {
            parts.append("Scheduled: \(DateBadge.relativeLabel(for: date))")
        }
        if let deadline = task.deadline, let date = deadline.parsedDate {
            parts.append("Deadline: \(DateBadge.relativeLabel(for: date))")
        }

        let allTags = task.tags + task.inheritedTags.filter { !task.tags.contains($0) }
        if !allTags.isEmpty {
            parts.append("\(allTags.count == 1 ? "1 tag" : "\(allTags.count) tags"): \(allTags.joined(separator: ", "))")
        }

        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private var checkbox: some View {
        let color: Color = isDone ? Theme.doneGreen : Theme.textTertiary
        let image = Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 18, weight: .regular))
            .foregroundStyle(color)

        if let onToggleDone {
            // `.buttonStyle(.borderless)` is the canonical way to make a
            // Button intercept its own taps when it lives inside a
            // NavigationLink's label or a List row — `.plain` lets the
            // surrounding link claim the tap, so the checkbox would do
            // nothing (and the user would just be pushing the detail view).
            Button(action: onToggleDone) {
                image
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(isDone ? "Mark \(task.title) as not done" : "Mark \(task.title) as done")
        } else {
            image
                .accessibilityHidden(true)
        }
    }
}
