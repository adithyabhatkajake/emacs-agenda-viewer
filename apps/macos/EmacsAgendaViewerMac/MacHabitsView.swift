import SwiftUI

/// Dashboard for `:STYLE: habit` headings. One row per habit: title,
/// streak in cadence-periods, a strip of period cells (oldest left,
/// newest right), completion ratio, and a checkbox to mark today's
/// period done. Mark/unmark goes through the same `toggleDone` mutation
/// every other view uses, so the org file stays the single source of
/// truth.
struct MacHabitsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(Selection.self) private var selection
    @Environment(ClockManager.self) private var clocks
    @Environment(CalendarSync.self) private var sync
    let store: TasksStore

    @State private var searchText = ""

    var body: some View {
        content
            .navigationTitle("Habits")
            .searchable(text: $searchText, placement: .toolbar, prompt: "Search habits")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    ReloadButton(action: { Task { await load() } }, disabled: !settings.isConfigured)
                }
            }
            .task(id: settings.serverURLString) { await loadIfNeeded() }
    }

    @ViewBuilder
    private var content: some View {
        if !settings.isConfigured {
            UnconfiguredStateView()
        } else if let tasks = store.allTasks.value {
            let habits = filter(tasks)
            if habits.isEmpty {
                EmptyStateView(
                    title: searchText.isEmpty
                        ? "No habits yet"
                        : "No matches",
                    systemImage: searchText.isEmpty
                        ? "arrow.triangle.2.circlepath"
                        : "magnifyingglass"
                )
            } else {
                list(habits)
            }
        } else if store.allTasks.isLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let msg = store.allTasks.error {
            ErrorStateView(message: msg) { Task { await load() } }
        } else {
            Color.clear
        }
    }

    private func filter(_ tasks: [OrgTask]) -> [OrgTask] {
        let habits = tasks.filter { $0.isHabit }
        guard !searchText.isEmpty else { return habits }
        let needle = searchText.lowercased()
        return habits.filter { task in
            task.title.lowercased().contains(needle)
                || task.category.lowercased().contains(needle)
        }
    }

    private func list(_ habits: [OrgTask]) -> some View {
        // Bucket by cadence so the dashboard reads "what do I need to do
        // *today*", "what's *this week*", and so on. Daily habits feel
        // urgent (every day is a checkpoint); weekly/monthly/yearly each
        // have their own rhythm and deserve visual separation.
        let buckets = HabitsGrouping.buckets(habits: habits)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(buckets, id: \.title) { bucket in
                    let done = HabitsGrouping.doneCount(bucket.habits)
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(bucket.habits, id: \.id) { habit in
                                HabitRow(habit: habit, store: store, selection: selection,
                                         settings: settings, clocks: clocks, sync: sync)
                            }
                        }
                    } header: {
                        sectionHeader(title: bucket.title,
                                      doneCount: done,
                                      total: bucket.habits.count)
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, minHeight: 600, alignment: .leading)
        }
        .background(Theme.background)
    }

    @ViewBuilder
    private func sectionHeader(title: String, doneCount: Int, total: Int) -> some View {
        let allDone = doneCount == total && total > 0
        HStack(spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(Theme.textPrimary)
            // "3 / 8 done" — readable at a glance, drops "done" when
            // everything in the bucket is settled (the green tick
            // covers it). Monospaced numerals so the slash centers.
            HStack(spacing: 3) {
                if allDone {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.doneGreen)
                    Text("\(total) / \(total)")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.doneGreen)
                } else {
                    Text("\(doneCount) / \(total)")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(doneCount > 0 ? Theme.doneGreen : Theme.textTertiary)
                    Text("done")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            Spacer()
        }
        .padding(.leading, 4)
        .padding(.bottom, 4)
    }

    private func load() async {
        guard let client = settings.apiClient else { return }
        await store.ensureInitialized(using: client, settings: settings)
        await store.loadAllTasks(using: client, includeDone: false)
    }

    private func loadIfNeeded() async {
        if store.allTasks.value == nil { await load() }
    }
}

// `HabitBucket` + `HabitsGrouping` moved to the shared
// `EmacsAgendaViewer/State/HabitStats.swift` so iOS HabitsView can share
// the same grouping logic. Mac code keeps using the same symbols.

/// One row on the habits dashboard. Owns nothing — all state lives in
/// the store + per-habit math runs lazily on render.
private struct HabitRow: View {
    let habit: OrgTask
    let store: TasksStore
    let selection: Selection
    let settings: AppSettings
    let clocks: ClockManager
    let sync: CalendarSync?

    @State private var isHovering = false

    private var stats: HabitStats {
        HabitMath.stats(
            completions: habit.completions,
            repeater: habit.scheduled?.repeater ?? habit.deadline?.repeater,
            lastRepeat: habit.properties?["LAST_REPEAT"]
        )
    }

    private var isDoneThisPeriod: Bool {
        stats.cells.last == .done
    }

