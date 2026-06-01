#if !os(macOS)
import SwiftUI

// MARK: - HabitsView (streak dashboard)

/// Read-only analytics dashboard for DB-backed habits.
///
/// Each row shows: title + 14-cell consistency strip + current streak +
/// best streak + completion %. No checkbox or swipe-to-complete actions
/// are present here — the actionable rows live in All Tasks.
///
/// Tapping a row opens the edit sheet (so title/cadence edits are still
/// reachable from this tab). The "+" toolbar button opens the new-habit
/// capture sheet.
struct HabitsView: View {
    @Environment(AppSettings.self) private var settings
    let store: TasksStore

    @State private var showNewHabit = false
    @State private var editingHabit: Habit? = nil

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(Theme.background, for: .navigationBar)
                .background(Theme.background)
                .refreshable { await load() }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showNewHabit = true
                        } label: {
                            Image(systemName: "plus.circle")
                                .font(.system(size: 17))
                        }
                        .disabled(!settings.isConfigured)
                    }
                }
        }
        .sheet(isPresented: $showNewHabit) {
            IOSHabitFormSheet(store: store, existingHabit: nil)
                .environment(settings)
        }
        .sheet(item: $editingHabit) { habit in
            IOSHabitFormSheet(store: store, existingHabit: habit)
                .environment(settings)
        }
        .task(id: settings.serverURLString) { await loadIfNeeded() }
    }

    @ViewBuilder
    private var content: some View {
        if !settings.isConfigured {
            VStack(spacing: 0) {
                LargePageHeader(pretitle: nil, title: "Habits")
                UnconfiguredStateView()
            }
            .background(Theme.background)
        } else if let habits = store.habits.value {
            if habits.isEmpty {
                VStack(spacing: 0) {
                    LargePageHeader(pretitle: nil, title: "Habits")
                    EmptyStateView(title: "No habits yet", systemImage: "arrow.triangle.2.circlepath")
                }
                .background(Theme.background)
            } else {
                dashboard(habits)
            }
        } else if store.habits.isLoading {
            VStack(spacing: 0) {
                LargePageHeader(pretitle: nil, title: "Habits")
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Theme.background)
        } else if let msg = store.habits.error {
            VStack(spacing: 0) {
                LargePageHeader(pretitle: nil, title: "Habits")
                ErrorStateView(message: msg) { Task { await load() } }
            }
            .background(Theme.background)
        } else {
            Color.clear
        }
    }

    // MARK: - Dashboard

    private func dashboard(_ habits: [Habit]) -> some View {
        // Compute each habit's stats exactly once: used for chips, sort, and row rendering.
        let statsMap: [String: HabitStats] = Dictionary(
            uniqueKeysWithValues: habits.map { ($0.id, HabitMath.stats(for: $0)) }
        )
        // isDoneThisCycle is server-truth (anchored on nextDue), avoiding
        // inflation from monthly habits that calendar-period math would double-count.
        let doneToday = habits.filter { $0.isDoneThisCycle }.count
        let bestStreak = statsMap.values.map { $0.currentStreak }.max() ?? 0
        let totalCells = statsMap.values.reduce(0) { $0 + $1.cells.count }
        let doneCells = statsMap.values.reduce(0) { $0 + $1.cells.filter { $0 == .done }.count }
        let rate: Int = totalCells > 0 ? Int(round(Double(doneCells) / Double(totalCells) * 100)) : 0

        let chips: [SummaryChip] = [
            SummaryChip(label: "Today", number: "\(doneToday)/\(habits.count)"),
            SummaryChip(
                label: "Best streak",
                number: "\(bestStreak)",
                trailingSymbol: bestStreak > 0 ? "flame.fill" : nil,
                trailingSymbolColor: Theme.priorityB
            ),
            SummaryChip(label: "30-day rate", number: "\(rate)%"),
        ]

        // Sort by current streak descending using the precomputed dict (one stats call per
        // habit, not two per comparison), then alphabetically.
        let sorted = habits.sorted { a, b in
            let sA = statsMap[a.id]?.currentStreak ?? 0
            let sB = statsMap[b.id]?.currentStreak ?? 0
            if sA != sB { return sA > sB }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }

        return VStack(spacing: 0) {
            LargePageHeader(pretitle: nil, title: "Habits")
            SummaryChipStrip(chips: chips)
                .padding(.horizontal, 18)
                .padding(.bottom, 6)
            List {
                ForEach(sorted) { habit in
                    HabitDashboardRow(habit: habit, stats: statsMap[habit.id] ?? HabitMath.stats(for: habit))
                        .contentShape(Rectangle())
                        .onTapGesture { editingHabit = habit }
                        .listRowBackground(Theme.surface)
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                        .listRowSeparatorTint(Theme.borderSubtle)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.background)
        }
        .background(Theme.background)
    }

    // MARK: - Loads

    private func load() async {
        guard let client = settings.apiClient else { return }
        await store.loadHabits(using: client)
    }

    private func loadIfNeeded() async {
        if store.habits.value == nil { await load() }
    }
}

