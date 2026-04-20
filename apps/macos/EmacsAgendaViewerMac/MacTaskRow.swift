import SwiftUI

struct TaskRowActions {
    var toggleDone: () -> Void = {}
    var setPriority: (String) -> Void = { _ in }
    var schedule: (Date?) -> Void = { _ in }
    var setDeadline: (Date?) -> Void = { _ in }
    var clockIn: () -> Void = {}
    var clockOut: () -> Void = {}
    var openInspector: () -> Void = {}
}

struct MacTaskRow: View {
    let task: any TaskDisplayable
    let isClocked: Bool
    let isSelected: Bool
    let doneStates: Set<String>
    let actions: TaskRowActions
    @State private var isHovering = false

    private var isDone: Bool {
        guard let state = task.todoState else { return false }
        return doneStates.contains(state.uppercased())
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            checkbox
                .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 2 }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(task.title)
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(isDone ? Theme.textTertiary : Theme.textPrimary)
                        .strikethrough(isDone, color: Theme.textTertiary)
                        .lineLimit(2)
                    if isClocked {
                        Image(systemName: "stopwatch.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.priorityB)
                    }
                }

                if hasMeta {
                    metaLine
                }
            }

            Spacer(minLength: 8)

            if !task.category.isEmpty {
                Text(task.category)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        Capsule(style: .continuous)
                            .strokeBorder(Theme.borderSubtle, lineWidth: 1)
                    )
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(rowBackground)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { actions.openInspector() }
        .contextMenu { contextMenuItems }
        .draggable(task.id) { dragPreview }
    }

    private var dragPreview: some View {
        HStack(spacing: 6) {
            Image(systemName: "circle").foregroundStyle(Theme.textTertiary)
            Text(task.title).lineLimit(1)
        }
        .padding(8)
        .background(Theme.surface)
        .cornerRadius(6)
        .frame(minWidth: 240)
    }

    private var rowBackground: Color {
        if isSelected { return Theme.accent.opacity(0.18) }
        if isHovering { return Theme.surface.opacity(0.6) }
        return .clear
    }

    private var hasMeta: Bool {
        task.scheduled != nil
            || task.deadline != nil
            || !task.tags.isEmpty
            || !task.inheritedTags.isEmpty
            || (task.todoState?.isEmpty == false)
            || (task.priority?.isEmpty == false)
    }

    @ViewBuilder
    private var metaLine: some View {
        HStack(spacing: 8) {
            if let state = task.todoState, !state.isEmpty {
                Text(state.uppercased())
                    .font(.system(size: 9.5, weight: .bold))
                    .tracking(0.7)
                    .foregroundStyle(stateColor(state))
            }

            if let priority = task.priority, !priority.isEmpty {
                HStack(spacing: 3) {
                    Circle()
                        .fill(Theme.priorityColor(priority))
                        .frame(width: 6, height: 6)
                    Text(priority.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.priorityColor(priority))
                }
            }

            if let scheduled = task.scheduled {
                metaDateLabel(scheduled, kind: .scheduled)
            }
            if let deadline = task.deadline {
                metaDateLabel(deadline, kind: .deadline)
            }

            ForEach(task.tags, id: \.self) { tag in
                tagChip(tag, inherited: false)
            }
            ForEach(task.inheritedTags.filter { !task.tags.contains($0) }, id: \.self) { tag in
                tagChip(tag, inherited: true)
            }
        }
    }

    private enum DateKind { case scheduled, deadline }

    @ViewBuilder
    private func metaDateLabel(_ ts: OrgTimestamp, kind: DateKind) -> some View {
        let date = ts.parsedDate
        let label = date.map { DateBadge.relativeLabel(for: $0) } ?? cleanRaw(ts.raw)
        let withTime = appendTime(label, ts: ts)
        HStack(spacing: 3) {
            Image(systemName: kind == .scheduled ? "calendar" : "exclamationmark.circle")
                .font(.system(size: 9.5, weight: .semibold))
            Text(withTime)
                .font(.system(size: 11))
        }
        .foregroundStyle(color(for: ts, kind: kind))
    }

    private func appendTime(_ label: String, ts: OrgTimestamp) -> String {
        guard let h = ts.start?.hour else { return label }
        let m = ts.start?.minute ?? 0
        return String(format: "%@ %d:%02d", label, h, m)
    }

    private func cleanRaw(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        let parts = trimmed.split(separator: " ").prefix(2)
        return parts.joined(separator: " ")
    }

    private func color(for ts: OrgTimestamp, kind: DateKind) -> Color {
        guard kind == .deadline, let date = ts.parsedDate else { return Theme.textSecondary }
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: date)).day ?? 0
        if days < 0 { return Theme.priorityA }
        if days <= 2 { return Theme.priorityB }
        return Theme.textSecondary
    }

    private func stateColor(_ state: String) -> Color {
        if isDone { return Theme.doneGreen }
        switch state.uppercased() {
        case "TODO": return Theme.accent
        case "NEXT", "STARTED", "DOING", "ACTV": return Theme.accentTeal
        case "WAIT", "WAITING", "HOLD", "BLOCKED", "SMDY": return Theme.priorityB
        case "CANCELLED", "CANCELED": return Theme.textTertiary
        default: return Theme.accent
        }
    }

    private func tagChip(_ tag: String, inherited: Bool) -> some View {
        Text(tag)
            .font(.system(size: 10))
            .foregroundStyle(inherited ? Theme.textTertiary : Theme.textSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule(style: .continuous)
                    .fill(Theme.surfaceElevated.opacity(inherited ? 0.4 : 0.7))
            )
    }

    @ViewBuilder
    private var checkbox: some View {
        let color: Color = isDone ? Theme.doneGreen : (isHovering ? Theme.textSecondary : Theme.textTertiary)
        Button(action: actions.toggleDone) {
            Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(color)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isDone ? "Mark as not done" : "Mark as done")
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        Button(isDone ? "Mark as Not Done" : "Mark as Done") { actions.toggleDone() }
        Divider()
        Menu("Priority") {
            ForEach(["A", "B", "C", "D"], id: \.self) { p in
                Button(p) { actions.setPriority(p) }
            }
            Divider()
            Button("None") { actions.setPriority("") }
        }
        Menu("Schedule") {
            Button("Today") { actions.schedule(Date()) }
            Button("Tomorrow") { actions.schedule(Calendar.current.date(byAdding: .day, value: 1, to: Date())) }
            Button("Next Week") { actions.schedule(Calendar.current.date(byAdding: .day, value: 7, to: Date())) }
            Divider()
            Button("Pick Date…") { actions.openInspector() }
            Divider()
            Button("Clear") { actions.schedule(nil) }
        }
        Menu("Deadline") {
            Button("Today") { actions.setDeadline(Date()) }
            Button("Tomorrow") { actions.setDeadline(Calendar.current.date(byAdding: .day, value: 1, to: Date())) }
            Button("Next Week") { actions.setDeadline(Calendar.current.date(byAdding: .day, value: 7, to: Date())) }
            Divider()
            Button("Pick Date…") { actions.openInspector() }
            Divider()
            Button("Clear") { actions.setDeadline(nil) }
        }
        Divider()
        if isClocked {
            Button("Clock Out") { actions.clockOut() }
        } else {
            Button("Clock In") { actions.clockIn() }
        }
        Divider()
        Button("Edit in Inspector") { actions.openInspector() }
    }
}
