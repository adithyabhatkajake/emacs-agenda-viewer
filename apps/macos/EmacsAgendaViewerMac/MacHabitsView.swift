import SwiftUI

/// Read-only analytics dashboard for DB-backed habits.
///
/// Each row shows: title + priority + 14-cell consistency strip + current streak +
/// best streak + completion %. No checkbox or complete/skip/clock actions here —
/// those live in All Tasks. Tapping a row opens the edit sheet.
/// The "+" toolbar button opens the new-habit capture sheet.
struct MacHabitsView: View {
    @Environment(AppSettings.self) private var settings
    let store: TasksStore

    @State private var searchText = ""
    @State private var showNewHabit = false
    @State private var editingHabit: Habit? = nil

    var body: some View {
        content
            .navigationTitle("Habits")
            .searchable(text: $searchText, placement: .toolbar, prompt: "Search habits")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showNewHabit = true
                    } label: {
                        Label("New Habit", systemImage: "plus.circle")
                    }
                    .help("Create a new habit")
                    .disabled(!settings.isConfigured)
                }
                ToolbarItem(placement: .primaryAction) {
                    ReloadButton(action: { Task { await load() } }, disabled: !settings.isConfigured)
                }
            }
            .task(id: settings.serverURLString) { await loadIfNeeded() }
            .sheet(isPresented: $showNewHabit) {
                HabitFormSheet(store: store, existingHabit: nil)
                    .environment(settings)
            }
            .sheet(item: $editingHabit) { habit in
                HabitFormSheet(store: store, existingHabit: habit)
                    .environment(settings)
            }
    }

    @ViewBuilder
    private var content: some View {
        if !settings.isConfigured {
            UnconfiguredStateView()
        } else if let habits = store.habits.value {
            let filtered = filter(habits)
            if filtered.isEmpty {
                EmptyStateView(
                    title: searchText.isEmpty ? "No habits yet" : "No matches",
                    systemImage: searchText.isEmpty
                        ? "arrow.triangle.2.circlepath"
                        : "magnifyingglass"
                )
            } else {
                dashboard(filtered)
            }
        } else if store.habits.isLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let msg = store.habits.error {
            ErrorStateView(message: msg) { Task { await load() } }
        } else {
            Color.clear
        }
    }

    private func filter(_ habits: [Habit]) -> [Habit] {
        guard !searchText.isEmpty else { return habits }
        let needle = searchText.lowercased()
        return habits.filter { h in
            h.title.lowercased().contains(needle)
                || (h.category ?? "").lowercased().contains(needle)
        }
    }

    private func dashboard(_ habits: [Habit]) -> some View {
        let allStats = habits.map { HabitMath.stats(for: $0) }
        let doneToday = allStats.filter { $0.cells.last == .done }.count
        let bestStreak = allStats.map { $0.currentStreak }.max() ?? 0
        let totalCells = allStats.reduce(0) { $0 + $1.cells.count }
        let doneCells = allStats.reduce(0) { $0 + $1.cells.filter { $0 == .done }.count }
        let rate: Int = totalCells > 0 ? Int(round(Double(doneCells) / Double(totalCells) * 100)) : 0

        // Sort by current streak descending, then alphabetically.
        let sorted = habits.sorted { a, b in
            let sA = HabitMath.stats(for: a).currentStreak
            let sB = HabitMath.stats(for: b).currentStreak
            if sA != sB { return sA > sB }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }

        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                // Summary strip — Today done/total, best streak, 30-day rate.
                HStack(spacing: 12) {
                    habitStatChip(label: "Today", value: "\(doneToday)/\(habits.count)")
                    habitStatChip(
                        label: "Best streak",
                        value: "\(bestStreak)",
                        symbolName: bestStreak > 0 ? "flame.fill" : nil,
                        symbolColor: Theme.priorityB
                    )
                    habitStatChip(label: "30-day rate", value: "\(rate)%")
                }
                .padding(.bottom, 8)

                ForEach(sorted) { habit in
                    HabitDashboardRow(
                        habit: habit,
                        store: store,
                        onEdit: { editingHabit = habit }
                    )
                    .environment(settings)
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, minHeight: 600, alignment: .leading)
        }
        .background(Theme.background)
    }

    @ViewBuilder
    private func habitStatChip(label: String, value: String, symbolName: String? = nil, symbolColor: Color = Theme.accent) -> some View {
        HStack(spacing: 4) {
            if let sym = symbolName {
                Image(systemName: sym)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(symbolColor)
            }
            Text(value)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.textPrimary)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.surface.opacity(0.6))
        )
    }

    private func load() async {
        guard let client = settings.apiClient else { return }
        await store.ensureInitialized(using: client, settings: settings)
        await store.loadHabits(using: client)
    }

    private func loadIfNeeded() async {
        if store.habits.value == nil { await load() }
    }
}

