#if !os(macOS)
import SwiftUI

/// Task detail view (iOS). Form-based layout in the Settings / Reminders
/// idiom: large title up top, then grouped sections for Status / Schedule /
/// Tags / Notes. Each editable row shows the current value and pushes the
/// corresponding sheet on tap. Replaces an earlier wireframe-quality layout
/// with duplicated status pills, raw action chips, and overlapping date
/// badges (see git log around 2026-05-21).
struct TaskDetailView: View {
    let task: any TaskDisplayable
    let doneStates: Set<String>
    let store: TasksStore

    @Environment(AppSettings.self) private var settings
    @Environment(ClockManager.self) private var clocks

    @State private var notesText: String = ""
    @State private var notesLoading: Bool = true
    @State private var notesError: String?

    @State private var outline: APIClient.OutlinePathResponse?

    /// Local mirror of the :PINNED: property. Seeded from the store-resolved
    /// OrgTask on appear; updated optimistically in `togglePin()` and
    /// reconciled with truth after the store reload.
    @State private var pinnedValue: String? = nil
    @State private var isMutating: Bool = false

    @State private var showTagSheet = false
    @State private var showPrioritySheet = false
    @State private var showStateSheet = false
    @State private var showScheduleSheet = false
    @State private var showDeadlineSheet = false
    @State private var showRefileSheet = false
    @State private var showNotesEditor = false

    @State private var notesBlocks: [NoteBlock] = []

    private var client: APIClient? { settings.apiClient }

    private var isDone: Bool {
        guard let s = task.todoState else { return false }
        return doneStates.contains(s.uppercased())
    }

    private var isPinnedToday: Bool {
        pinnedValue == DateQuery.today()
    }

    /// Calendar events (and other timestamp-driven entries) don't have a
    /// file/pos to round-trip mutations against. We disable all editing
    /// affordances for them.
    private var hasFileBacking: Bool {
        !task.file.isEmpty && task.pos > 0
    }

    private var canEdit: Bool {
        client != nil && hasFileBacking && !isMutating
    }

