import SwiftUI

struct TaskRowActions {
    var toggleDone: () -> Void = {}
    var setPriority: (String) -> Void = { _ in }
    var setState: (String) -> Void = { _ in }
    var schedule: (Date?) -> Void = { _ in }
    var setDeadline: (Date?) -> Void = { _ in }
    var scheduleAt: (Date?, Bool) -> Void = { _, _ in }
    var setDeadlineAt: (Date?, Bool) -> Void = { _, _ in }
    var clockIn: () -> Void = {}
    var clockOut: () -> Void = {}
    var openInspector: () -> Void = {}
    var refile: () -> Void = {}
    var setTags: ([String]) -> Void = { _ in }
    var saveTitle: ((String) -> Void)?
}

struct MacTaskRow: View {
    @Environment(AppSettings.self) private var settings
    @Environment(Selection.self) private var selection
    let task: any TaskDisplayable
    let isClocked: Bool
    let isSelected: Bool
    let doneStates: Set<String>
    let actions: TaskRowActions
    var progress: (done: Int, ongoing: Int, total: Int)? = nil
    var onAppear: (() -> Void)? = nil
    @State private var isHovering = false
    @FocusState private var titleFieldFocused: Bool

    private var isDone: Bool {
        guard let state = task.todoState else { return false }
        return doneStates.contains(state.uppercased())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if settings.rowProgressStyle == .line { progressLine }
            HStack(alignment: .top, spacing: 12) {
                checkbox
                    .padding(.top, 1)

                titleRow
                    .frame(maxWidth: .infinity, alignment: .leading)

                if settings.rowProgressStyle == .circle, progress != nil {
                    progressCircle
                }
            }
            .padding(.vertical, 9)
            .padding(.horizontal, 14)
        }
        .padding(0)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(rowBackground)
                if settings.rowProgressStyle == .background {
                    progressBackground
                }
                if let tintBg = highlightTintBackground {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(tintBg)
                }
            }
        )
        .overlay(alignment: .leading) {
            if let edge = highlightEdgeColor {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(edge)
                    .frame(width: 3)
                    .padding(.vertical, 4)
                    .padding(.leading, 2)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { actions.openInspector() }
        .contextMenu { contextMenuItems }
        .draggable(task.id) { dragPreview }
        .onAppear { onAppear?() }
    }

    @ViewBuilder
    private var progressCircle: some View {
        if let p = progress, p.total > 0 {
            let fraction = CGFloat(p.done) / CGFloat(p.total)
            let ongoingFrac = CGFloat(p.ongoing) / CGFloat(p.total)
            ZStack {
                Circle()
                    .stroke(Theme.textTertiary.opacity(0.25), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: fraction + ongoingFrac)
                    .stroke(Theme.priorityB.opacity(0.7), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(Theme.doneGreen, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 14, height: 14)
            .help("\(p.done)/\(p.total) complete")
        }
    }

    @ViewBuilder
    private var progressBackground: some View {
        if let p = progress, p.total > 0 {
            let total = CGFloat(p.total)
            let doneFrac = CGFloat(p.done) / total
            let ongoingFrac = CGFloat(p.ongoing) / total
            GeometryReader { geo in
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(Theme.doneGreen.opacity(0.12))
                        .frame(width: geo.size.width * doneFrac)
                    Rectangle()
                        .fill(Theme.priorityB.opacity(0.10))
                        .frame(width: geo.size.width * ongoingFrac)
                    Spacer(minLength: 0)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    @ViewBuilder
    private var progressLine: some View {
        if let p = progress, p.total > 0 {
            GeometryReader { geo in
                let total = CGFloat(p.total)
                let doneW = geo.size.width * CGFloat(p.done) / total
                let ongoingW = geo.size.width * CGFloat(p.ongoing) / total
                ZStack(alignment: .leading) {
                    Rectangle().fill(Theme.textTertiary.opacity(0.18))
                    HStack(spacing: 0) {
                        Rectangle().fill(Theme.doneGreen).frame(width: doneW)
                        Rectangle().fill(Theme.priorityB.opacity(0.7)).frame(width: ongoingW)
                        Spacer(minLength: 0)
                    }
                }
            }
            .frame(height: 2)
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: 6,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: 6,
                    style: .continuous
                )
            )
            .padding(.horizontal, 1)
        }
    }

    private var highlightColor: Color? {
        let _ = settings.colorRevision
        switch settings.rowHighlightMode {
        case .none:
            return nil
        case .priority:
            guard let p = task.priority, !p.isEmpty else { return nil }
            return settings.resolvedPriorityColor(for: p)
        case .todoState:
            guard let s = task.todoState, !s.isEmpty else { return nil }
            return settings.resolvedTodoStateColor(for: s, isDone: isDone)
        }
    }

    private var highlightEdgeColor: Color? {
        guard settings.rowHighlightStyle == .edgeBar else { return nil }
        return highlightColor
    }

    private var highlightTintBackground: Color? {
        guard settings.rowHighlightStyle == .backgroundTint else { return nil }
        guard let c = highlightColor else { return nil }
        return c.opacity(isSelected ? 0.18 : 0.10)
    }

    @ViewBuilder
    private var titleRow: some View {
        HStack(alignment: .center, spacing: 6) {
            if let state = task.todoState, !state.isEmpty {
                statePill(state)
            }
            if let priority = task.priority, !priority.isEmpty {
                priorityBox(priority)
            }
            titleContent
            if let scheduled = task.scheduled {
                metaDateLabel(scheduled, kind: .scheduled)
            }
            if let deadline = task.deadline {
                metaDateLabel(deadline, kind: .deadline)
            }
            if isClocked {
                Image(systemName: "stopwatch.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.priorityB)
            }
            Spacer(minLength: 6)
            if !task.tags.isEmpty || !task.inheritedTags.isEmpty {
                HStack(spacing: 4) {
                    ForEach(task.tags, id: \.self) { tag in
                        tagChip(tag, inherited: false)
                    }
                    ForEach(task.inheritedTags.filter { !task.tags.contains($0) }, id: \.self) { tag in
                        tagChip(tag, inherited: true)
                    }
                }
            }
            if !task.category.isEmpty {
                categoryPill(task.category)
            }
        }
    }

    @ViewBuilder
    private var titleContent: some View {
        if selection.editingTaskId == task.id {
            @Bindable var sel = selection
            TextField("Title", text: $sel.editingTitle)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .regular))
                .focused($titleFieldFocused)
                .onAppear { titleFieldFocused = true }
                .onSubmit { actions.saveTitle?(selection.editingTitle) }
        } else {
            Text(task.title)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(isDone ? Theme.textTertiary : Theme.textPrimary)
                .strikethrough(isDone, color: Theme.textTertiary)
                .lineLimit(2)
        }
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

    private enum DateKind { case scheduled, deadline }

    private enum DeadlineSeverity { case overdue, soon, normal }

    @ViewBuilder
    private func metaDateLabel(_ ts: OrgTimestamp, kind: DateKind) -> some View {
        let date = ts.parsedDate
        let label = date.map { DateBadge.relativeLabel(for: $0) } ?? cleanRaw(ts.raw)
        let withTime = appendTime(label, ts: ts)

        switch kind {
        case .scheduled:
            scheduledPill(text: withTime)
        case .deadline:
            deadlinePill(text: withTime, severity: deadlineSeverity(for: ts))
        }
    }

    @ViewBuilder
    private func scheduledPill(text: String) -> some View {
        let tint = Theme.priorityC // accent-blue
        HStack(spacing: 3) {
            Image(systemName: "calendar")
                .font(.system(size: 9.5, weight: .semibold))
            Text(text)
                .font(.system(size: 11))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(tint.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(tint.opacity(0.28), lineWidth: 0.5)
        )
    }

    private func deadlineStyle(_ severity: DeadlineSeverity) -> (Color, Double, Double) {
        switch severity {
        case .overdue: return (Theme.priorityA, 0.14, 0.40)
        case .soon: return (Theme.priorityB, 0.14, 0.40)
        case .normal: return (Theme.textSecondary, 0.12, 0.28)
        }
    }

    @ViewBuilder
    private func deadlinePill(text: String, severity: DeadlineSeverity) -> some View {
        let (tint, bgOpacity, borderOpacity) = deadlineStyle(severity)
        HStack(spacing: 3) {
            Image(systemName: "flag.fill")
                .font(.system(size: 9, weight: .semibold))
            Text(text)
                .font(.system(size: 11))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(tint.opacity(bgOpacity))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(tint.opacity(borderOpacity), lineWidth: 0.5)
        )
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

    private func deadlineSeverity(for ts: OrgTimestamp) -> DeadlineSeverity {
        guard let date = ts.parsedDate else { return .normal }
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: date)).day ?? 0
        if days < 0 { return .overdue }
        if days <= 2 { return .soon }
        return .normal
    }

    @ViewBuilder
    private func statePill(_ state: String) -> some View {
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
    }

    @ViewBuilder
    private func priorityBox(_ priority: String) -> some View {
        Text(priority.uppercased())
            .font(.system(size: 10, weight: .heavy, design: .monospaced))
            .foregroundStyle(.white)
            .frame(width: 16, height: 16)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(settings.resolvedPriorityColor(for: priority))
            )
            .help("Priority \(priority.uppercased())")
    }

    @ViewBuilder
    private func categoryPill(_ category: String) -> some View {
        Text(category.uppercased())
            .font(.system(size: 10, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(
                Capsule(style: .continuous)
                    .fill(Theme.textSecondary.opacity(0.10))
            )
    }

    private func tagChip(_ tag: String, inherited: Bool) -> some View {
        Text("#\(tag)")
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(Theme.textTertiary.opacity(inherited ? 0.7 : 1.0))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Theme.borderSubtle, lineWidth: 0.5)
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
            Button("Clear") { actions.schedule(nil) }
        }
        Menu("Deadline") {
            Button("Today") { actions.setDeadline(Date()) }
            Button("Tomorrow") { actions.setDeadline(Calendar.current.date(byAdding: .day, value: 1, to: Date())) }
            Button("Next Week") { actions.setDeadline(Calendar.current.date(byAdding: .day, value: 7, to: Date())) }
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
        Button("Refile…") { actions.refile() }
    }
}
