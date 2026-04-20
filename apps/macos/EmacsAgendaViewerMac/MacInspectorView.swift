import SwiftUI

struct MacInspectorView: View {
    @Environment(AppSettings.self) private var settings
    let store: TasksStore
    let selectedTask: (any TaskDisplayable)?
    let onClose: () -> Void

    var body: some View {
        if let task = selectedTask {
            InspectorContent(store: store, task: task, onClose: onClose)
                .id(task.id)
        } else {
            emptyState
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.text")
                .font(.system(size: 36))
                .foregroundStyle(Theme.textTertiary)
            Text("Select a task to inspect")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct InspectorContent: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ClockManager.self) private var clocks
    @Environment(EventKitService.self) private var ek
    @Environment(CalendarSync.self) private var sync
    let store: TasksStore
    let task: any TaskDisplayable
    let onClose: () -> Void

    @State private var titleText: String = ""
    @State private var notesText: String = ""
    @State private var notesLoading = true
    @State private var notesEdited = false
    @FocusState private var notesFocused: Bool
    @State private var scheduledDate: Date?
    @State private var scheduledHasTime: Bool = false
    @State private var deadlineDate: Date?
    @State private var deadlineHasTime: Bool = false
    @State private var savingNotes = false

    private var file: String { task.file }
    private var pos: Int { task.pos }
    private var taskId: String { task.id }
    private var isDone: Bool { store.isDoneState(task.todoState) }
    private var isClocked: Bool {
        if clocks.isClocked(taskId: taskId) { return true }
        return store.clock?.clocking == true && store.clock?.file == file && store.clock?.pos == pos
    }
    private var client: APIClient? { settings.apiClient }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                Divider().background(Theme.borderSubtle)

                stateAndPriority
                datesSection

                Divider().background(Theme.borderSubtle)

                clockSection

                Divider().background(Theme.borderSubtle)

                calendarSection

                Divider().background(Theme.borderSubtle)

                notesSection

                Spacer(minLength: 24)
            }
            .padding(20)
        }
        .background(Theme.surface)
        .onAppear { syncFromTask() }
        .onChange(of: task.id) { _, _ in syncFromTask() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(action: { Task { await toggleDone() } }) {
                    Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20))
                        .foregroundStyle(isDone ? Theme.doneGreen : Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [])

                Spacer()

                if !task.category.isEmpty {
                    Text(task.category)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule(style: .continuous).strokeBorder(Theme.borderSubtle, lineWidth: 1))
                }

                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Close inspector")
            }

            TextField("Title", text: $titleText, axis: .vertical)
                .font(.system(size: 17, weight: .semibold))
                .textFieldStyle(.plain)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1...3)
                .onSubmit { Task { await saveTitle() } }
            HStack {
                Spacer()
                if titleText != task.title {
                    Button("Save title") { Task { await saveTitle() } }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
        }
    }

    // MARK: - State + priority

    private var stateAndPriority: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("STATE")
                    .font(.system(size: 9, weight: .bold)).tracking(0.6)
                    .foregroundStyle(Theme.textTertiary)
                stateMenu
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("PRIORITY")
                    .font(.system(size: 9, weight: .bold)).tracking(0.6)
                    .foregroundStyle(Theme.textTertiary)
                priorityMenu
            }
            Spacer()
        }
    }

    private var stateMenu: some View {
        Menu {
            ForEach((store.keywords?.allActive ?? ["TODO"]) + (store.keywords?.allDone ?? ["DONE"]), id: \.self) { state in
                Button(state) { Task { await setState(state) } }
            }
        } label: {
            HStack {
                Text(task.todoState ?? "—").font(.system(size: 12, weight: .semibold))
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9))
            }
            .frame(minWidth: 90, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
    }

    private var priorityMenu: some View {
        Menu {
            ForEach(["A", "B", "C", "D"], id: \.self) { p in
                Button {
                    Task { await setPriority(p) }
                } label: {
                    HStack {
                        Circle().fill(Theme.priorityColor(p)).frame(width: 8, height: 8)
                        Text(p)
                    }
                }
                .keyboardShortcut(KeyEquivalent(p.lowercased().first!), modifiers: [])
            }
            Divider()
            Button("None") { Task { await setPriority("") } }
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(Theme.priorityColor(task.priority))
                    .frame(width: 8, height: 8)
                Text(task.priority?.isEmpty == false ? task.priority! : "—")
                    .font(.system(size: 12, weight: .semibold))
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9))
            }
            .frame(minWidth: 60, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
    }

    // MARK: - Dates

    private var datesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            datePickerRow(
                label: "Scheduled",
                icon: "calendar",
                tint: Theme.accent,
                date: $scheduledDate,
                hasTime: $scheduledHasTime,
                onCommit: { Task { await commitScheduled() } }
            )
            datePickerRow(
                label: "Deadline",
                icon: "exclamationmark.circle",
                tint: Theme.priorityA,
                date: $deadlineDate,
                hasTime: $deadlineHasTime,
                onCommit: { Task { await commitDeadline() } }
            )
        }
    }

    @ViewBuilder
    private func datePickerRow(
        label: String, icon: String, tint: Color,
        date: Binding<Date?>, hasTime: Binding<Bool>,
        onCommit: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(label, systemImage: icon).foregroundStyle(tint)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if date.wrappedValue != nil {
                    Button("Clear") {
                        date.wrappedValue = nil
                        onCommit()
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
                }
            }
            HStack(spacing: 8) {
                if let bound = date.wrappedValue {
                    DatePicker(
                        "",
                        selection: Binding(
                            get: { bound },
                            set: { date.wrappedValue = $0 }
                        ),
                        displayedComponents: hasTime.wrappedValue ? [.date, .hourAndMinute] : [.date]
                    )
                    .labelsHidden()
                    .datePickerStyle(.compact)

                    Toggle("Time", isOn: hasTime)
                        .toggleStyle(.checkbox)
                        .controlSize(.small)

                    Button("Set") { onCommit() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                } else {
                    Button("Add date") {
                        date.wrappedValue = Calendar.current.startOfDay(for: Date())
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    // MARK: - Clock

    private var clockSection: some View {
        HStack {
            Label("Clock", systemImage: "stopwatch")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            if isClocked {
                Button {
                    Task { await clockOut() }
                } label: {
                    Label("Clock Out", systemImage: "stop.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.priorityA)
                .controlSize(.small)
            } else {
                Button {
                    Task { await clockIn() }
                } label: {
                    Label("Clock In", systemImage: "play.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
    }

    // MARK: - Calendar (EventKit)

    private var orgTask: OrgTask? { task as? OrgTask }
    private var linkedExternalId: String? {
        let id = orgTask?.properties?[CalendarSync.eventIdKey]
        return (id?.isEmpty ?? true) ? nil : id
    }
    private var hasScheduledTime: Bool { task.scheduled?.hasTime == true }

    @ViewBuilder
    private var calendarSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Calendar", systemImage: "calendar")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
            }

            if !ek.hasAccess {
                HStack {
                    Text("Not connected").font(.caption).foregroundStyle(Theme.textTertiary)
                    Spacer()
                    Button("Grant Access") { Task { await ek.requestAccess() } }
                        .controlSize(.small)
                }
            } else if let extId = linkedExternalId {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.doneGreen)
                    Text("Linked").font(.caption)
                    if let event = ek.findEvent(externalId: extId) {
                        Text("·").foregroundStyle(Theme.textTertiary)
                        Text(event.calendar.title).font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Button("Push") { pushUpdate(extId: extId) }
                        .controlSize(.small)
                    Button("Unlink") { Task { await unlink(extId: extId) } }
                        .controlSize(.small)
                }
            } else {
                Button {
                    Task { await addToCalendar() }
                } label: {
                    Label("Add to Calendar", systemImage: "calendar.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!hasScheduledTime || orgTask == nil)
                if !hasScheduledTime {
                    Text("Schedule a time first.")
                        .font(.caption2)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
    }

    private func addToCalendar() async {
        guard let scheduled = task.scheduled, let start = scheduled.parsedDate, scheduled.hasTime,
              let client else { return }
        let end = computeEnd(scheduled, default: 60)
        guard let extId = ek.createEvent(
            title: task.title, start: start, end: end,
            calendarId: settings.eventKitCalendarIdentifier
        ) else { return }
        await store.setProperty(taskId: taskId, file: file, pos: pos,
                                key: CalendarSync.eventIdKey, value: extId, using: client)
    }

    private func unlink(extId: String) async {
        guard let client else { return }
        ek.deleteEvent(externalId: extId)
        await store.setProperty(taskId: taskId, file: file, pos: pos,
                                key: CalendarSync.eventIdKey, value: "", using: client)
    }

    private func pushUpdate(extId: String) {
        guard let scheduled = task.scheduled, let start = scheduled.parsedDate else { return }
        let end = computeEnd(scheduled, default: 60)
        ek.updateEvent(externalId: extId, title: task.title, start: start, end: end)
    }

    // MARK: - Notes

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("NOTES")
                    .font(.system(size: 9, weight: .bold)).tracking(0.6)
                    .foregroundStyle(Theme.textTertiary)
                if notesEdited {
                    Circle()
                        .fill(Theme.priorityB)
                        .frame(width: 6, height: 6)
                        .help("Unsaved changes")
                }
                Spacer()
                Button {
                    Task { await saveNotes() }
                } label: {
                    Label(savingNotes ? "Saving…" : "Save",
                          systemImage: "arrow.down.doc")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(savingNotes || !notesEdited)
                .keyboardShortcut("s", modifiers: .command)
                .help("Save notes (⌘S). Notes also auto-save when you click outside the editor.")
            }
            if notesLoading {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                TextEditor(text: $notesText)
                    .scrollContentBackground(.hidden)
                    .background(Theme.background)
                    .font(.system(size: 12))
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
                if notesEdited {
                    Text("Unsaved changes — press ⌘S or click outside to save")
                        .font(.caption2)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
    }

    // MARK: - Actions

    private func syncFromTask() {
        titleText = task.title
        scheduledDate = task.scheduled?.parsedDate
        scheduledHasTime = task.scheduled?.hasTime ?? false
        deadlineDate = task.deadline?.parsedDate
        deadlineHasTime = task.deadline?.hasTime ?? false
        notesEdited = false
        notesLoading = true
        notesText = ""
        Task {
            guard let client else { notesLoading = false; return }
            let n = await store.loadNotes(file: file, pos: pos, using: client)
            await MainActor.run {
                notesText = n
                notesLoading = false
                notesEdited = false
            }
        }
    }

    private func toggleDone() async {
        guard let client else { return }
        await store.toggleDone(task, file: file, pos: pos, using: client)
    }

    private func setState(_ state: String) async {
        guard let client else { return }
        await store.setState(taskId: taskId, file: file, pos: pos, state: state, using: client)
    }

    private func setPriority(_ priority: String) async {
        guard let client else { return }
        await store.setPriority(taskId: taskId, file: file, pos: pos, priority: priority, using: client)
    }

    private func saveTitle() async {
        guard let client else { return }
        await store.setTitle(taskId: taskId, file: file, pos: pos, title: titleText, using: client)
    }

    private func commitScheduled() async {
        guard let client else { return }
        let ts = scheduledDate.map { OrgTimestampFormat.string(date: $0, includeTime: scheduledHasTime) } ?? ""
        await store.setScheduled(taskId: taskId, file: file, pos: pos, timestamp: ts, using: client)
    }

    private func commitDeadline() async {
        guard let client else { return }
        let ts = deadlineDate.map { OrgTimestampFormat.string(date: $0, includeTime: deadlineHasTime) } ?? ""
        await store.setDeadline(taskId: taskId, file: file, pos: pos, timestamp: ts, using: client)
    }

    private func clockIn() async {
        clocks.start(task: task)
    }

    private func clockOut() async {
        guard let client else { return }
        await clocks.stop(taskId: taskId, using: client, store: store)
    }

    private func saveNotes() async {
        guard let client else { return }
        savingNotes = true
        await store.setNotes(file: file, pos: pos, notes: notesText, using: client)
        savingNotes = false
        notesEdited = false
    }
}