    var body: some View {
        let s = stats
        // Single horizontal row of fixed-width columns so titles, streak
        // labels, strips, and percentages line up across every habit
        // regardless of title length. Earlier layout stacked the strip
        // under the title-line (VStack), which kept strips at the SAME
        // leading X but let the streak/best text drift with title width;
        // this collapses everything into one columnar row.
        HStack(alignment: .center, spacing: 12) {
            // Done indicator that actually reads as DONE: solid green
            // circle with a white checkmark glyph, instead of the old
            // green-dot-inside-empty-ring style which was too subtle to
            // spot in a list of 16 rows. The empty state stays the
            // same — outlined circle, click target.
            Button(action: toggleToday) {
                ZStack {
                    if isDoneThisPeriod {
                        Circle()
                            .fill(Theme.doneGreen)
                            .frame(width: 20, height: 20)
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .heavy))
                            .foregroundStyle(.white)
                    } else {
                        Circle()
                            .strokeBorder(Theme.textTertiary.opacity(0.5), lineWidth: 1.5)
                            .frame(width: 20, height: 20)
                    }
                }
            }
            .buttonStyle(.plain)
            .help(isDoneThisPeriod
                  ? "Done this period — click to toggle back to TODO."
                  : "Mark this period's habit done.")

            // Title column. Fixed width so the streak column starts at
            // the same X across every row. Truncates with ellipsis when
            // the title is longer than the column. When done this period
            // the title fades to secondary text so the user can scan the
            // not-yet-done rows by their darker titles alone.
            Text(habit.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isDoneThisPeriod ? Theme.textTertiary : Theme.textPrimary)
                .strikethrough(isDoneThisPeriod, color: Theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 240, alignment: .leading)

            // Streak column: current streak (colored), best streak below
            // it (muted). Two-line stack keeps the row compact and the
            // numbers monospaced for visual alignment.
            VStack(alignment: .trailing, spacing: 1) {
                Text(s.streakLabel)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(streakColor(s.currentStreak))
                Text("best \(s.bestLabel)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
            }
            .frame(width: 56, alignment: .trailing)

            // Strip column. Fixed cellSize means rows with the same
            // window length render identical widths; daily / weekly /
            // monthly cadences each get their own width but always
            // start at the same X.
            StripView(cells: s.cells, cadence: s.cadence)

            Spacer(minLength: 8)

            // Completion-rate column, right-aligned.
            Text(String(format: "%.0f%%", s.completionRate * 100))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 40, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(rowBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Theme.borderSubtle, lineWidth: 0.5)
        )
        // Visually dismiss done rows — the user has already done the
        // work for this period, so the row should recede so the still-
        // pending rows above it command attention. 0.45 opacity is
        // dim enough to read "settled" without making the checkmark
        // unreadable when the user wants to undo.
        .opacity(isDoneThisPeriod ? 0.45 : 1.0)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(count: 1) {
            // Single-click on the row body selects the underlying task —
            // the user can then use the regular task surfaces (refile,
            // schedule, etc.) without going through the habits view.
            selection.taskId = habit.id
        }
    }

    /// Green when on a streak, gray when at zero. We deliberately don't
    /// use red — habits are a positive game, not a punitive one.
    private func streakColor(_ n: Int) -> Color {
        n == 0 ? Theme.textTertiary : Theme.doneGreen
    }

    /// Row background. We deliberately don't tint done rows green
    /// anymore — `opacity(0.45)` on the whole row achieves the
    /// "settled, recede" treatment cleanly, and a green wash on top of
    /// that read as too busy.
    private var rowBackground: Color {
        isHovering ? Theme.surface.opacity(0.6) : Theme.surface.opacity(0.35)
    }

    private func toggleToday() {
        // Reuse the row-action machinery instead of writing a fresh
        // mutation: it already handles clock-out side-effects, calendar
        // sync, and SSE-driven refresh coalescing.
        let factory = RowActionFactory(
            store: store, settings: settings, selection: selection,
            clocks: clocks, sync: sync
        )
        let actions = factory.make(for: habit)
        actions.toggleDone()
    }
}

/// The horizontal cell strip. Cell colors:
///   · upcoming → outlined circle (current period, not done yet)
///   · done     → solid green
///   · missed   → dim gray
/// Cells get smaller as the window grows so 14-day and 12-week strips
/// occupy similar visual width.
private struct StripView: View {
    let cells: [HabitCellState]
    let cadence: HabitCadence

    /// Fixed cell size across all cadences. Because every row also uses
    /// the same window length (`HabitCadence.defaultWindow`), this
    /// guarantees that the Nth cell of every row sits at the same X —
    /// daily / weekly / monthly habits all align cell-for-cell.
    private let cellSize: CGFloat = 14
    private let cellSpacing: CGFloat = 3

    var body: some View {
        HStack(spacing: cellSpacing) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                cellShape(cell)
                    .frame(width: cellSize, height: cellSize)
            }
        }
        .help("Each cell is one \(cadence.unitLabel). Oldest left, current period right.")
    }

    @ViewBuilder
    private func cellShape(_ state: HabitCellState) -> some View {
        let radius: CGFloat = 3
        switch state {
        case .done:
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Theme.doneGreen)
        case .missed:
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Theme.textTertiary.opacity(0.18))
        case .upcoming:
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Theme.accent.opacity(0.7), lineWidth: 1.5)
        }
    }
}
