#if !os(macOS)
import SwiftUI

/// Unified edit sheet for an existing org task. Surfaces title, state,
/// priority, tags, scheduled date/time, deadline date/time, and notes in a
/// single form. Save commits only the fields that changed; Cancel discards
/// everything.
///
/// Save order matters: notes and property mutations are sent first (they
/// identify the task by file+pos, which remains stable). Title is sent last
/// because renaming a heading changes the daemon's task id — any subsequent
/// PATCH that still references the old id would 404.
struct EditTaskSheet: View {
    // Wrap the `any TaskDisplayable` so the sheet can be presented via
    // `.sheet(item:)` which requires Identifiable.
    struct TaskWrapper: Identifiable {
        let task: any TaskDisplayable
        var id: String { task.id }
    }

    let task: any TaskDisplayable
    let store: TasksStore

    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings

    // MARK: - Draft state (pre-populated on appear)

    @State private var draftTitle: String = ""
    @State private var draftState: String = ""
    @State private var draftPriority: String = ""
    @State private var draftTags: String = ""

    @State private var includeScheduled: Bool = false
    @State private var scheduledDate: Date = Date()
    @State private var scheduledTime: Date = Date()
    @State private var includeScheduledTime: Bool = false

    @State private var includeDeadline: Bool = false
    @State private var deadlineDate: Date = Date()
    @State private var deadlineTime: Date = Date()
    @State private var includeDeadlineTime: Bool = false

    @State private var draftNotes: String = ""
    @State private var notesLoading: Bool = false
    @State private var notesLoaded: Bool = false

    // MARK: - Save state

    @State private var isSaving: Bool = false
    @State private var errorMessage: String?

    private var client: APIClient? { settings.apiClient }

    private var priorityChoices: [String] {
        let server = store.priorities?.all ?? []
        return server.isEmpty ? ["A", "B", "C"] : server
    }

    // MARK: - Baseline values (set once on appear, used to detect dirtiness)

    @State private var baseTitle: String = ""
    @State private var baseState: String = ""
    @State private var basePriority: String = ""
    @State private var baseTags: String = ""
    @State private var baseIncludeScheduled: Bool = false
    @State private var baseScheduledTimestamp: String = ""
    @State private var baseIncludeDeadline: Bool = false
    @State private var baseDeadlineTimestamp: String = ""
    @State private var baseNotes: String = ""

    private var isDirty: Bool {
        draftTitle != baseTitle
            || draftState != baseState
            || draftPriority != basePriority
            || draftTags != baseTags
            || includeScheduled != baseIncludeScheduled
            || (includeScheduled && currentScheduledTimestamp != baseScheduledTimestamp)
            || includeDeadline != baseIncludeDeadline
            || (includeDeadline && currentDeadlineTimestamp != baseDeadlineTimestamp)
            || draftNotes != baseNotes
    }

    // Reconstruct the timestamp string the way we'd send it, so dirty-check
    // is string-level and avoids floating-point Date comparisons.
    private var currentScheduledTimestamp: String {
        OrgTimestampFormat.string(
            date: mergeDateTime(day: scheduledDate, time: scheduledTime),
            includeTime: includeScheduledTime
        )
    }

    private var currentDeadlineTimestamp: String {
        OrgTimestampFormat.string(
            date: mergeDateTime(day: deadlineDate, time: deadlineTime),
            includeTime: includeDeadlineTime
        )
    }

