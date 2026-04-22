import SwiftUI

struct TaskExpandedCard: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ClockManager.self) private var clocks
    let store: TasksStore
    let task: any TaskDisplayable
    let actions: TaskRowActions

    @State private var notesText: String = ""
    @State private var notesLoading = true
    @State private var notesEdited = false
    @State private var notesEditing = false
    @State private var savingNotes = false
    @FocusState private var notesFocused: Bool

    @State private var scheduledPickerOpen = false
    @State private var scheduledPickerDate: Date = Date()
    @State private var scheduledPickerHasTime: Bool = false
    @State private var deadlinePickerOpen = false
    @State private var deadlinePickerDate: Date = Date()
    @State private var deadlinePickerHasTime: Bool = false

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

    private var checklistProgress: (done: Int, ongoing: Int, total: Int)? {
        var done = 0, ongoing = 0, total = 0
        for b in blocks {
            if case .checklist(_, _, let state, _, _) = b {
                total += 1
                switch state {
                case .done: done += 1
                case .ongoing: ongoing += 1
                case .notStarted: break
                }
            }
        }
        return total == 0 ? nil : (done, ongoing, total)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            actionChips
            Divider().background(Theme.borderSubtle)
            notesHeader
            if notesLoading {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else if notesEditing {
                rawEditor
            } else if !hasVisibleNotes {
                emptyNotes
            } else {
                renderedNotes
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.surface.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Theme.borderSubtle, lineWidth: 1)
        )
        .padding(.leading, 42)
        .padding(.trailing, 6)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .onAppear { loadNotes() }
        .onChange(of: task.id) { _, _ in loadNotes() }
    }

    // MARK: - Header

    private var notesHeader: some View {
        HStack(spacing: 8) {
            Text("NOTES")
                .font(.system(size: 9, weight: .bold))
                .tracking(0.7)
                .foregroundStyle(Theme.textTertiary)

            if let p = checklistProgress {
                progressBar(done: p.done, ongoing: p.ongoing, total: p.total)
                    .frame(maxWidth: 180)
                Text("\(p.done)/\(p.total)")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
            }

            Spacer()

            if notesEdited && !notesEditing {
                Circle().fill(Theme.priorityB).frame(width: 6, height: 6)
                    .help("Unsaved changes")
            }

            Button {
                if notesEditing {
                    // Leaving edit mode: save if needed.
                    if notesEdited { Task { await saveNotes() } }
                    notesEditing = false
                } else {
                    notesEditing = true
                }
            } label: {
                Image(systemName: notesEditing ? "checkmark" : "pencil")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 22, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Theme.surfaceElevated)
                    )
            }
            .buttonStyle(.plain)
            .help(notesEditing ? "Finish editing" : "Edit raw notes")
            .keyboardShortcut("e", modifiers: .command)
        }
    }

    @ViewBuilder
    private func progressBar(done: Int, ongoing: Int, total: Int) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            let doneW = total == 0 ? 0 : w * CGFloat(done) / CGFloat(total)
            let ongoingW = total == 0 ? 0 : w * CGFloat(ongoing) / CGFloat(total)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Theme.surfaceElevated)
                    .overlay(
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .strokeBorder(Theme.borderSubtle, lineWidth: 0.5)
                    )
                HStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Theme.doneGreen)
                        .frame(width: doneW)
                    Rectangle()
                        .fill(Theme.priorityB)
                        .frame(width: ongoingW)
                }
                .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
            }
        }
        .frame(height: 5)
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
        Text("No notes. Click the pencil to add.")
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
                tint: Theme.priorityColor(p.isEmpty ? nil : p),
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
                scheduledPickerDate = task.scheduled?.parsedDate ?? Date()
                scheduledPickerHasTime = task.scheduled?.hasTime ?? false
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
            datePickerPopover(
                date: $scheduledPickerDate,
                hasTime: $scheduledPickerHasTime,
                tint: Theme.accent,
                onSet: {
                    actions.scheduleAt(scheduledPickerDate, scheduledPickerHasTime)
                    scheduledPickerOpen = false
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
                deadlinePickerDate = task.deadline?.parsedDate ?? Date()
                deadlinePickerHasTime = task.deadline?.hasTime ?? false
                deadlinePickerOpen = true
            }
            if task.deadline != nil {
                Divider()
                Button("Clear") { actions.setDeadlineAt(nil, false) }
            }
        } label: {
            chipLabel(
                icon: "exclamationmark.circle",
                tint: Theme.priorityA,
                text: deadlineLabel()
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .popover(isPresented: $deadlinePickerOpen, arrowEdge: .bottom) {
            datePickerPopover(
                date: $deadlinePickerDate,
                hasTime: $deadlinePickerHasTime,
                tint: Theme.priorityA,
                onSet: {
                    actions.setDeadlineAt(deadlinePickerDate, deadlinePickerHasTime)
                    deadlinePickerOpen = false
                },
                onClear: {
                    actions.setDeadlineAt(nil, false)
                    deadlinePickerOpen = false
                }
            )
        }
    }

    @ViewBuilder
    private func datePickerPopover(
        date: Binding<Date>,
        hasTime: Binding<Bool>,
        tint: Color,
        onSet: @escaping () -> Void,
        onClear: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            DatePicker(
                "",
                selection: date,
                displayedComponents: [.date]
            )
            .labelsHidden()
            .datePickerStyle(.graphical)
            .frame(width: 260)

            HStack(spacing: 8) {
                Image(systemName: "clock")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                if hasTime.wrappedValue {
                    DatePicker(
                        "",
                        selection: date,
                        displayedComponents: [.hourAndMinute]
                    )
                    .labelsHidden()
                    .datePickerStyle(.compact)
                    Button {
                        hasTime.wrappedValue = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove time")
                } else {
                    Button("Add time") {
                        // Default to the next round half hour.
                        let cal = Calendar.current
                        var comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date.wrappedValue)
                        let base = cal.dateComponents([.year, .month, .day], from: date.wrappedValue)
                        let now = cal.dateComponents([.hour, .minute], from: Date())
                        comps.hour = now.hour
                        comps.minute = (now.minute ?? 0) < 30 ? 30 : 0
                        if (comps.minute ?? 0) == 0 { comps.hour = (comps.hour ?? 0) + 1 }
                        comps.year = base.year; comps.month = base.month; comps.day = base.day
                        if let d = cal.date(from: comps) { date.wrappedValue = d }
                        hasTime.wrappedValue = true
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
                Spacer()
            }

            HStack {
                Button("Clear", role: .destructive) { onClear() }
                    .controlSize(.small)
                Spacer()
                Button("Set") { onSet() }
                    .buttonStyle(.borderedProminent)
                    .tint(tint)
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
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
        notesEditing = false
        Task {
            guard let client else { notesLoading = false; return }
            let n = await store.loadNotes(file: task.file, pos: task.pos, using: client)
            await MainActor.run {
                notesText = n
                notesLoading = false
                notesEdited = false
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
