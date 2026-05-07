import SwiftUI

struct TaskExpandedCard: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ClockManager.self) private var clocks
    @Environment(Selection.self) private var selection
    let store: TasksStore
    let task: any TaskDisplayable
    let actions: TaskRowActions
    var doneStates: Set<String> = []

    @State private var notesText: String = ""
    @State private var originalNotes: String = ""
    @State private var originalTitle: String = ""
    @State private var notesLoading = true
    @State private var notesEdited = false
    @State private var savingNotes = false
    @State private var titleText: String = ""
    @State private var outline: APIClient.OutlinePathResponse?
    @FocusState private var notesFocused: Bool
    @FocusState private var titleFocused: Bool

    @State private var scheduledPickerOpen = false
    @State private var deadlinePickerOpen = false
    @State private var tagsEditorOpen = false
    @State private var tagsDraft: String = ""
    @State private var priorityPickerOpen = false
    @State private var statePickerOpen = false

    private var isEditing: Bool { selection.editingTaskId == task.id }
    private var isDone: Bool {
        guard let s = task.todoState else { return false }
        return doneStates.contains(s.uppercased())
    }
    private var client: APIClient? { settings.apiClient }
    private var isClocked: Bool {
        if clocks.isClocked(taskId: task.id) { return true }
        return store.clock?.clocking == true
            && store.clock?.file == task.file
            && store.clock?.pos == task.pos
    }

    private var blocks: [NoteBlock] { NotesParser.parse(notesText) }

    private var hasVisibleNotes: Bool {
        blocks.contains { block in
            switch block {
            case .blank: return false
            default: return true
            }
        }
    }

    private var checklistProgress: ChecklistProgress? {
        ChecklistProgress.compute(from: notesText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            topRow
            outlineLine
            looseClocksBanner
            notesArea
            footer
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(alignment: .top) { progressLine }
        .contextMenu { cardContextMenu }
        .shadow(color: .black.opacity(0.06), radius: 14, x: 0, y: 4)
        .padding(.horizontal, 2)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .background(
            // Invisible Escape-key handler. A focusable Button with no label
            // catches the keyboard shortcut without affecting layout.
            Button("", action: dismissInspector)
                .keyboardShortcut(.escape, modifiers: [])
                .opacity(0)
                .frame(width: 0, height: 0)
        )
        .onAppear {
            titleText = task.title
            loadNotes()
            loadOutline()
        }
        .onChange(of: task.id) { _, _ in
            titleText = task.title
            selection.editingTaskId = nil
            loadNotes()
            loadOutline()
        }
    }

    @ViewBuilder
    private var outlineLine: some View {
        if let o = outline, !o.file.isEmpty {
            let parts = [o.file] + o.headings
            Text(parts.joined(separator: " ▸ "))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(parts.joined(separator: " ▸ "))
        }
    }

    @ViewBuilder
    private var progressLine: some View {
        if let p = checklistProgress {
            GeometryReader { geo in
                let doneW = geo.size.width * CGFloat(p.done)
                let ongoingW = geo.size.width * CGFloat(p.ongoing)
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Theme.textTertiary.opacity(0.18))
                    HStack(spacing: 0) {
                        Rectangle().fill(Theme.doneGreen).frame(width: doneW)
                        Rectangle().fill(Theme.priorityB.opacity(0.7)).frame(width: ongoingW)
                        Spacer(minLength: 0)
                    }
                }
            }
            .frame(height: 3)
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: 10,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: 10,
                    style: .continuous
                )
            )
        }
    }

    private var looseClockCount: Int {
        var count = 0
        var inDrawer = false
        for line in notesText.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(":LOGBOOK:") { inDrawer = true; continue }
            if trimmed.hasPrefix(":END:") { inDrawer = false; continue }
            if !inDrawer && trimmed.hasPrefix("CLOCK:") { count += 1 }
        }
        return count
    }

    @ViewBuilder
    private var looseClocksBanner: some View {
        let count = looseClockCount
        if count > 0 {
            HStack(spacing: 8) {
                Image(systemName: "clock.badge.exclamationmark")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.priorityB)
                Text("\(count) loose CLOCK \(count == 1 ? "entry" : "entries") outside :LOGBOOK:")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Button {
                    Task {
                        guard let client = settings.apiClient else { return }
                        await store.tidyClocks(file: task.file, pos: task.pos, using: client)
                        await MainActor.run {
                            // Refresh the visible notes too.
                            loadNotes()
                        }
                    }
                } label: {
                    Text("Tidy")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Theme.priorityB)
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Theme.priorityB.opacity(0.08))
            )
        }
    }

    @ViewBuilder
    private var cardContextMenu: some View {
        if !isEditing {
            Button("Edit") { startEditing() }
        }
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

    private func dismissInspector() {
        if notesEdited && !savingNotes {
            Task { await saveNotes() }
        }
        commitTitle()
        selection.editingTaskId = nil
        selection.taskId = nil
    }

    // MARK: - Top row: checkbox + state + priority + title

    @ViewBuilder
    private var topRow: some View {
        HStack(alignment: .center, spacing: 10) {
            checkbox
            statePillMenu
            priorityBoxMenu
            if isEditing {
                TextField("Title", text: $titleText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isDone ? Theme.textTertiary : Theme.textPrimary)
                    .focused($titleFocused)
                    .onSubmit { commitTitle() }
            } else {
                Text(titleText.isEmpty ? task.title : titleText)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isDone ? Theme.textTertiary : Theme.textPrimary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { dismissInspector() }
                    .help("Click to close")
            }
            if let scheduled = task.scheduled {
                scheduledInlineButton(scheduled)
            }
            if let deadline = task.deadline {
                deadlineInlineButton(deadline)
            }
        }
    }

    @ViewBuilder
    private var statePillMenu: some View {
        let current = task.todoState ?? ""
        Button {
            statePickerOpen.toggle()
        } label: {
            if current.isEmpty {
                Text("STATE")
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                    .tracking(0.5)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .strokeBorder(Theme.borderSubtle, lineWidth: 0.5)
                    )
            } else {
                statePill(current)
            }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $statePickerOpen, arrowEdge: .bottom) {
            stateChoicesPopover
        }
    }

    private var stateChoicesPopover: some View {
        let active = store.keywords?.allActive ?? ["TODO"]
        let done = store.keywords?.allDone ?? ["DONE"]
        let current = task.todoState ?? ""
        return VStack(alignment: .leading, spacing: 6) {
            if !active.isEmpty {
                Text("ACTIVE")
                    .font(.system(size: 9, weight: .heavy)).tracking(0.6)
                    .foregroundStyle(Theme.textTertiary)
                ForEach(active, id: \.self) { s in
                    stateChoiceRow(s, isCurrent: s.uppercased() == current.uppercased(), isDone: false)
                }
            }
            if !done.isEmpty {
                Text("DONE")
                    .font(.system(size: 9, weight: .heavy)).tracking(0.6)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.top, 4)
                ForEach(done, id: \.self) { s in
                    stateChoiceRow(s, isCurrent: s.uppercased() == current.uppercased(), isDone: true)
                }
            }
            if !current.isEmpty {
                Divider()
                Button {
                    actions.setState("")
                    statePickerOpen = false
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

    private func stateChoiceRow(_ state: String, isCurrent: Bool, isDone: Bool) -> some View {
        Button {
            actions.setState(state)
            statePickerOpen = false
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

    @ViewBuilder
    private var priorityBoxMenu: some View {
        let p = task.priority ?? ""
        Button {
            priorityPickerOpen.toggle()
        } label: {
            if p.isEmpty {
                Image(systemName: "flag")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 16, height: 16)
                    .background(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .strokeBorder(Theme.borderSubtle, lineWidth: 0.5)
                    )
            } else {
                priorityBox(p)
            }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $priorityPickerOpen, arrowEdge: .bottom) {
            priorityChoicesPopover
        }
    }

    private var priorityChoicesPopover: some View {
        let p = task.priority ?? ""
        return VStack(alignment: .leading, spacing: 4) {
            Text("PRIORITY")
                .font(.system(size: 9, weight: .heavy)).tracking(0.6)
                .foregroundStyle(Theme.textTertiary)
                .padding(.bottom, 2)
            ForEach(["A", "B", "C", "D"], id: \.self) { letter in
                priorityChoiceRow(letter, isCurrent: letter == p.uppercased())
            }
            if !p.isEmpty {
                Divider().padding(.vertical, 2)
                Button {
                    actions.setPriority("")
                    priorityPickerOpen = false
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

    private func priorityChoiceRow(_ letter: String, isCurrent: Bool) -> some View {
        Button {
            actions.setPriority(letter)
            priorityPickerOpen = false
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

    @ViewBuilder
    private func scheduledInlineButton(_ ts: OrgTimestamp) -> some View {
        let label = inlineDateLabel(ts)
        Button {
            scheduledPickerOpen.toggle()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "calendar")
                    .font(.system(size: 9.5, weight: .semibold))
                Text(label)
                    .font(.system(size: 11))
            }
            .foregroundStyle(Theme.priorityC)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Theme.priorityC.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Theme.priorityC.opacity(0.28), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $scheduledPickerOpen, arrowEdge: .bottom) {
            DatePickerPopover(
                initialDate: ts.parsedDate ?? Date(),
                initialHasTime: ts.hasTime,
                tint: Theme.accent,
                onSet: { date, hasTime, closing in
                    actions.scheduleAt(date, hasTime)
                    if closing { scheduledPickerOpen = false }
                },
                onClear: {
                    actions.scheduleAt(nil, false)
                    scheduledPickerOpen = false
                }
            )
        }
    }

    @ViewBuilder
    private func deadlineInlineButton(_ ts: OrgTimestamp) -> some View {
        let label = inlineDateLabel(ts)
        let tint = deadlineInlineTint(for: ts)
        Button {
            deadlinePickerOpen.toggle()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "flag.fill")
                    .font(.system(size: 9, weight: .semibold))
                Text(label)
                    .font(.system(size: 11))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(tint.opacity(0.14))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(tint.opacity(0.40), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $deadlinePickerOpen, arrowEdge: .bottom) {
            DatePickerPopover(
                initialDate: ts.parsedDate ?? Date(),
                initialHasTime: ts.hasTime,
                tint: Theme.priorityA,
                onSet: { date, hasTime, closing in
                    actions.setDeadlineAt(date, hasTime)
                    if closing { deadlinePickerOpen = false }
                },
                onClear: {
                    actions.setDeadlineAt(nil, false)
                    deadlinePickerOpen = false
                }
            )
        }
    }

    private func inlineDateLabel(_ ts: OrgTimestamp) -> String {
        guard let d = ts.parsedDate else { return ts.raw }
        var s = DateBadge.relativeLabel(for: d)
        if let h = ts.start?.hour {
            let m = ts.start?.minute ?? 0
            s += String(format: " %d:%02d", h, m)
        }
        return s
    }

    private func deadlineInlineTint(for ts: OrgTimestamp) -> Color {
        guard let d = ts.parsedDate else { return Theme.textSecondary }
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: d)).day ?? 0
        if days < 0 { return Theme.priorityA }
        if days <= 2 { return Theme.priorityB }
        return Theme.textSecondary
    }

    private func commitTitle() {
        let trimmed = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != task.title else { return }
        actions.saveTitle?(trimmed)
    }

    @ViewBuilder
    private var checkbox: some View {
        let color: Color = isDone ? Theme.doneGreen : Theme.textTertiary
        Button(action: actions.toggleDone) {
            Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(color)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isDone ? "Mark as not done" : "Mark as done")
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

    // MARK: - Notes area

    @ViewBuilder
    private var notesArea: some View {
        if notesLoading {
            HStack {
                Spacer()
                ProgressView().controlSize(.small)
                Spacer()
            }
            .padding(.vertical, 4)
        } else if isEditing {
            rawNotesEditor
        } else if hasVisibleNotes {
            NotesRenderedView(blocks: blocks, onToggleChecklist: toggleChecklist)
        } else {
            Text("No notes")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
        }
    }

    private var rawNotesEditor: some View {
        TextEditor(text: $notesText)
            .scrollContentBackground(.hidden)
            .font(.system(size: 13))
            .frame(minHeight: 60, maxHeight: 240)
            .focused($notesFocused)
            .onAppear { notesFocused = true }
            .onChange(of: notesText) { _, _ in notesEdited = true }
    }

    private func startEditing() {
        selection.editingTitle = task.title
        selection.editingTaskId = task.id
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        if isEditing {
            HStack(spacing: 8) {
                Spacer(minLength: 8)
                editFooterPill(text: "Discard", icon: "arrow.uturn.backward",
                               tint: Theme.textSecondary, action: discardEdits)
                editFooterPill(text: "Save", icon: "checkmark",
                               tint: Theme.accent, action: commitEdits)
                    .keyboardShortcut(.defaultAction)
            }
        } else {
            HStack(spacing: 10) {
                scheduledFooterChip
                Spacer(minLength: 8)
                clockFooterButton
                tagsFooterButton
                stateFooterButton
                deadlineFooterButton
                refileFooterButton
            }
        }
    }

    private func editFooterPill(text: String, icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                Text(text).font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous).fill(tint.opacity(0.12))
            )
        }
        .buttonStyle(.plain)
    }

    private var clockFooterButton: some View {
        Button {
            if isClocked { actions.clockOut() } else { actions.clockIn() }
        } label: {
            Image(systemName: isClocked ? "stop.circle.fill" : "play.circle")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(isClocked ? Theme.priorityA : Theme.textTertiary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isClocked ? "Clock out" : "Clock in")
    }

    private var scheduledFooterChip: some View {
        Button {
            scheduledPickerOpen.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: task.scheduled == nil ? "star" : "star.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(task.scheduled == nil ? Theme.textTertiary : Theme.priorityB)
                Text(scheduledLabel())
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(task.scheduled == nil ? Theme.textTertiary : Theme.textPrimary)
                if task.scheduled != nil {
                    Button {
                        actions.scheduleAt(nil, false)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear scheduled")
                }
            }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $scheduledPickerOpen, arrowEdge: .bottom) {
            DatePickerPopover(
                initialDate: task.scheduled?.parsedDate ?? Date(),
                initialHasTime: task.scheduled?.hasTime ?? false,
                tint: Theme.accent,
                onSet: { date, hasTime, closing in
                    actions.scheduleAt(date, hasTime)
                    if closing { scheduledPickerOpen = false }
                },
                onClear: {
                    actions.scheduleAt(nil, false)
                    scheduledPickerOpen = false
                }
            )
        }
    }

    private var tagsFooterButton: some View {
        Button {
            tagsDraft = task.tags.joined(separator: ", ")
            tagsEditorOpen.toggle()
        } label: {
            iconButtonLabel(icon: "tag", on: !task.tags.isEmpty)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $tagsEditorOpen, arrowEdge: .bottom) {
            tagsEditor
        }
    }

    private var tagsEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tags")
                .font(.system(size: 11, weight: .heavy)).tracking(0.6)
                .foregroundStyle(Theme.textSecondary)

            TextField("comma, separated, tags", text: $tagsDraft)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 240)
                .onSubmit { commitTags() }

            if !task.inheritedTags.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("INHERITED")
                        .font(.system(size: 9, weight: .heavy)).tracking(0.6)
                        .foregroundStyle(Theme.textTertiary)
                    HStack(spacing: 4) {
                        ForEach(task.inheritedTags, id: \.self) { tag in
                            Text("#\(tag)")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(Theme.textTertiary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .strokeBorder(Theme.borderSubtle, lineWidth: 0.5)
                                )
                        }
                    }
                }
            }

            HStack {
                Button("Cancel") { tagsEditorOpen = false }
                    .controlSize(.small)
                Spacer()
                Button("Save") { commitTags() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
    }

    private func commitTags() {
        let tags = tagsDraft
            .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\t" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        actions.setTags(tags)
        tagsEditorOpen = false
    }

    private var refileFooterButton: some View {
        Button {
            actions.refile()
        } label: {
            iconButtonLabel(icon: "tray.and.arrow.down", on: false)
        }
        .buttonStyle(.plain)
        .help("Refile…")
    }

    private var stateFooterButton: some View {
        Menu {
            let active = store.keywords?.allActive ?? ["TODO"]
            let done = store.keywords?.allDone ?? ["DONE"]
            Section("State") {
                ForEach(active, id: \.self) { s in
                    Button(s) { actions.setState(s) }
                }
            }
            Section("Done") {
                ForEach(done, id: \.self) { s in
                    Button(s) { actions.setState(s) }
                }
            }
            Divider()
            Section("Priority") {
                ForEach(["A", "B", "C", "D"], id: \.self) { p in
                    Button(p) { actions.setPriority(p) }
                }
                if task.priority?.isEmpty == false {
                    Divider()
                    Button("None") { actions.setPriority("") }
                }
            }
        } label: {
            iconButtonLabel(icon: "list.bullet", on: task.todoState?.isEmpty == false)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var deadlineFooterButton: some View {
        Button {
            deadlinePickerOpen.toggle()
        } label: {
            iconButtonLabel(icon: "flag", on: task.deadline != nil, tint: task.deadline != nil ? Theme.priorityA : nil)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $deadlinePickerOpen, arrowEdge: .bottom) {
            DatePickerPopover(
                initialDate: task.deadline?.parsedDate ?? Date(),
                initialHasTime: task.deadline?.hasTime ?? false,
                tint: Theme.priorityA,
                onSet: { date, hasTime, closing in
                    actions.setDeadlineAt(date, hasTime)
                    if closing { deadlinePickerOpen = false }
                },
                onClear: {
                    actions.setDeadlineAt(nil, false)
                    deadlinePickerOpen = false
                }
            )
        }
    }

    @ViewBuilder
    private func iconButtonLabel(icon: String, on: Bool, tint: Color? = nil) -> some View {
        let color = tint ?? (on ? Theme.textPrimary : Theme.textTertiary)
        Image(systemName: icon)
            .font(.system(size: 14, weight: .regular))
            .foregroundStyle(color)
            .frame(width: 26, height: 26)
            .contentShape(Rectangle())
    }

    // MARK: - Notes modes

    private var renderedNotes: some View {
        NotesRenderedView(blocks: blocks, onToggleChecklist: toggleChecklist)
    }

    private var rawEditor: some View {
        TextEditor(text: $notesText)
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .font(.system(size: 12, design: .monospaced))
            .frame(minHeight: 120)
            .padding(8)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(notesFocused ? Theme.accent : Theme.borderSubtle,
                                  lineWidth: notesFocused ? 1.5 : 1)
            )
            .focused($notesFocused)
            .onChange(of: notesText) { _, _ in notesEdited = true }
            .onChange(of: notesFocused) { _, focused in
                if !focused && notesEdited && !savingNotes {
                    Task { await saveNotes() }
                }
            }
    }

    private var emptyNotes: some View {
        Text("No notes. Click Edit to add.")
            .font(.system(size: 11))
            .foregroundStyle(Theme.textTertiary)
            .padding(.vertical, 2)
    }

    // MARK: - Action chips

    private var actionChips: some View {
        HStack(spacing: 8) {
            stateChip
            priorityChip
            scheduledChip
            deadlineChip
            clockChip
            Button {
                if isEditing {
                    actions.saveTitle?(selection.editingTitle)
                    if notesEdited { Task { await saveNotes() } }
                    selection.editingTaskId = nil
                } else {
                    selection.editingTitle = task.title
                    selection.editingTaskId = task.id
                }
            } label: {
                chipLabel(icon: isEditing ? "checkmark" : "pencil",
                          tint: isEditing ? Theme.accent : Theme.textSecondary,
                          text: isEditing ? "Done" : "Edit")
            }
            .buttonStyle(.plain)
            .keyboardShortcut("e", modifiers: .command)
            Spacer()
        }
    }

    private var stateChip: some View {
        let active = store.keywords?.allActive ?? ["TODO"]
        let done = store.keywords?.allDone ?? ["DONE"]
        let current = task.todoState ?? ""
        let isDone = done.map { $0.uppercased() }.contains(current.uppercased())
        return Menu {
            Section("Active") {
                ForEach(active, id: \.self) { s in
                    Button {
                        actions.setState(s)
                    } label: {
                        stateMenuLabel(s, done: false, isCurrent: s.uppercased() == current.uppercased())
                    }
                }
            }
            Section("Done") {
                ForEach(done, id: \.self) { s in
                    Button {
                        actions.setState(s)
                    } label: {
                        stateMenuLabel(s, done: true, isCurrent: s.uppercased() == current.uppercased())
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(current.isEmpty ? Theme.textTertiary : (isDone ? Theme.doneGreen : Theme.accent))
                    .frame(width: 7, height: 7)
                Text(current.isEmpty ? "State" : current)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Theme.surfaceElevated.opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Theme.borderSubtle, lineWidth: 1)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    @ViewBuilder
    private func stateMenuLabel(_ state: String, done: Bool, isCurrent: Bool) -> some View {
        HStack {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? Theme.doneGreen : Theme.accent)
            Text(state)
            if isCurrent {
                Image(systemName: "checkmark").font(.caption)
            }
        }
    }

    private var priorityChip: some View {
        Menu {
            ForEach(["A", "B", "C", "D"], id: \.self) { p in
                Button(p) { actions.setPriority(p) }
            }
            if task.priority?.isEmpty == false {
                Divider()
                Button("None") { actions.setPriority("") }
            }
        } label: {
            let p = task.priority ?? ""
            chipLabel(
                icon: "flag.fill",
                tint: settings.resolvedPriorityColor(for: p.isEmpty ? nil : p),
                text: p.isEmpty ? "Priority" : p
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var scheduledChip: some View {
        Menu {
            Button("Today") { actions.scheduleAt(Date(), false) }
            Button("Tomorrow") {
                actions.scheduleAt(Calendar.current.date(byAdding: .day, value: 1, to: Date()), false)
            }
            Button("Next Week") {
                actions.scheduleAt(Calendar.current.date(byAdding: .day, value: 7, to: Date()), false)
            }
            Divider()
            Button("Pick date & time…") {
                scheduledPickerOpen = true
            }
            if task.scheduled != nil {
                Divider()
                Button("Clear") { actions.scheduleAt(nil, false) }
            }
        } label: {
            chipLabel(
                icon: "calendar",
                tint: Theme.accent,
                text: scheduledLabel()
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .popover(isPresented: $scheduledPickerOpen, arrowEdge: .bottom) {
            DatePickerPopover(
                initialDate: task.scheduled?.parsedDate ?? Date(),
                initialHasTime: task.scheduled?.hasTime ?? false,
                tint: Theme.accent,
                onSet: { date, hasTime, closing in
                    actions.scheduleAt(date, hasTime)
                    if closing { scheduledPickerOpen = false }
                },
                onClear: {
                    actions.scheduleAt(nil, false)
                    scheduledPickerOpen = false
                }
            )
        }
    }

    private var deadlineChip: some View {
        Menu {
            Button("Today") { actions.setDeadlineAt(Date(), false) }
            Button("Tomorrow") {
                actions.setDeadlineAt(Calendar.current.date(byAdding: .day, value: 1, to: Date()), false)
            }
            Button("Next Week") {
                actions.setDeadlineAt(Calendar.current.date(byAdding: .day, value: 7, to: Date()), false)
            }
            Divider()
            Button("Pick date & time…") {
                deadlinePickerOpen = true
            }
            if task.deadline != nil {
                Divider()
                Button("Clear") { actions.setDeadlineAt(nil, false) }
            }
        } label: {
            chipLabel(
                icon: "flag.fill",
                tint: Theme.priorityA,
                text: deadlineLabel()
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .popover(isPresented: $deadlinePickerOpen, arrowEdge: .bottom) {
            DatePickerPopover(
                initialDate: task.deadline?.parsedDate ?? Date(),
                initialHasTime: task.deadline?.hasTime ?? false,
                tint: Theme.priorityA,
                onSet: { date, hasTime, closing in
                    actions.setDeadlineAt(date, hasTime)
                    if closing { deadlinePickerOpen = false }
                },
                onClear: {
                    actions.setDeadlineAt(nil, false)
                    deadlinePickerOpen = false
                }
            )
        }
    }

    @ViewBuilder
    private var clockChip: some View {
        Button {
            if isClocked { actions.clockOut() } else { actions.clockIn() }
        } label: {
            chipLabel(
                icon: isClocked ? "stop.circle.fill" : "play.circle",
                tint: isClocked ? Theme.priorityA : Theme.textSecondary,
                text: isClocked ? "Clock Out" : "Clock In"
            )
        }
        .buttonStyle(.plain)
    }

    private func chipLabel(icon: String, tint: Color, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Theme.surfaceElevated.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Theme.borderSubtle, lineWidth: 1)
        )
    }

    private func scheduledLabel() -> String {
        if let ts = task.scheduled, let d = ts.parsedDate {
            var s = DateBadge.relativeLabel(for: d)
            if let h = ts.start?.hour {
                let m = ts.start?.minute ?? 0
                s += String(format: " %d:%02d", h, m)
            }
            return s
        }
        return "Scheduled"
    }

    private func deadlineLabel() -> String {
        if let ts = task.deadline, let d = ts.parsedDate {
            return DateBadge.relativeLabel(for: d)
        }
        return "Deadline"
    }

    // MARK: - Actions

    private func loadNotes() {
        notesLoading = true
        notesText = ""
        notesEdited = false
        selection.editingTaskId = nil
        Task {
            guard let client else { notesLoading = false; return }
            let n = await store.loadNotes(file: task.file, pos: task.pos, using: client)
            await MainActor.run {
                notesText = n
                originalNotes = n
                originalTitle = task.title
                notesLoading = false
                notesEdited = false
            }
        }
    }

    private func commitEdits() {
        if titleText != originalTitle { commitTitle() }
        Task {
            if notesEdited { await saveNotes() }
            await MainActor.run {
                originalNotes = notesText
                originalTitle = titleText
                notesEdited = false
                selection.editingTaskId = nil
                notesFocused = false
                titleFocused = false
            }
        }
    }

    private func discardEdits() {
        notesText = originalNotes
        titleText = originalTitle
        notesEdited = false
        selection.editingTaskId = nil
        notesFocused = false
        titleFocused = false
    }

    private func loadOutline() {
        outline = nil
        let file = task.file
        let pos = task.pos
        Task {
            guard let client else { return }
            let o = try? await client.fetchOutlinePath(file: file, pos: pos)
            await MainActor.run {
                if file == task.file && pos == task.pos { outline = o }
            }
        }
    }

    private func toggleChecklist(lineIndex: Int) {
        guard let updated = NotesMutation.toggleChecklist(in: notesText, lineIndex: lineIndex) else { return }
        notesText = updated
        notesEdited = true
        Task { await saveNotes() }
    }

    private func saveNotes() async {
        guard let client else { return }
        savingNotes = true
        await store.setNotes(file: task.file, pos: task.pos, notes: notesText, using: client)
        savingNotes = false
        notesEdited = false
    }
}

struct DatePickerPopover: View {
    @State private var date: Date
    @State private var hasTime: Bool
    @State private var monthAnchor: Date
    @State private var query: String = ""
    let tint: Color
    /// Commit a new date. `closing` is true when the popover should auto-dismiss
    /// after this commit (e.g., picking a day, "Today", or "This Evening").
    /// Time-of-day adjustments stay open so the user can keep tweaking.
    let onSet: (_ date: Date, _ hasTime: Bool, _ closing: Bool) -> Void
    let onClear: () -> Void

    init(initialDate: Date, initialHasTime: Bool, tint: Color,
         onSet: @escaping (Date, Bool, Bool) -> Void, onClear: @escaping () -> Void) {
        _date = State(initialValue: initialDate)
        _hasTime = State(initialValue: initialHasTime)
        _monthAnchor = State(initialValue: initialDate)
        self.tint = tint
        self.onSet = onSet
        self.onClear = onClear
    }

    private var cal: Calendar { Calendar.current }
    private var todayStart: Date { cal.startOfDay(for: Date()) }

    var body: some View {
        VStack(spacing: 0) {
            whenField
                .padding(.top, 10)
                .padding(.horizontal, 12)
                .padding(.bottom, 6)

            quickRow(
                icon: "star.fill", iconTint: Color(red: 1.0, green: 0.78, blue: 0.18),
                label: "Today",
                checked: cal.isDate(date, inSameDayAs: todayStart),
                action: { selectDay(todayStart) }
            )
            quickRow(
                icon: "moon.fill", iconTint: Color(red: 0.45, green: 0.55, blue: 0.95),
                label: "This Evening",
                checked: hasTime && cal.isDate(date, inSameDayAs: todayStart) && eveningHour == cal.component(.hour, from: date),
                action: {
                    var comps = cal.dateComponents([.year, .month, .day], from: todayStart)
                    comps.hour = eveningHour; comps.minute = 0
                    if let d = cal.date(from: comps) { date = d; monthAnchor = d; hasTime = true; commit(closing: true) }
                }
            )

            monthHeader
                .padding(.top, 8)
                .padding(.horizontal, 12)
            weekHeader
                .padding(.horizontal, 12)
            monthGrid
                .padding(.horizontal, 12)
                .padding(.bottom, 4)

            quickRow(
                icon: "tray", iconTint: .white.opacity(0.6),
                label: "Someday",
                checked: false,
                action: { onClear() }
            )

            timeRow
                .padding(.horizontal, 12)
                .padding(.vertical, 6)

            Button(action: onClear) {
                Text("Clear")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.06))
            }
            .buttonStyle(.plain)
        }
        .frame(width: 220)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(red: 0.15, green: 0.15, blue: 0.17))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
        .colorScheme(.dark)
        .padding(2)
    }

    private var eveningHour: Int { 18 }

    private var whenField: some View {
        TextField("When", text: $query)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .onSubmit { applyQuery() }
    }

    private func applyQuery() {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        if q == "today" { selectDay(todayStart) }
        else if q == "tomorrow", let d = cal.date(byAdding: .day, value: 1, to: todayStart) { selectDay(d) }
        else if q == "next week", let d = cal.date(byAdding: .day, value: 7, to: todayStart) { selectDay(d) }
    }

    private var monthHeader: some View {
        HStack(spacing: 6) {
            Button { shiftMonth(-1) } label: {
                Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.7))
            Text(monthLabel)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(maxWidth: .infinity)
            Button { shiftMonth(1) } label: {
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.7))
        }
        .padding(.bottom, 4)
    }

    private var monthLabel: String {
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return f.string(from: monthAnchor)
    }

    private func shiftMonth(_ delta: Int) {
        if let d = cal.date(byAdding: .month, value: delta, to: monthAnchor) { monthAnchor = d }
    }

    private var weekHeader: some View {
        HStack(spacing: 0) {
            ForEach(["Sun","Mon","Tue","Wed","Thu","Fri","Sat"], id: \.self) { d in
                Text(d)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.bottom, 2)
    }

    private var monthGrid: some View {
        let days = monthDays
        return VStack(spacing: 2) {
            ForEach(0..<6, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { col in
                        let idx = row * 7 + col
                        if idx < days.count, let d = days[idx] {
                            dayCell(d)
                        } else {
                            Color.clear.frame(maxWidth: .infinity).frame(height: 22)
                        }
                    }
                }
            }
        }
    }

    private var monthDays: [Date?] {
        let firstOfMonth = cal.date(from: cal.dateComponents([.year, .month], from: monthAnchor)) ?? monthAnchor
        let weekdayOfFirst = cal.component(.weekday, from: firstOfMonth) // 1=Sun
        let leading = weekdayOfFirst - 1
        let range = cal.range(of: .day, in: .month, for: firstOfMonth) ?? 1..<31
        var out: [Date?] = Array(repeating: nil, count: leading)
        for day in range {
            var comps = cal.dateComponents([.year, .month], from: firstOfMonth)
            comps.day = day
            out.append(cal.date(from: comps))
        }
        while out.count < 42 { out.append(nil) }
        return out
    }

    private func dayCell(_ d: Date) -> some View {
        let isSelected = cal.isDate(d, inSameDayAs: date)
        let isToday = cal.isDate(d, inSameDayAs: todayStart)
        let label = String(cal.component(.day, from: d))
        return Button {
            selectDay(d)
        } label: {
            ZStack {
                if isSelected {
                    Circle().fill(tint).frame(width: 22, height: 22)
                }
                if isToday && !isSelected {
                    Image(systemName: "star.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(red: 1.0, green: 0.78, blue: 0.18).opacity(0.85))
                        .offset(y: -1)
                } else {
                    Text(label)
                        .font(.system(size: 11, weight: isToday ? .bold : .regular))
                        .foregroundStyle(isSelected ? Color.white : .white.opacity(0.85))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func selectDay(_ d: Date) {
        var newDate = d
        if hasTime, let h = cal.dateComponents([.hour, .minute], from: date).hour {
            var comps = cal.dateComponents([.year, .month, .day], from: d)
            comps.hour = h
            comps.minute = cal.component(.minute, from: date)
            newDate = cal.date(from: comps) ?? d
        }
        date = newDate
        monthAnchor = newDate
        commit(closing: true)
    }

    private func commit(closing: Bool = false) {
        onSet(date, hasTime, closing)
    }

    @ViewBuilder
    private func quickRow(icon: String, iconTint: Color, label: String, checked: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(iconTint)
                    .frame(width: 14)
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                Spacer()
                if checked {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(checked ? Color.white.opacity(0.06) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var timeRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.55))
            if hasTime {
                DatePicker("", selection: $date, displayedComponents: [.hourAndMinute])
                    .labelsHidden()
                    .datePickerStyle(.compact)
                    .fixedSize()
                    .onChange(of: date) { _, _ in commit(closing: false) }
                Spacer()
                Button {
                    hasTime = false
                    commit(closing: false)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
                .help("Remove time")
            } else {
                Button {
                    var comps = cal.dateComponents([.year, .month, .day], from: date)
                    let now = cal.dateComponents([.hour, .minute], from: Date())
                    comps.hour = now.hour
                    comps.minute = (now.minute ?? 0) < 30 ? 30 : 0
                    if (comps.minute ?? 0) == 0 { comps.hour = (comps.hour ?? 0) + 1 }
                    if let d = cal.date(from: comps) { date = d }
                    hasTime = true
                    commit(closing: false)
                } label: {
                    Text("Add time")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
                Spacer()
            }
        }
    }
}