// MARK: - HabitDashboardRow

/// Stats row for the Mac Habits dashboard.
///
/// Layout: checkbox + priority menu | title | 14-cell strip | streak | rate%
/// Supports done/undo, skip, delete-with-confirm, and inline priority change.
private struct HabitDashboardRow: View {
    @Environment(AppSettings.self) private var settings
    let habit: Habit
    let store: TasksStore
    let onEdit: () -> Void

    @State private var isHovering = false
    @State private var showDeleteConfirmation = false

    private var isDone: Bool { HabitsGroupingNew.isDoneThisPeriod(habit) }

    var body: some View {
        let stats = HabitMath.stats(for: habit)
        let ratePercent = Int(round(stats.completionRate * 100))

        HStack(alignment: .top, spacing: 10) {
            // Completion checkbox
            let checkColor: Color = isDone
                ? Theme.doneGreen
                : (isHovering ? Theme.textSecondary : Theme.textTertiary)
            Button(action: toggleDone) {
                Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(checkColor)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(-6)
            .padding(.top, 1)
            .help(isDone ? "Done this period — click to undo." : "Mark this period's habit done.")

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if let priority = habit.priority, !priority.isEmpty {
                        dashboardPriorityBox(priority)
                    }
                    Text(habit.title)
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(isDone ? Theme.textTertiary : Theme.textPrimary)
                        .strikethrough(isDone, color: Theme.textTertiary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }

                // 14-cell consistency strip
                DashboardStripView(cells: stats.cells, cadence: stats.cadence)

                HStack(spacing: 12) {
                    HStack(spacing: 3) {
                        Image(systemName: "flame.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(stats.currentStreak > 0 ? Theme.priorityB : Theme.textTertiary)
                        Text(stats.streakLabel)
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(stats.currentStreak > 0 ? Theme.doneGreen : Theme.textTertiary)
                    }
                    HStack(spacing: 3) {
                        Image(systemName: "trophy.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textTertiary)
                        Text(stats.bestLabel)
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Text("\(ratePercent)%")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Theme.textTertiary)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHovering ? Theme.surfaceElevated : Theme.surface)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { onEdit() }
        .contextMenu { dashboardContextMenu }
        .confirmationDialog(
            "Delete habit?",
            isPresented: $showDeleteConfirmation
        ) {
            Button("Delete", role: .destructive) { deleteHabit() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the habit and its completion history.")
        }
    }

    @ViewBuilder
    private var dashboardContextMenu: some View {
        if isDone {
            Button("Undo Done") { toggleDone() }
        } else {
            Button("Done") { toggleDone() }
        }
        Button("Skip") { skipHabit() }
        Divider()
        Menu("Priority") {
            let priorityList = store.priorities?.all ?? ["A", "B", "C", "D"]
            ForEach(priorityList, id: \.self) { p in
                Button(p) {
                    Task { @MainActor in
                        guard let client = settings.apiClient else { return }
                        _ = await store.setHabitPriority(habit, priority: p, using: client)
                    }
                }
            }
            Divider()
            Button("None") {
                Task { @MainActor in
                    guard let client = settings.apiClient else { return }
                    _ = await store.setHabitPriority(habit, priority: nil, using: client)
                }
            }
        }
        Divider()
        Button("Edit") { onEdit() }
        Button("Delete", role: .destructive) { showDeleteConfirmation = true }
    }

    @ViewBuilder
    private func dashboardPriorityBox(_ priority: String) -> some View {
        let color = settings.resolvedPriorityColor(for: priority)
        let priorityList = store.priorities?.all ?? ["A", "B", "C", "D"]
        Menu {
            ForEach(priorityList, id: \.self) { p in
                Button(p) {
                    Task { @MainActor in
                        guard let client = settings.apiClient else { return }
                        _ = await store.setHabitPriority(habit, priority: p, using: client)
                    }
                }
            }
            Divider()
            Button("None") {
                Task { @MainActor in
                    guard let client = settings.apiClient else { return }
                    _ = await store.setHabitPriority(habit, priority: nil, using: client)
                }
            }
        } label: {
            Text(priority.uppercased())
                .font(.system(size: 10, weight: .heavy, design: .monospaced))
                .foregroundStyle(color)
                .frame(width: 16, height: 16)
                .background(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(color.opacity(0.15))
                )
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
    }

    private func toggleDone() {
        Task { @MainActor in
            guard let client = settings.apiClient else { return }
            if isDone {
                _ = await store.uncompleteHabit(habit, using: client)
            } else {
                _ = await store.completeHabit(habit, using: client)
            }
        }
    }

    private func skipHabit() {
        Task { @MainActor in
            guard let client = settings.apiClient else { return }
            _ = await store.skipHabit(habit, using: client)
        }
    }

    private func deleteHabit() {
        Task { @MainActor in
            guard let client = settings.apiClient else { return }
            _ = await store.deleteHabit(habit, using: client)
        }
    }
}


// MARK: - HabitNotesBody

/// Renders the expanded notes body for a habit row: checklist items as
/// toggleable checkboxes and free-text lines with an inline edit affordance.
struct HabitNotesBody: View {
    let habit: Habit
    let store: TasksStore
    let settings: AppSettings
    let checklistItems: [ChecklistItem]

    @State private var isEditingNotes = false
    @State private var notesDraft: String = ""

    var body: some View {
        let notes = habit.notes ?? ""
        let lines = notes.components(separatedBy: "\n")
        let checklistLineIndices = Set(checklistItems.map(\.lineIndex))
        let hasFreetextLines = lines.enumerated().contains { (index, line) in
            !checklistLineIndices.contains(index)
                && !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                if let item = checklistItems.first(where: { $0.lineIndex == index }) {
                    ChecklistItemRow(item: item) {
                        toggleChecklistItem(lineIndex: item.lineIndex)
                    }
                } else if !checklistLineIndices.contains(index) {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        // Render org inline markup (=verbatim=, ~code~, *bold*,
                        // links, timestamps) like task notes do — plain Text
                        // showed the raw =…= markers.
                        Text(renderInline(trimmed))
                    }
                }
            }

            if hasFreetextLines || checklistItems.isEmpty {
                Button {
                    notesDraft = notes
                    isEditingNotes = true
                } label: {
                    Label("Edit notes", systemImage: "pencil")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
                .popover(isPresented: $isEditingNotes, arrowEdge: .bottom) {
                    notesEditPopover
                }
            }
        }
    }

    @ViewBuilder
    private var notesEditPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("NOTES")
                .font(.system(size: 9, weight: .heavy)).tracking(0.6)
                .foregroundStyle(Theme.textTertiary)
            TextEditor(text: $notesDraft)
                .font(.system(size: 13))
                .frame(minWidth: 280, minHeight: 100)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Theme.borderSubtle, lineWidth: 0.5)
                )
            HStack {
                Spacer()
                Button("Cancel") { isEditingNotes = false }
                    .keyboardShortcut(.escape)
                Button("Save") {
                    saveNotes(notesDraft)
                    isEditingNotes = false
                }
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(16)
        .frame(minWidth: 320)
    }

    private func toggleChecklistItem(lineIndex: Int) {
        guard let notes = habit.notes,
              let newNotes = OrgChecklist.toggle(notes, lineIndex: lineIndex) else { return }
        Task { @MainActor in
            guard let client = settings.apiClient else { return }
            _ = await store.setHabitNotes(habit, notes: newNotes, using: client)
        }
    }

    private func saveNotes(_ text: String) {
        Task { @MainActor in
            guard let client = settings.apiClient else { return }
            _ = await store.setHabitNotes(habit, notes: text, using: client)
        }
    }
}

// MARK: - ChecklistItemRow

struct ChecklistItemRow: View {
    let item: ChecklistItem
    let onToggle: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onToggle) {
                ZStack {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(item.checked ? Theme.doneGreen : Theme.textTertiary.opacity(0.5), lineWidth: 1.5)
                        .frame(width: 14, height: 14)
                    if item.checked {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Theme.doneGreen)
                            .frame(width: 14, height: 14)
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .heavy))
                            .foregroundStyle(.white)
                    }
                }
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())

            Text(item.label)
                .font(.system(size: 12))
                .foregroundStyle(item.checked ? Theme.textTertiary : Theme.textSecondary)
                .strikethrough(item.checked, color: Theme.textTertiary)
                .lineLimit(nil)
        }
    }
}