    var body: some View {
        PickerSheetScaffold(
            title: "Edit Task",
            isMutating: isSaving,
            saveAction: { await save() },
            saveDisabled: !isDirty || client == nil
        ) {
            Form {
                Section("Title") {
                    TextField("Task title", text: $draftTitle, axis: .vertical)
                        .lineLimit(1...3)
                        .autocorrectionDisabled(false)
                }

                if let kw = store.keywords {
                    let allStates = kw.allActive + kw.allDone
                    Section("State") {
                        if allStates.count <= 5 {
                            Picker("State", selection: $draftState) {
                                Text("None").tag("")
                                ForEach(allStates, id: \.self) { st in
                                    Text(st).tag(st)
                                }
                            }
                            .pickerStyle(.segmented)
                        } else {
                            Picker("State", selection: $draftState) {
                                Text("None").tag("")
                                if !kw.allActive.isEmpty {
                                    Section("Active") {
                                        ForEach(kw.allActive, id: \.self) { st in
                                            Text(st).tag(st)
                                        }
                                    }
                                }
                                if !kw.allDone.isEmpty {
                                    Section("Done") {
                                        ForEach(kw.allDone, id: \.self) { st in
                                            Text(st).tag(st)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                Section("Priority") {
                    Picker("Priority", selection: $draftPriority) {
                        Text("None").tag("")
                        ForEach(priorityChoices, id: \.self) { p in
                            Text(p).tag(p)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Tags") {
                    TextField("tag1:tag2:tag3", text: $draftTags)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                Section("Scheduled") {
                    Toggle("Schedule this task", isOn: $includeScheduled)
                        .tint(Theme.accent)
                    if includeScheduled {
                        DatePicker("Date", selection: $scheduledDate, displayedComponents: .date)
                            .datePickerStyle(.graphical)
                        Toggle("Include time", isOn: $includeScheduledTime)
                            .tint(Theme.accent)
                        if includeScheduledTime {
                            DatePicker("Time", selection: $scheduledTime, displayedComponents: .hourAndMinute)
                        }
                    }
                }

                Section("Deadline") {
                    Toggle("Set deadline", isOn: $includeDeadline)
                        .tint(Theme.accent)
                    if includeDeadline {
                        DatePicker("Date", selection: $deadlineDate, displayedComponents: .date)
                            .datePickerStyle(.graphical)
                        Toggle("Include time", isOn: $includeDeadlineTime)
                            .tint(Theme.accent)
                        if includeDeadlineTime {
                            DatePicker("Time", selection: $deadlineTime, displayedComponents: .hourAndMinute)
                        }
                    }
                }

                Section {
                    if notesLoading {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Loading notes\u{2026}")
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    } else {
                        TextEditor(text: $draftNotes)
                            .font(.system(size: 14, design: .monospaced))
                            .frame(minHeight: 120)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.sentences)
                    }
                } header: {
                    Text("Notes")
                } footer: {
                    Text("Raw org-mode markup.")
                }

                ErrorSection(errorMessage)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
        }
        .task { await setup() }
    }

    // MARK: - Setup

    private func setup() async {
        // Populate all draft fields from the task. This runs once on appear.
        draftTitle = task.title
        draftState = task.todoState ?? ""
        draftPriority = task.priority ?? ""
        draftTags = task.tags.joined(separator: ":")

        if let sched = task.scheduled, let comp = sched.start {
            includeScheduled = true
            includeScheduledTime = comp.hour != nil
            var dc = DateComponents()
            dc.year = comp.year; dc.month = comp.month; dc.day = comp.day
            dc.hour = comp.hour ?? 9; dc.minute = comp.minute ?? 0
            let resolved = Calendar.current.date(from: dc) ?? Date()
            scheduledDate = resolved
            scheduledTime = resolved
        } else {
            includeScheduled = false
        }

        if let dl = task.deadline, let comp = dl.start {
            includeDeadline = true
            includeDeadlineTime = comp.hour != nil
            var dc = DateComponents()
            dc.year = comp.year; dc.month = comp.month; dc.day = comp.day
            dc.hour = comp.hour ?? 9; dc.minute = comp.minute ?? 0
            let resolved = Calendar.current.date(from: dc) ?? Date()
            deadlineDate = resolved
            deadlineTime = resolved
        } else {
            includeDeadline = false
        }

        // Capture baselines after populating all draft fields.
        baseTitle = draftTitle
        baseState = draftState
        basePriority = draftPriority
        baseTags = draftTags
        baseIncludeScheduled = includeScheduled
        baseScheduledTimestamp = includeScheduled ? currentScheduledTimestamp : ""
        baseIncludeDeadline = includeDeadline
        baseDeadlineTimestamp = includeDeadline ? currentDeadlineTimestamp : ""

        // Load notes async — show spinner while fetching.
        await loadNotes()
    }

    private func loadNotes() async {
        guard let client else { return }

        // Try the inline field first (avoids a round trip for tasks that
        // already have `notes` in the /api/tasks payload).
        if let org = task as? OrgTask, let inline = org.notes {
            draftNotes = inline
            baseNotes = inline
            notesLoaded = true
            return
        }
        // Try store cache before hitting the network.
        if let cached = store.cachedNotes(file: task.file, pos: task.pos) {
            draftNotes = cached
            baseNotes = cached
            notesLoaded = true
            return
        }
        notesLoading = true
        let body = await store.loadNotes(file: task.file, pos: task.pos, using: client)
        draftNotes = body
        baseNotes = body
        notesLoaded = true
        notesLoading = false
    }

    // MARK: - Save

    /// Saves only the fields that changed. Returns true on full success so
    /// `PickerSheetScaffold` can auto-dismiss; returns false on partial or
    /// total failure (errorMessage is set and the sheet stays open).
    private func save() async -> Bool {
        guard let client else { return false }
        isSaving = true
        errorMessage = nil

        var errors: [String] = []

        // 1. Notes (stable key: file+pos never changes during an edit session).
        if draftNotes != baseNotes {
            let ok = await store.setNotes(file: task.file, pos: task.pos, notes: draftNotes, using: client)
            if !ok { errors.append(store.lastMutationError ?? "Couldn't save notes") }
            else { baseNotes = draftNotes }
        }

        // 2. State
        if draftState != baseState {
            let ok = await store.setState(
                taskId: task.id, file: task.file, pos: task.pos,
                state: draftState, using: client
            )
            if !ok { errors.append(store.lastMutationError ?? "Couldn't save state") }
            else { baseState = draftState }
        }

        // 3. Priority
        if draftPriority != basePriority {
            let ok = await store.setPriority(
                taskId: task.id, file: task.file, pos: task.pos,
                priority: draftPriority, using: client
            )
            if !ok { errors.append(store.lastMutationError ?? "Couldn't save priority") }
            else { basePriority = draftPriority }
        }

        // 4. Tags — colon-joined string back to array, filtering empty tokens.
        if draftTags != baseTags {
            let tagArray = draftTags
                .split(separator: ":", omittingEmptySubsequences: true)
                .map(String.init)
            let ok = await store.setTags(
                taskId: task.id, file: task.file, pos: task.pos,
                tags: tagArray, using: client
            )
            if !ok { errors.append(store.lastMutationError ?? "Couldn't save tags") }
            else { baseTags = draftTags }
        }

        // 5. Scheduled timestamp
        let scheduledChanged = includeScheduled != baseIncludeScheduled
            || (includeScheduled && currentScheduledTimestamp != baseScheduledTimestamp)
        if scheduledChanged {
            let ts = includeScheduled ? currentScheduledTimestamp : ""
            let ok = await store.setScheduled(
                taskId: task.id, file: task.file, pos: task.pos,
                timestamp: ts, using: client
            )
            if !ok { errors.append(store.lastMutationError ?? "Couldn't save scheduled date") }
            else {
                baseIncludeScheduled = includeScheduled
                baseScheduledTimestamp = includeScheduled ? currentScheduledTimestamp : ""
            }
        }

        // 6. Deadline timestamp
        let deadlineChanged = includeDeadline != baseIncludeDeadline
            || (includeDeadline && currentDeadlineTimestamp != baseDeadlineTimestamp)
        if deadlineChanged {
            let ts = includeDeadline ? currentDeadlineTimestamp : ""
            let ok = await store.setDeadline(
                taskId: task.id, file: task.file, pos: task.pos,
                timestamp: ts, using: client
            )
            if !ok { errors.append(store.lastMutationError ?? "Couldn't save deadline") }
            else {
                baseIncludeDeadline = includeDeadline
                baseDeadlineTimestamp = includeDeadline ? currentDeadlineTimestamp : ""
            }
        }

        // 7. Title — sent last because renaming a heading changes the task's id.
        //    Any PATCH that still uses the old id would fail after this point,
        //    so title must be the final mutation in the sequence.
        if draftTitle != baseTitle {
            let trimmed = draftTitle.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                let ok = await store.setTitle(
                    taskId: task.id, file: task.file, pos: task.pos,
                    title: trimmed, using: client
                )
                if !ok { errors.append(store.lastMutationError ?? "Couldn't save title") }
                else { baseTitle = trimmed }
            }
        }

        isSaving = false

        if errors.isEmpty {
            await store.refreshLoaded(using: client)
            return true
        } else {
            errorMessage = errors.joined(separator: "\n")
            return false
        }
    }
}

// Merges the calendar-date components of `day` with the clock components of
// `time` so OrgTimestampFormat sees a single coherent Date.
private func mergeDateTime(day: Date, time: Date) -> Date {
    var dc = Calendar.current.dateComponents([.year, .month, .day], from: day)
    let tc = Calendar.current.dateComponents([.hour, .minute], from: time)
    dc.hour = tc.hour
    dc.minute = tc.minute
    return Calendar.current.date(from: dc) ?? day
}
#endif