// MARK: - HabitDashboardRow

/// Compact read-only stats row for the Habits dashboard.
///
/// Layout: title | consistency strip | streak | best | rate%
/// No checkbox, no swipe actions. Tapping the enclosing list row opens edit.
///
/// `stats` is passed in from the dashboard to avoid recomputing HabitMath
/// per-body evaluation (the parent already built a [id: HabitStats] dict).
private struct HabitDashboardRow: View {
    let habit: Habit
    let stats: HabitStats

    var body: some View {
        let ratePercent = Int(round(stats.completionRate * 100))

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let priority = habit.priority, !priority.isEmpty {
                    PriorityBadge(priority: priority)
                }
                Text(habit.title)
                    .font(.body)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

            // 14-cell consistency strip
            ConsistencyStrip(cells: stats.cells)

            HStack(spacing: 12) {
                // Current streak
                HStack(spacing: 3) {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(stats.currentStreak > 0 ? Theme.priorityB : Theme.textTertiary)
                    Text(stats.streakLabel)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(stats.currentStreak > 0 ? Theme.doneGreen : Theme.textTertiary)
                }
                // Best streak
                HStack(spacing: 3) {
                    Image(systemName: "trophy.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                    Text(stats.bestLabel)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Theme.textTertiary)
                }
                // Completion rate
                Text("\(ratePercent)%")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 8)
    }
}

// MARK: - ConsistencyStrip

/// 14 small cells, left-to-right oldest-to-newest.
/// .done → doneGreen, .missed → priorityA-tinted, .upcoming → textTertiary/hollow.
private struct ConsistencyStrip: View {
    let cells: [HabitCellState]

    private let cellWidth: CGFloat = 14
    private let cellHeight: CGFloat = 8
    private let spacing: CGFloat = 2

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                RoundedRectangle(cornerRadius: 2)
                    .fill(color(for: cell))
                    .frame(width: cellWidth, height: cellHeight)
            }
        }
    }

    private func color(for cell: HabitCellState) -> Color {
        switch cell {
        case .done:     return Theme.doneGreen
        case .missed:   return Theme.priorityA.opacity(0.4)
        case .upcoming: return Theme.textTertiary.opacity(0.25)
        }
    }
}

// MARK: - Cadence label helpers (shared by HabitExpandableRow)

/// Compact cadence badge: "🔁 1d", "🔁 2w", "🔁 1–2w" (for relaxed range).
func cadenceBadgeLabel(_ spec: HabitCadenceSpec) -> String {
    let minPart = compactCadenceUnit(value: spec.value, unit: spec.unit)
    if let mv = spec.maxValue, let mu = spec.maxUnit {
        let maxPart = compactCadenceUnit(value: mv, unit: mu)
        return "\u{1F501} \(minPart)\u{2013}\(maxPart)"
    }
    return "\u{1F501} \(minPart)"
}

