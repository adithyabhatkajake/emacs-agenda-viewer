import SwiftUI

struct TodayView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ClockManager.self) private var clocks
    let store: TasksStore

    @State private var expandedIds: Set<String> = []

    var body: some View {
        @Bindable var bindable = settings
        NavigationStack {
            content
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(Theme.background, for: .navigationBar)
                .background(Theme.background)
                .refreshable { await load() }
                .toolbar {
                    SortMenuToolbar(options: SortKey.agendaOptions, selection: $bindable.agendaSort)
                }
        }
        .captureFAB(store: store)
        .task(id: settings.serverURLString) { await loadIfNeeded() }
    }

    private var dateTitle: String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMM d"
        return f.string(from: Date())
    }

    @ViewBuilder
    private var content: some View {
        if !settings.isConfigured {
            VStack(spacing: 0) {
                LargePageHeader(pretitle: "TODAY", title: dateTitle)
                UnconfiguredStateView()
            }
            .background(Theme.background)
        } else if let entries = store.today.value {
            agendaContent(entries)
        } else if store.today.isLoading {
            VStack(spacing: 0) {
                LargePageHeader(pretitle: "TODAY", title: dateTitle)
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Theme.background)
        } else if let msg = store.today.error {
            VStack(spacing: 0) {
                LargePageHeader(pretitle: "TODAY", title: dateTitle)
                ErrorStateView(message: msg) { Task { await load() } }
            }
            .background(Theme.background)
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private func agendaContent(_ entries: [AgendaEntry]) -> some View {
        let doneStates = Set((store.keywords?.allDone ?? []).map { $0.uppercased() })
        let classified = TodayClassifier.buildItems(
            today: entries,
            all: store.allTasks.value ?? [],
            doneStates: doneStates,
            hideHabits: settings.hideHabitsInToday
        )
        // The classifier doesn't know about hidden-event-tags (that's a view
        // concern); filter those out after the fact so the events bucket
        // still respects the user's calendar mute list.
        let visibleEvents = classified.events.filter { !isEventHidden($0) }
        let items = TodayItems(events: visibleEvents, main: classified.main)
        let mainSorted = sortTodayItems(items.main, by: settings.agendaSort)
        let chips = summaryChips(items: items, doneStates: doneStates)
        let openCount = items.main.filter { isOpen($0, doneStates: doneStates) }.count
        let doneCount = items.main.filter { isDone($0, doneStates: doneStates) }.count
        let overdueCount = items.main.filter { isOverdue($0) }.count

        VStack(spacing: 0) {
            LargePageHeader(pretitle: "TODAY", title: dateTitle)
            if !clocks.sessions.isEmpty {
                ClockCard(store: store)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 8)
            }
            SummaryChipStrip(chips: chips)
                .padding(.horizontal, 18)
                .padding(.bottom, 6)
            if items.main.isEmpty && items.events.isEmpty {
                EmptyStateView(title: "Nothing scheduled for today", systemImage: "sparkles")
            } else {
                List {
                    if !items.events.isEmpty {
                        Section {
                            ForEach(items.events) { entry in
                                EventRow(entry: entry)
                                    .listRowBackground(Theme.background)
                                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                                    .listRowSeparatorTint(Theme.borderSubtle)
                            }
                        } header: {
                            simpleHeader(text: "Events")
                        }
                    }
                    Section {
                        ForEach(mainSorted, id: \.id) { item in
                            taskRow(for: item, doneStates: doneStates)
                        }
                    } header: {
                        scheduledHeader(open: openCount, done: doneCount, overdue: overdueCount)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Theme.background)
            }
        }
        .background(Theme.background)
    }

    @ViewBuilder
    private func taskRow(for item: any TaskDisplayable, doneStates: Set<String>) -> some View {
        TaskRowItem(
            task: item, doneStates: doneStates, store: store,
            expandedIds: $expandedIds
        )
        .listRowBackground(Theme.background)
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        .listRowSeparatorTint(Theme.borderSubtle)
    }

    @ViewBuilder
    private func simpleHeader(text: String) -> some View {
        HStack(spacing: 8) {
            Text(text)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Sticky section header — needs a solid fill so scrolling content
        // doesn't bleed through. `.listRowInsets` zeroed so the background
        // fills edge-to-edge.
        .background(Theme.background)
        .textCase(nil)
        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 0, trailing: 0))
    }

    @ViewBuilder
    private func scheduledHeader(open: Int, done: Int, overdue: Int) -> some View {
        HStack(spacing: 8) {
            Text("Scheduled")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(overdue > 0
                 ? "\(open) open · \(overdue) overdue · \(done) done"
                 : "\(open) open · \(done) done")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
            Spacer()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.background)
        .textCase(nil)
        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 0, trailing: 0))
    }

    // MARK: - Item assembly

    /// Local convenience wrapper around `TodayClassifier.TodayItems` — the
    /// view holds onto it after applying its tag-based event filter so the
    /// chip strip and section headers can share counts.
    private struct TodayItems {
        let events: [AgendaEntry]
        let main: [any TaskDisplayable]
    }

    /// Sort the mixed `[any TaskDisplayable]` Today list. Overdue items
    /// (scheduled in the past) always float to the top regardless of the
    /// chosen sort key — they need attention. Within each bucket, defer to
    /// the regular sortTasks behavior.
    private func sortTodayItems(_ items: [any TaskDisplayable], by key: SortKey) -> [any TaskDisplayable] {
        let overdue = items.filter { isOverdue($0) }
        let due = items.filter { !isOverdue($0) }

        let overdueSorted = sortByScheduledAsc(overdue)
        let dueSorted = sortByKey(due, key: key)

        return overdueSorted + dueSorted
    }

    private func sortByScheduledAsc(_ items: [any TaskDisplayable]) -> [any TaskDisplayable] {
        items.sorted { a, b in
            (a.scheduled?.raw ?? "") < (b.scheduled?.raw ?? "")
        }
    }

    private func sortByKey(_ items: [any TaskDisplayable], key: SortKey) -> [any TaskDisplayable] {
        guard key != .default else { return items }
        return items.sorted { a, b in
            switch key {
            case .priority:
                return priorityRank(a.priority) < priorityRank(b.priority)
            case .scheduled:
                return (a.scheduled?.raw ?? "") < (b.scheduled?.raw ?? "")
            case .deadline:
                let ar = a.deadline?.raw ?? a.scheduled?.raw ?? ""
                let br = b.deadline?.raw ?? b.scheduled?.raw ?? ""
                return ar < br
            case .state:
                return (a.todoState ?? "") < (b.todoState ?? "")
            case .category:
                return a.category.localizedCompare(b.category) == .orderedAscending
            case .default:
                return false
            }
        }
    }

    private func priorityRank(_ p: String?) -> Int {
        switch p?.uppercased() {
        case "A": return 0
        case "B": return 1
        case "C": return 2
        case "D": return 3
        default:  return 4
        }
    }

    /// True when any of the entry's direct or inherited tags is in the
    /// user's hidden-event-tags set. Used to suppress entire calendars
    /// (e.g. "HarshithaDEPTcalendar") from the Events list without losing
    /// other calendars' entries.
    private func isEventHidden(_ entry: AgendaEntry) -> Bool {
        let hidden = settings.hiddenEventTags
        guard !hidden.isEmpty else { return false }
        for tag in entry.tags where hidden.contains(tag) { return true }
        for tag in entry.inheritedTags where hidden.contains(tag) { return true }
        return false
    }

    private func isOverdue(_ item: any TaskDisplayable) -> Bool {
        TodayClassifier.isOverdue(item)
    }

    private func isOpen(_ item: any TaskDisplayable, doneStates: Set<String>) -> Bool {
        guard let s = item.todoState, !s.isEmpty else { return false }
        return !doneStates.contains(s.uppercased())
    }

    private func isDone(_ item: any TaskDisplayable, doneStates: Set<String>) -> Bool {
        guard let s = item.todoState else { return false }
        return doneStates.contains(s.uppercased())
    }

    private func summaryChips(items: TodayItems, doneStates: Set<String>) -> [SummaryChip] {
        // The agenda endpoint already filters done items, so "open count" =
        // "total" = useless redundant denominator. Split the metric into the
        // two things you actually act on:
        //   • Today  — items that are due/scheduled today (drive-by work)
        //   • Overdue — items already past their scheduled date (debt)
        let overdue = items.main.filter { isOverdue($0) }.count
        let todayCount = items.main.count - overdue

        var chips: [SummaryChip] = [
            SummaryChip(label: "Today", number: "\(todayCount)"),
            SummaryChip(
                label: "Overdue",
                number: "\(overdue)",
                trailingSymbol: overdue > 0 ? "exclamationmark.triangle.fill" : nil,
                trailingSymbolColor: Theme.priorityA
            ),
        ]
        if let habits = store.allTasks.value?.filter({ $0.isHabit }), !habits.isEmpty {
            let best = habits.map { habit in
                HabitMath.stats(
                    completions: habit.completions,
                    repeater: habit.scheduled?.repeater ?? habit.deadline?.repeater,
                    lastRepeat: habit.properties?["LAST_REPEAT"]
                ).currentStreak
            }.max() ?? 0
            chips.append(SummaryChip(
                label: "Streak",
                number: "\(best)",
                trailingSymbol: best > 0 ? "flame.fill" : nil,
                trailingSymbolColor: Theme.priorityB
            ))
        }
        return chips
    }

    private func load() async {
        guard let client = settings.apiClient else { return }
        await store.loadToday(using: client)
        // Overdue scheduled tasks live in /api/tasks; load them so the Today
        // list can pull them in even when the user hasn't visited another
        // view that loads allTasks first.
        await store.loadAllTasks(using: client, includeDone: false)
        await store.refreshClock(using: client)
    }

    private func loadIfNeeded() async {
        if store.today.value == nil || store.allTasks.value == nil { await load() }
    }
}