    var body: some View {
        Form {
            titleSection
            statusSection
            scheduleSection
            tagsSection
            organizeSection
            notesSection
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showNotesEditor = true } label: {
                    Image(systemName: "pencil")
                }
                .disabled(!canEdit)
                .help("Edit notes")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await togglePin() } } label: {
                    Image(systemName: isPinnedToday ? "pin.fill" : "pin")
                }
                .disabled(!canEdit)
                .help(isPinnedToday ? "Unpin from My Day" : "Pin to My Day")
            }
        }
        .sheet(isPresented: $showTagSheet)      { TagEditorSheet(task: task, store: store) }
        .sheet(isPresented: $showPrioritySheet) { PriorityPickerSheet(task: task, store: store) }
        .sheet(isPresented: $showStateSheet)    { StatePickerSheet(task: task, store: store) }
        .sheet(isPresented: $showScheduleSheet) { SchedulePickerSheet(task: task, store: store) }
        .sheet(isPresented: $showDeadlineSheet) { DeadlinePickerSheet(task: task, store: store) }
        .sheet(isPresented: $showRefileSheet)   { RefileSheet(task: task, store: store) }
        .sheet(isPresented: $showNotesEditor) {
            NotesEditorSheet(task: task, store: store, initialNotes: notesText) { saved in
                notesText = saved
                notesBlocks = NotesParser.parse(saved)
            }
        }
        .onChange(of: notesText) { _, new in
            notesBlocks = NotesParser.parse(new)
        }
        .onAppear {
            pinnedValue = currentOrgTask()?.properties?["PINNED"]
                ?? (task as? OrgTask)?.properties?["PINNED"]
            Task {
                await loadOutline()
                await loadNotes()
            }
        }
    }

    // MARK: - Clock helpers (multi-clock via ClockManager — see ClockManager.swift)

    private var isClockedHere: Bool {
        clocks.isClocked(taskId: task.id)
    }

    private func liveElapsedLabel(now: Date) -> String? {
        guard let s = clocks.sessions.first(where: { $0.taskId == task.id }) else { return nil }
        return ClockManager.formatElapsed(ClockManager.elapsed(for: s, now: now))
    }

    private func toggleClock() async {
        guard let client else { return }
        isMutating = true
        if isClockedHere {
            _ = await clocks.stop(taskId: task.id, using: client, store: store)
        } else {
            await clocks.clockIn(task: task, using: client)
        }
        isMutating = false
    }

    // MARK: - Sections

    private var titleSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(renderInline(task.title))
                    .font(.title3.weight(.semibold))
                    .strikethrough(isDone, color: Theme.textSecondary)
                    .foregroundStyle(isDone ? Theme.textSecondary : Theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !task.category.isEmpty {
                    Text(task.category)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.textTertiary)
                        .textCase(.uppercase)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var statusSection: some View {
        Section("Status") {
            row(
                label: "State",
                icon: "circle.dashed",
                value: task.todoState,
                placeholder: "Set state"
            ) { showStateSheet = true }

            row(
                label: "Priority",
                icon: "flag",
                value: task.priority.map { "[\($0)]" },
                placeholder: "Set priority"
            ) { showPrioritySheet = true }

            clockRow
        }
    }

    @ViewBuilder
    private var clockRow: some View {
        if isClockedHere {
            // TimelineView fires only while this view is in the rendered hierarchy
            // and an active clock exists for this task.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                clockRowContent(clocked: true, now: context.date)
            }
        } else {
            clockRowContent(clocked: false, now: .now)
        }
    }

    @ViewBuilder
    private func clockRowContent(clocked: Bool, now: Date) -> some View {
        let icon = clocked ? "stop.circle.fill" : "play.circle"
        let label = clocked ? "Clock Out" : "Clock In"
        let value: String? = clocked ? liveElapsedLabel(now: now) : nil
        let placeholder = clocked ? "" : "Not clocked"
        let tint: Color = clocked ? Theme.priorityA : Theme.accent

        Button {
            Task { await toggleClock() }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.body)
                    .foregroundStyle(canEdit ? tint : Theme.textTertiary)
                    .frame(width: 20)
                Text(label)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(value ?? placeholder)
                    .font(clocked ? .body.monospacedDigit() : .body)
                    .foregroundStyle(value == nil ? Theme.textTertiary : tint)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canEdit)
    }

    private var scheduleSection: some View {
        Section("Schedule") {
            row(
                label: "Scheduled",
                icon: "calendar",
                value: friendlyDate(task.scheduled),
                placeholder: "Add date"
            ) { showScheduleSheet = true }

            row(
                label: "Deadline",
                icon: "exclamationmark.triangle",
                value: friendlyDate(task.deadline),
                placeholder: "Add deadline"
            ) { showDeadlineSheet = true }

            Toggle(isOn: pinBinding) {
                Label("Pin to My Day", systemImage: "pin.fill")
                    .foregroundStyle(Theme.textPrimary)
            }
            .disabled(!canEdit)
            .tint(Theme.accent)
        }
    }

    private var tagsSection: some View {
        Section("Tags") {
            row(
                label: "Tags",
                icon: "tag",
                value: task.tags.isEmpty ? nil : task.tags.joined(separator: ", "),
                placeholder: "Add tags"
            ) { showTagSheet = true }
        }
    }

    @ViewBuilder
    private var organizeSection: some View {
        Section("Organize") {
            row(
                label: "Move to\u{2026}",
                icon: "arrow.turn.right.down",
                value: outlineCrumbs,
                placeholder: "Refile"
            ) { showRefileSheet = true }
        }
    }

    @ViewBuilder
    private var notesSection: some View {
        Section("Notes") {
            if notesLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading\u{2026}")
                        .foregroundStyle(Theme.textSecondary)
                }
            } else if let err = notesError {
                VStack(alignment: .leading, spacing: 6) {
                    Text(err).foregroundStyle(Theme.priorityA)
                    Button("Retry") { Task { await loadNotes() } }
                        .buttonStyle(.borderless)
                }
            } else if notesText.isEmpty {
                Text("No notes \u{2014} tap the pencil to add")
                    .foregroundStyle(Theme.textTertiary)
                    .italic()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onLongPressGesture { showNotesEditor = true }
            } else {
                NotesRenderedView(blocks: notesBlocks, onToggleChecklist: handleChecklistToggle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onLongPressGesture { showNotesEditor = true }
            }
        }
    }

    // MARK: - Row helper

    @ViewBuilder
    private func row(label: String, icon: String, value: String?, placeholder: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.body)
                    .foregroundStyle(canEdit ? Theme.accent : Theme.textTertiary)
                    .frame(width: 20)
                Text(label)
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 8)
                Text(value ?? placeholder)
                    .foregroundStyle(value == nil ? Theme.textTertiary : Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canEdit)
    }

    // MARK: - Pin binding

    private var pinBinding: Binding<Bool> {
        Binding(
            get: { isPinnedToday },
            set: { _ in Task { await togglePin() } }
        )
    }

    // MARK: - Formatting helpers

    private var outlineCrumbs: String? {
        guard let outline, !outline.file.isEmpty else { return nil }
        let fileName = URL(fileURLWithPath: outline.file)
            .deletingPathExtension().lastPathComponent
        let parts = [fileName] + outline.headings
        return parts.joined(separator: " › ")
    }

    /// Relative + friendly date label: "Today", "Tomorrow", "Yesterday",
    /// weekday for the next week, then "MMM d". Includes time if present.
    private func friendlyDate(_ ts: OrgTimestamp?) -> String? {
        guard let ts, let comp = ts.start else { return nil }
        var dc = DateComponents()
        dc.year = comp.year
        dc.month = comp.month
        dc.day = comp.day
        let cal = Calendar.current
        guard let date = cal.date(from: dc) else { return nil }
        let today = cal.startOfDay(for: Date())
        let target = cal.startOfDay(for: date)
        let days = cal.dateComponents([.day], from: today, to: target).day ?? 0

        let dayLabel: String
        switch days {
        case 0: dayLabel = "Today"
        case 1: dayLabel = "Tomorrow"
        case -1: dayLabel = "Yesterday"
        case 2...6:
            let f = DateFormatter(); f.dateFormat = "EEEE"
            dayLabel = f.string(from: date)
        default:
            let f = DateFormatter(); f.dateFormat = "MMM d"
            dayLabel = f.string(from: date)
        }

        if let h = comp.hour, let m = comp.minute {
            return String(format: "%@ %02d:%02d", dayLabel, h, m)
        }
        return dayLabel
    }

    // MARK: - Data + mutations

    private func currentOrgTask() -> OrgTask? {
        store.allTasks.value?.first { $0.id == task.id }
    }

    private func togglePin() async {
        guard let client else { return }
        let today = DateQuery.today()
        let newValue = isPinnedToday ? "" : today
        let previous = pinnedValue
        pinnedValue = newValue.isEmpty ? nil : newValue
        isMutating = true
        do {
            try await client.setProperty(
                taskId: task.id, file: task.file, pos: task.pos,
                key: "PINNED", value: newValue
            )
            await store.loadAllTasks(using: client, includeDone: false)
            pinnedValue = currentOrgTask()?.properties?["PINNED"]
        } catch {
            pinnedValue = previous
        }
        isMutating = false
    }

    private func loadNotes() async {
        notesLoading = true
        notesError = nil
        guard hasFileBacking else {
            notesText = ""
            notesLoading = false
            return
        }
        guard let client else {
            notesError = "Couldn't load notes"
            notesLoading = false
            return
        }
        do {
            // Keep RAW — NotesParser strips drawers / SCHEDULED / CLOCK
            // lines during render but preserves their source-line indices,
            // so checklist toggles + edit-sheet saves write the right
            // bytes back. Filtering up-front would corrupt the indices and
            // drop the drawers on save.
            notesText = try await client.fetchNotes(file: task.file, pos: task.pos)
        } catch {
            notesError = "Couldn't load notes"
        }
        notesLoading = false
    }

    private func loadOutline() async {
        guard hasFileBacking, let client else { return }
        outline = try? await client.fetchOutlinePath(file: task.file, pos: task.pos)
    }

    /// Cycle the checkbox at `lineIndex` and PUT the full body. Optimistic
    /// — revert on failure so the rendered view doesn't lie.
    private func handleChecklistToggle(_ lineIndex: Int) {
        guard let client,
              let next = NotesMutation.toggleChecklist(in: notesText, lineIndex: lineIndex)
        else { return }
        let previous = notesText
        notesText = next
        Task {
            let ok = await store.setNotes(
                file: task.file, pos: task.pos,
                notes: next, using: client
            )
            if !ok {
                await MainActor.run { notesText = previous }
            } else if let saved = store.cachedNotes(file: task.file, pos: task.pos) {
                await MainActor.run { notesText = saved }
            }
        }
    }
}
#endif
