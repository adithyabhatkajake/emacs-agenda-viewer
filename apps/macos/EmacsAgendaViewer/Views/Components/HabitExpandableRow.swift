#if !os(macOS)
import SwiftUI

// MARK: - HabitExpandableRow

/// Task-row-style expandable row for a DB-backed `Habit`.
///
/// Interaction model mirrors `ExpandableTaskRow`:
///  - Tap the checkbox circle → complete (if undone) or uncomplete (if done)
///  - Tap the row body → toggle inline expansion (checklist + notes + meta)
///  - Swipe leading → Done / Undo
///  - Swipe trailing → Skip / Schedule / Edit / Delete
///  - Long-press → context menu with the same set
///
/// `expandedIds` lives in the parent list so scroll-off recycling doesn't
/// collapse rows mid-session.
struct HabitExpandableRow: View {
    let habit: Habit
    let store: TasksStore
    @Binding var expandedIds: Set<String>

    @Environment(AppSettings.self) private var settings
    @Environment(ClockManager.self) private var clocks

    @State private var showEditSheet: Bool = false
    @State private var showScheduleSheet: Bool = false
    @State private var hapticDone: Bool = false

    /// Cached parse of `habit.notes`. Updated via `.onChange(of: habit.notes)` so
    /// it stays current on external edits without re-parsing every body evaluation.
    /// `hasChecklist` and `progress` are derived from the same parse so
    /// OrgChecklist.parse and a second NotesParser.parse are never called separately.
    @State private var parsedNotes: ParsedNotesCache = ParsedNotesCache(notes: "")

    private var isExpanded: Bool { expandedIds.contains(habit.id) }
    private var isDone: Bool { HabitsGroupingNew.isDoneThisPeriod(habit) }