/// Kept for call sites that need the plain unit string without the badge prefix.
func compactCadenceUnit(value: Int64, unit: String) -> String {
    switch unit.lowercased() {
    case "w": return "\(value)w"
    case "m": return "\(value)mo"
    case "y": return "\(value)y"
    default:  return "\(value)d"
    }
}

/// Relative due-date label for a habit row.
///
/// For a relaxed cadence (maxValue present), the shown date is the deadline:
/// `nextDue + (max interval − min interval)`. That is the last day before the
/// habit is considered missed. For all other cadence kinds, show nextDue directly.
func habitDueDateLabel(_ habit: Habit) -> String? {
    guard let nd = habit.nextDue, !nd.isEmpty,
          let base = OrgTimestamp.parseDateString(nd) else { return nil }

    let displayDate: Date
    if let mv = habit.cadence.maxValue, let mu = habit.cadence.maxUnit {
        // Compute each interval length in days relative to a fixed epoch so
        // we can subtract them. Use base as the epoch for both.
        let cal = Calendar.current
        guard let minEnd = cal.date(byAdding: habitDC(Int(habit.cadence.value), habit.cadence.unit), to: base),
              let maxEnd = cal.date(byAdding: habitDC(Int(mv), mu), to: base)
        else { return DateBadge.relativeLabel(for: base) }
        let extraDays = cal.dateComponents([.day], from: minEnd, to: maxEnd).day ?? 0
        displayDate = cal.date(byAdding: .day, value: extraDays, to: base) ?? base
    } else {
        displayDate = base
    }
    return DateBadge.relativeLabel(for: displayDate)
}

func habitDC(_ value: Int, _ unit: String) -> DateComponents {
    var dc = DateComponents()
    switch unit.lowercased() {
    case "w": dc.weekOfYear = value
    case "m": dc.month = value
    case "y": dc.year = value
    default:  dc.day = value
    }
    return dc
}

// MARK: - IOSHabitFormSheet

/// iOS sheet for creating or editing a DB-backed habit.
struct IOSHabitFormSheet: View {
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
    // Guards populateFromExisting so background→foreground transitions while
    // the sheet is open don't clobber in-progress edits (onAppear re-fires).
    @State private var didPopulate: Bool = false

    private var isEditing: Bool { existingHabit != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("e.g. Meditate", text: $title)
                }

                Section("Cadence") {
                    Picker("Kind", selection: $cadenceKind) {
                        Text("+ cumulative").tag("+")
                        Text("++ strict").tag("++")
                        Text(".+ minimum").tag(".+")
                    }
                    Stepper("Every \(cadenceValue)", value: $cadenceValue, in: 1...365)
                    Picker("Unit", selection: $cadenceUnit) {
                        Text("days").tag("d")
                        Text("weeks").tag("w")
                        Text("months").tag("m")
                        Text("years").tag("y")
                    }
                    Toggle("Relaxed range", isOn: $hasRelaxed)
                    if hasRelaxed {
                        Stepper("Up to \(relaxedValue)", value: $relaxedValue, in: 1...365)
                        Picker("Max unit", selection: $relaxedUnit) {
                            Text("days").tag("d")
                            Text("weeks").tag("w")
                            Text("months").tag("m")
                            Text("years").tag("y")
                        }
                    }
                }

                Section("Optional") {
                    TextField("Category", text: $category)
                    Picker("Priority", selection: $priority) {
                        Text("None").tag("")
                        Text("A").tag("A")
                        Text("B").tag("B")
                        Text("C").tag("C")
                    }
                    TextField("Tags (comma-separated)", text: $tags)
                }

                Section("Notes") {
                    TextEditor(text: $notes)
                        .frame(minHeight: 80)
                }

                Section("Checklist") {
                    Toggle("Reset checklist on completion", isOn: $resetChecklistOnComplete)
                }

                if let err = saveError {
                    Section {
                        Text(err)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.priorityA)
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Habit" : "New Habit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Save" : "Create") {
                        Task { await save() }
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                }
            }
        }
        .onAppear {
            guard !didPopulate else { return }
            didPopulate = true
            populateFromExisting()
        }
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
#endif