// MARK: - HabitStateBadge

struct HabitStateBadge: View {
    let state: String?

    var body: some View {
        if let s = state, s != "ok" {
            Text(s.uppercased())
                .font(.system(size: 9, weight: .bold))
                .tracking(0.4)
                .foregroundStyle(s == "overdue" ? Theme.priorityA : Theme.accent)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(
                        (s == "overdue" ? Theme.priorityA : Theme.accent).opacity(0.12)
                    )
                )
        }
    }
}

// MARK: - DashboardStripView

/// 14 small cells, left-to-right oldest-to-newest, for the Habits dashboard.
private struct DashboardStripView: View {
    let cells: [HabitCellState]
    let cadence: HabitCadence

    private let cellWidth: CGFloat = 14
    private let cellHeight: CGFloat = 8
    private let spacing: CGFloat = 2

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(color(for: cell))
                    .frame(width: cellWidth, height: cellHeight)
            }
        }
        .help("Each cell is one \(cadence.unitLabel). Oldest left, current period right.")
    }

    private func color(for cell: HabitCellState) -> Color {
        switch cell {
        case .done:     return Theme.doneGreen
        case .missed:   return Theme.priorityA.opacity(0.4)
        case .upcoming: return Theme.textTertiary.opacity(0.25)
        }
    }
}

