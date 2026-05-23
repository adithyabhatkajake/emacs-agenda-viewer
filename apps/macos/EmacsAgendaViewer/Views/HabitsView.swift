#if !os(macOS)
import SwiftUI

/// iOS dashboard for `:STYLE: habit` headings. Groups habits by cadence
/// bucket (Today / This Week / This Month / This Year / Other), shows a
/// current-streak count and a 14-period completion strip per habit.
/// Mirrors MacHabitsView; uses the shared HabitMath / HabitsGrouping
/// compute layer — no duplication of the bucketing or stats math here.
struct HabitsView: View {
    @Environment(AppSettings.self) private var settings
    let store: TasksStore

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(Theme.background, for: .navigationBar)
                .background(Theme.background)
                .refreshable { await load() }
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
        } else if let tasks = store.allTasks.value {
            let habits = tasks.filter { $0.isHabit }
            if habits.isEmpty {
                VStack(spacing: 0) {
                    LargePageHeader(pretitle: nil, title: "Habits")
                    EmptyStateView(title: "No habits", systemImage: "repeat.circle")
                }
                .background(Theme.background)
            } else {
                habitList(habits)
            }
        } else if store.allTasks.isLoading {
            VStack(spacing: 0) {
                LargePageHeader(pretitle: nil, title: "Habits")
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Theme.background)
        } else if let msg = store.allTasks.error {
            VStack(spacing: 0) {
                LargePageHeader(pretitle: nil, title: "Habits")
                ErrorStateView(message: msg) { Task { await load() } }
            }
            .background(Theme.background)
        } else {
            Color.clear
        }
    }

    private func habitList(_ habits: [OrgTask]) -> some View {
        let buckets = HabitsGrouping.buckets(habits: habits)
        let doneStates = Set((store.keywords?.allDone ?? []).map { $0.uppercased() })
        let stats = habits.map { habit in
            HabitMath.stats(
                completions: habit.completions,
                repeater: habit.scheduled?.repeater ?? habit.deadline?.repeater,
                lastRepeat: habit.properties?["LAST_REPEAT"]
            )
        }
        let doneToday = stats.filter { $0.cells.last == .done }.count
        let bestStreak = stats.map { $0.currentStreak }.max() ?? 0
        let totalCells = stats.reduce(0) { $0 + $1.cells.count }
        let doneCells = stats.reduce(0) { $0 + $1.cells.filter { $0 == .done }.count }
        let rate: Int = totalCells > 0 ? Int(round(Double(doneCells) / Double(totalCells) * 100)) : 0

        let dailyStreaks = zip(habits, stats).compactMap { habit, s -> Int? in
            let unit = (habit.scheduled?.repeater?.unit ?? habit.deadline?.repeater?.unit)?.lowercased()
            return unit == "d" ? s.currentStreak : nil
        }
        let avgStreak: Int = dailyStreaks.isEmpty
            ? 0
            : Int(round(Double(dailyStreaks.reduce(0, +)) / Double(dailyStreaks.count)))

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

        return VStack(spacing: 0) {
            LargePageHeader(
                pretitle: dailyStreaks.isEmpty ? nil : "Streak · \(avgStreak)d avg",
                title: "Habits"
            )
            SummaryChipStrip(chips: chips)
                .padding(.horizontal, 18)
                .padding(.bottom, 6)
            List {
                ForEach(buckets, id: \.title) { bucket in
                    Section {
                        ForEach(bucket.habits, id: \.id) { habit in
                            NavigationLink {
                                TaskDetailView(task: habit, doneStates: doneStates, store: store)
                            } label: {
                                HabitRowView(habit: habit)
                            }
                            .listRowBackground(Theme.background)
                            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                            .listRowSeparatorTint(Theme.borderSubtle)
                        }
                    } header: {
                        bucketHeader(bucket: bucket)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.background)
        }
        .background(Theme.background)
    }

    @ViewBuilder
    private func bucketHeader(bucket: HabitBucket) -> some View {
        let doneCount = HabitsGrouping.doneCount(bucket.habits)
        let total = bucket.habits.count
        let allDone = doneCount == total && total > 0
        HStack(spacing: 6) {
            Text(bucket.title.uppercased())
                .font(.system(size: 11, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(Theme.textPrimary)
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
        .padding(.vertical, 2)
        .textCase(nil)
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
    }

    private func load() async {
        guard let client = settings.apiClient else { return }
        await store.loadAllTasks(using: client, includeDone: false)
    }

    private func loadIfNeeded() async {
        if store.allTasks.value == nil { await load() }
    }
}

/// One row in the iOS habits list. Shows: title (with done styling),
/// streak count (current / best), and a 14-period completion strip.
private struct HabitRowView: View {
    let habit: OrgTask

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
        VStack(alignment: .leading, spacing: 6) {
            // Title row with streak alongside
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(habit.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(isDoneThisPeriod ? Theme.textTertiary : Theme.textPrimary)
                    .strikethrough(isDoneThisPeriod, color: Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                // Current streak (colored) + best streak below it
                VStack(alignment: .trailing, spacing: 1) {
                    Text(s.streakLabel)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(s.currentStreak == 0 ? Theme.textTertiary : Theme.doneGreen)
                    Text("best \(s.bestLabel)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            // 14-period completion strip
            HabitsStripView(cells: s.cells, cadence: s.cadence)
        }
        .padding(.vertical, 8)
        .opacity(isDoneThisPeriod ? 0.55 : 1.0)
        .contentShape(Rectangle())
    }
}

/// Horizontal cell strip for the iOS habits row.
/// Each cell is a small rounded square: green = done, faint = missed,
/// outlined = current period not yet completed.
private struct HabitsStripView: View {
    let cells: [HabitCellState]
    let cadence: HabitCadence

    private let cellSize: CGFloat = 13
    private let cellSpacing: CGFloat = 2

    var body: some View {
        HStack(spacing: cellSpacing) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                cellShape(cell)
                    .frame(width: cellSize, height: cellSize)
            }
        }
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
#endif