    private var hasNotes: Bool {
        !(habit.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasChecklistItems: Bool { parsedNotes.hasChecklist }

    /// True when the expanded panel has anything worth showing.
    private var hasExpandableContent: Bool {
        parsedNotes.blocks.contains { block in
            if case .blank = block { return false }
            return true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 6) {
                checkboxButton
                    // 44pt hit frame: glyph center is 13pt from top of frame.
                    // 3pt top pad keeps visual glyph-center at the same 16pt
                    // from row top as the old 28pt frame + 11pt pad.
                    .padding(.top, 3)

                Button {
                    guard hasExpandableContent || hasNotes else { return }
                    if expandedIds.contains(habit.id) {
                        expandedIds.remove(habit.id)
                    } else {
                        expandedIds.insert(habit.id)
                    }
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        habitTitleBlock
                        if hasExpandableContent || hasNotes {
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.textTertiary)
                                .padding(.top, 14)
                                .padding(.trailing, 8)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if isExpanded {
                expandedPanel
                    .padding(.leading, 38)
                    .padding(.trailing, 12)
                    .padding(.bottom, 10)
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                toggleDone()
            } label: {
                Label(isDone ? "Undo" : "Done",
                      systemImage: isDone ? "arrow.uturn.backward.circle" : "checkmark.circle")
            }
            .tint(isDone ? Theme.textSecondary : Theme.doneGreen)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                deleteHabit()
            } label: {
                Label("Delete", systemImage: "trash")
            }

            Button {
                showEditSheet = true
            } label: {
                Label("Edit", systemImage: "square.and.pencil")
            }
            .tint(Theme.accent)

            Button {
                showScheduleSheet = true
            } label: {
                Label("Schedule", systemImage: "calendar.badge.plus")
            }
            .tint(Theme.priorityB)

            Button {
                skipHabit()
            } label: {
                Label("Skip", systemImage: "forward.end")
            }
            .tint(Theme.textTertiary)
        }
        .sensoryFeedback(.success, trigger: hapticDone)
        .contextMenu {
            Button {
                toggleDone()
            } label: {
                Label(isDone ? "Undo" : "Done",
                      systemImage: isDone ? "arrow.uturn.backward.circle" : "checkmark.circle")
            }

            Button {
                skipHabit()
            } label: {
                Label("Skip", systemImage: "forward.end")
            }

            Divider()

            Button {
                showScheduleSheet = true
            } label: {
                Label("Schedule\u{2026}", systemImage: "calendar.badge.plus")
            }

            Button {
                showEditSheet = true
            } label: {
                Label("Edit\u{2026}", systemImage: "square.and.pencil")
            }

            // Only show when there are checklist items to reset.
            if hasChecklistItems {
                Button {
                    resetChecklist()
                } label: {
                    Label("Reset checklist", systemImage: "arrow.counterclockwise.circle")
                }
            }

            Button {
                clockToggle()
            } label: {
                Label(
                    clocks.isClocked(taskId: habit.id) ? "Clock Out" : "Clock In",
                    systemImage: clocks.isClocked(taskId: habit.id) ? "stop.circle" : "play.circle"
                )
            }

            Divider()

            Button(role: .destructive) {
                deleteHabit()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .sheet(isPresented: $showEditSheet) {
            IOSHabitFormSheet(store: store, existingHabit: habit)
                .environment(settings)
        }
        .sheet(isPresented: $showScheduleSheet) {
            HabitSchedulePickerSheet(habit: habit, store: store)
                .environment(settings)
        }
        .onAppear { parsedNotes = ParsedNotesCache(notes: habit.notes ?? "") }
        .onChange(of: habit.notes) { _, new in
            parsedNotes = ParsedNotesCache(notes: new ?? "")
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var checkboxButton: some View {
        ProgressCheckbox(
            progress: parsedNotes.progress,
            isDone: isDone,
            onTap: toggleDone
        )
    }

    /// Synthetic TODO state for display: first active keyword when not done,
    /// first done keyword when done. Falls back to the literal strings if
    /// `store.keywords` hasn't loaded yet.
    private func syntheticState(for isDone: Bool) -> String {
        if isDone {
            return store.keywords?.allDone.first ?? "DONE"
        } else {
            return store.keywords?.allActive.first ?? "TODO"
        }
    }

    @ViewBuilder
    private var habitTitleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                // State pill mirrors TaskRow: [pill] [priority] title
                TodoStatePill(state: syntheticState(for: isDone), isDone: isDone)
                if let priority = habit.priority, !priority.isEmpty {
                    PriorityBadge(priority: priority)
                }
                Text(habit.title)
                    .font(.body)
                    .foregroundStyle(isDone ? Theme.textTertiary : Theme.textPrimary)
                    .strikethrough(isDone, color: Theme.textTertiary)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }

            // Meta line: same order as TaskRow — overdue, category, date, recurrence, tags.
            HStack(spacing: 8) {
                if habit.state == "overdue" {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(Theme.priorityA)
                        .accessibilityLabel("Overdue")
                }
                if let cat = habit.category, !cat.isEmpty {
                    Text(cat)
                        .font(.caption2)
                        .foregroundStyle(Theme.textTertiary)
                }
                // Calendar icon + relative date, matching DateBadge(.scheduled) style.
                if let displayDate = habitDisplayDate(habit) {
                    HStack(spacing: 3) {
                        Image(systemName: "calendar")
                            .font(.system(size: 9, weight: .semibold))
                            .accessibilityHidden(true)
                        Text(DateBadge.relativeLabel(for: displayDate))
                            .font(.caption2)
                    }
                    .foregroundStyle(habit.state == "overdue" ? Theme.priorityA : Theme.textSecondary)
                }
                // Recurrence glyph + compact interval, matching TaskRow's repeatLabel block.
                HStack(spacing: 2) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .accessibilityHidden(true)
                    Text(compactCadenceLabel(habit.cadence))
                }
                .font(.caption2)
                .foregroundStyle(Theme.textTertiary)

                if !habit.tags.isEmpty {
                    TagChips(tags: habit.tags, inheritedTags: [])
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 8)
    }

    /// Display date for the meta line. Relaxed cadences show the deadline
    /// (nextDue + extra days), matching the logic in `habitDueDateLabel`.
    private func habitDisplayDate(_ habit: Habit) -> Date? {
        guard let nd = habit.nextDue, !nd.isEmpty,
              let base = OrgTimestamp.parseDateString(nd) else { return nil }
        if let mv = habit.cadence.maxValue, let mu = habit.cadence.maxUnit {
            let cal = Calendar.current
            guard let minEnd = cal.date(byAdding: habitDC(Int(habit.cadence.value), habit.cadence.unit), to: base),
                  let maxEnd = cal.date(byAdding: habitDC(Int(mv), mu), to: base)
            else { return base }
            let extra = cal.dateComponents([.day], from: minEnd, to: maxEnd).day ?? 0
            return cal.date(byAdding: .day, value: extra, to: base) ?? base
        }
        return base
    }

    /// Compact cadence interval without the emoji — "1d", "2w", "1\u{2013}2w".
    /// Used with the arrow glyph to match TaskRow's `↻<interval>` appearance.
    private func compactCadenceLabel(_ spec: HabitCadenceSpec) -> String {
        let minPart = compactCadenceUnit(value: spec.value, unit: spec.unit)
        if let mv = spec.maxValue, let mu = spec.maxUnit {
            let maxPart = compactCadenceUnit(value: mv, unit: mu)
            return "\(minPart)\u{2013}\(maxPart)"
        }
        return minPart
    }

    @ViewBuilder
    private var expandedPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !parsedNotes.blocks.isEmpty {
                NotesRenderedView(blocks: parsedNotes.blocks, onToggleChecklist: handleChecklistToggle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Recurrence glyph + streak summary — small, secondary detail.
            let stats = HabitMath.stats(for: habit)
            HStack(spacing: 8) {
                HStack(spacing: 2) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .accessibilityHidden(true)
                    Text(compactCadenceLabel(habit.cadence))
                }
                .font(.caption2)
                .foregroundStyle(Theme.textTertiary)
                Text("\u{00B7}")
                    .font(.caption2)
                    .foregroundStyle(Theme.textTertiary)
                Text("streak: \(stats.streakLabel)")
                    .font(.caption2)
                    .foregroundStyle(stats.currentStreak == 0 ? Theme.textTertiary : Theme.doneGreen)
                Spacer(minLength: 0)
            }
            .padding(.top, 2)
        }
    }

    // MARK: - Actions

    private func toggleDone() {
        guard let client = settings.apiClient else { return }
        hapticDone.toggle()
        Task { @MainActor in
            if isDone {
                _ = await store.uncompleteHabit(habit, using: client)
            } else {
                _ = await store.completeHabit(habit, using: client)
            }
        }
    }

    private func skipHabit() {
        guard let client = settings.apiClient else { return }
        Task { @MainActor in
            _ = await store.skipHabit(habit, using: client)
        }
    }

    private func deleteHabit() {
        guard let client = settings.apiClient else { return }
        Task { @MainActor in
            _ = await store.deleteHabit(habit, using: client)
        }
    }

    private func clockToggle() {
        guard let client = settings.apiClient else { return }
        Task { @MainActor in
            if clocks.isClocked(taskId: habit.id),
               let active = clocks.clockFor(taskId: habit.id) {
                await clocks.clockOut(clockId: active.id, using: client)
            } else {
                await clocks.clockInHabit(id: habit.id, title: habit.title, using: client)
            }
        }
    }

    private func resetChecklist() {
        guard let client = settings.apiClient else { return }
        let notes = habit.notes ?? ""
        let reset = OrgChecklist.resetAll(notes)
        // Skip the network call if nothing changed (no checked items).
        guard reset != notes else { return }
        Task { @MainActor in
            _ = await store.setHabitNotes(habit, notes: reset, using: client)
        }
    }

    private func handleChecklistToggle(_ lineIndex: Int) {
        guard let client = settings.apiClient else { return }
        let notes = habit.notes ?? ""
        guard let next = NotesMutation.toggleChecklist(in: notes, lineIndex: lineIndex)
        else { return }
        Task { @MainActor in
            _ = await store.setHabitNotes(habit, notes: next, using: client)
        }
    }
}

// MARK: - HabitSchedulePickerSheet

/// Date picker sheet that calls `rescheduleHabit(id:date:)`.
/// `date` is formatted `YYYY-MM-DD` as expected by the server.
struct HabitSchedulePickerSheet: View {
    let habit: Habit
    let store: TasksStore

    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings

    @State private var date: Date = Date()
    @State private var isMutating: Bool = false
    @State private var errorMessage: String?

    private static let isoDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    var body: some View {
        PickerSheetScaffold(
            title: "Reschedule \u{2014} \(habit.title)",
            isMutating: isMutating,
            saveAction: { await save() }
        ) {
            Form {
                Section {
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                }
                ErrorSection(errorMessage)
            }
        }
        .onAppear {
            // Seed with the current nextDue if parseable, otherwise today.
            if let nd = habit.nextDue,
               let d = Self.isoDateFormatter.date(from: nd) {
                date = d
            }
        }
    }

    private func save() async -> Bool {
        guard let client = settings.apiClient else { return false }
        isMutating = true
        errorMessage = nil
        let dateStr = Self.isoDateFormatter.string(from: date)
        let ok = await store.rescheduleHabit(habit, to: dateStr, using: client)
        if !ok { errorMessage = store.lastMutationError ?? "Failed to reschedule" }
        isMutating = false
        return ok
    }
}

// MARK: - ParsedNotesCache

/// One-shot parse of a notes string. Derives blocks, checklist presence, and
/// progress fraction in a single pass so downstream views never re-invoke
/// NotesParser or OrgChecklist separately for the same string.
private struct ParsedNotesCache {
    let notes: String
    let blocks: [NoteBlock]
    let hasChecklist: Bool
    let progress: Double?

    init(notes: String) {
        self.notes = notes
        let parsed = NotesParser.parse(notes)
        let items = parsed.compactMap { b -> ChecklistState? in
            if case .checklist(_, let s, _, _) = b { return s }
            return nil
        }
        self.blocks = parsed
        self.hasChecklist = !items.isEmpty
        self.progress = items.isEmpty ? nil : Double(items.filter { $0 == .done }.count) / Double(items.count)
    }
}
#endif