// MARK: - HabitFormSheet

/// Sheet for creating or editing a DB-backed habit.
struct HabitFormSheet: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    let store: TasksStore
    let existingHabit: Habit?

    @State private var title: String = ""
    @State private var cadenceKind: String = "+"
    @State private var cadenceValue: Int = 1
    @State private var cadenceUnit: String = "d"
    @State private var hasRelaxed: Bool = false
    @State private var relaxedValue: Int = 2
    @State private var relaxedUnit: String = "d"
    @State private var category: String = ""
    @State private var priority: String = ""
    @State private var tags: String = ""
    @State private var notes: String = ""
    @State private var resetChecklistOnComplete: Bool = false
    @State private var isSaving: Bool = false
    @State private var saveError: String?

    private var isEditing: Bool { existingHabit != nil }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(isEditing ? "Edit Habit" : "New Habit")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape)
                Button(isEditing ? "Save" : "Create") {
                    Task { await save() }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
            }
            .padding(16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Title
                    LabeledContent("Title") {
                        TextField("e.g. Meditate", text: $title)
                            .textFieldStyle(.roundedBorder)
                    }

                    // Cadence
                    GroupBox("Cadence") {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 10) {
                                Picker("Kind", selection: $cadenceKind) {
                                    Text("+ (cumulative)").tag("+")
                                    Text("++ (strict)").tag("++")
                                    Text(".+ (minimum)").tag(".+")
                                }
                                .pickerStyle(.menu)
                                .frame(width: 160)

                                Stepper(value: $cadenceValue, in: 1...365) {
                                    Text("\(cadenceValue)")
                                        .monospacedDigit()
                                        .frame(width: 32, alignment: .trailing)
                                }

                                Picker("Unit", selection: $cadenceUnit) {
                                    Text("days").tag("d")
                                    Text("weeks").tag("w")
                                    Text("months").tag("m")
                                    Text("years").tag("y")
                                }
                                .pickerStyle(.menu)
                                .frame(width: 90)
                            }

                            Toggle("Relaxed range", isOn: $hasRelaxed)
                                .toggleStyle(.switch)

                            if hasRelaxed {
                                HStack(spacing: 10) {
                                    Text("Max:")
                                        .font(.system(size: 12))
                                        .foregroundStyle(Theme.textSecondary)
                                    Stepper(value: $relaxedValue, in: 1...365) {
                                        Text("\(relaxedValue)")
                                            .monospacedDigit()
                                            .frame(width: 32, alignment: .trailing)
                                    }
                                    Picker("Max unit", selection: $relaxedUnit) {
                                        Text("days").tag("d")
                                        Text("weeks").tag("w")
                                        Text("months").tag("m")
                                        Text("years").tag("y")
                                    }
                                    .pickerStyle(.menu)
                                    .frame(width: 90)
                                }
                            }
                        }
                        .padding(4)
                    }

                    // Optional fields
                    LabeledContent("Category") {
                        TextField("optional", text: $category)
                            .textFieldStyle(.roundedBorder)
                    }

                    LabeledContent("Priority") {
                        let priorityList = store.priorities?.all ?? ["A", "B", "C", "D"]
                        Picker("Priority", selection: $priority) {
                            Text("None").tag("")
                            ForEach(priorityList, id: \.self) { p in
                                Text(p).tag(p)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 90)
                    }

                    LabeledContent("Tags") {
                        TextField("comma-separated", text: $tags)
                            .textFieldStyle(.roundedBorder)
                    }

                    LabeledContent("Notes") {
                        TextEditor(text: $notes)
                            .font(.system(size: 13))
                            .frame(minHeight: 60)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .strokeBorder(Theme.borderSubtle, lineWidth: 0.5)
                            )
                    }

                    GroupBox("Checklist") {
                        Toggle("Reset checklist on completion", isOn: $resetChecklistOnComplete)
                            .toggleStyle(.switch)
                            .padding(4)
                    }

                    if let err = saveError {
                        Text(err)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.priorityA)
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 520)
        .frame(minHeight: 440)
        .onAppear { populateFromExisting() }
    }

    private func populateFromExisting() {
        guard let h = existingHabit else { return }
        title = h.title
        cadenceKind = h.cadence.kind
        cadenceValue = Int(h.cadence.value)
        cadenceUnit = h.cadence.unit
        if let mv = h.cadence.maxValue, let mu = h.cadence.maxUnit {
            hasRelaxed = true
            relaxedValue = Int(mv)
            relaxedUnit = mu
        }
        category = h.category ?? ""
        priority = h.priority ?? ""
        tags = h.tags.joined(separator: ", ")
        notes = h.notes ?? ""
        resetChecklistOnComplete = h.resetChecklistOnComplete
    }

    private func save() async {
        guard let client = settings.apiClient else { return }
        isSaving = true
        saveError = nil
        let spec = HabitCadenceSpec(
            kind: cadenceKind,
            value: Int64(cadenceValue),
            unit: cadenceUnit,
            maxValue: hasRelaxed ? Int64(relaxedValue) : nil,
            maxUnit: hasRelaxed ? relaxedUnit : nil
        )
        let tagList = tags
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let cat = category.trimmingCharacters(in: .whitespacesAndNewlines)
        let pri = priority.isEmpty ? nil : priority
        let notesStr = notes.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            if let existing = existingHabit {
                _ = try await client.updateHabit(
                    id: existing.id,
                    title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                    cadence: spec,
                    category: cat.isEmpty ? nil : cat,
                    priority: pri,
                    tags: tagList.isEmpty ? nil : tagList,
                    notes: notesStr.isEmpty ? nil : notesStr,
                    resetChecklistOnComplete: resetChecklistOnComplete
                )
            } else {
                _ = try await client.createHabit(
                    title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                    cadence: spec,
                    category: cat.isEmpty ? nil : cat,
                    priority: pri,
                    tags: tagList.isEmpty ? nil : tagList,
                    notes: notesStr.isEmpty ? nil : notesStr,
                    resetChecklistOnComplete: resetChecklistOnComplete
                )
            }
            await store.invalidateHabits(using: client)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
        isSaving = false
    }
}
