#if !os(macOS)
import SwiftUI

/// Unified home feed that merges Today, Pinned, and Upcoming into a single
/// continuous-scroll List. Section order: header block (scrolls away), then
/// PINNED, then today's Events, then today's Scheduled tasks, then Upcoming
/// day groups (tomorrow onward).
///
/// Dedup rule: tasks that appear in Pinned are suppressed from Scheduled and
/// Upcoming so each task appears exactly once in the feed.
struct HomeView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ClockManager.self) private var clocks
    let store: TasksStore

    @State private var expandedIds: Set<String> = []
    @State private var pinnedCollapsed: Bool = false

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

    // MARK: - Top-level content dispatcher

    @ViewBuilder
    private var content: some View {
        if !settings.isConfigured {
            VStack(spacing: 0) {
                headerBlock(chips: [], showClock: false)
                UnconfiguredStateView()
            }
            .background(Theme.background)
        } else if isLoading {
            VStack(spacing: 0) {
                headerBlock(chips: [], showClock: false)
                DelayedProgressView()
            }
            .background(Theme.background)
        } else if let errorMsg = firstError {
            VStack(spacing: 0) {
                headerBlock(chips: [], showClock: false)
                ErrorStateView(message: errorMsg) { Task { await load() } }
            }
            .background(Theme.background)
        } else {
            feedContent
        }
    }

    // MARK: - Full feed

    @ViewBuilder
    private var feedContent: some View {
        let todayEntries = store.today.value ?? []
        let allTasks = store.allTasks.value ?? []
        let upcomingEntries = store.upcoming.value ?? []
        let doneStates = Set((store.keywords?.allDone ?? []).map { $0.uppercased() })

        let classified = TodayClassifier.buildItems(
            today: todayEntries,
            all: allTasks,
            doneStates: doneStates,
            hideHabits: settings.hideHabitsInToday
        )
        let visibleEvents = classified.events.filter { !isEventHidden($0) }
        let mainSorted = sortTodayItems(classified.main, by: settings.agendaSort)

        let pinnedTasks = sortPinnedItems(
            allTasks.filter { TaskFilters.isPinnedToday($0) },
            by: settings.agendaSort
        )
        let pinnedIds = Set(pinnedTasks.map { $0.id })

        // Suppress pinned ids from scheduled list and upcoming list.
        let scheduledItems = mainSorted.filter { !pinnedIds.contains($0.id) }

        let upcomingFiltered = filteredUpcoming(upcomingEntries, excludingIds: pinnedIds)
        let upcomingGroups = upcomingDayGroups(upcomingFiltered)

        let chips = buildChips(main: classified.main, doneStates: doneStates, allTasks: allTasks)
        let openCount = scheduledItems.filter { isOpen($0, doneStates: doneStates) }.count
        let doneCount = scheduledItems.filter { isDone($0, doneStates: doneStates) }.count
        let overdueCount = scheduledItems.filter { TodayClassifier.isOverdue($0) }.count

        List {
            // Header block — inside the List so it scrolls away with content.
            // Zero row chrome so it looks like a VStack header.
            Section {
                headerBlock(chips: chips, showClock: !clocks.sessions.isEmpty)
                    .listRowBackground(Theme.background)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
            }

            // PINNED section
            if !pinnedTasks.isEmpty {
                Section {
                    if !pinnedCollapsed {
                        ForEach(pinnedTasks) { task in
                            TaskRowItem(
                                task: task, doneStates: doneStates, store: store,
                                expandedIds: $expandedIds
                            )
                            .listRowBackground(Theme.background)
                            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                            .listRowSeparatorTint(Theme.borderSubtle)
                        }
                    }
                } header: {
                    collapsibleHeader(
                        title: "PINNED",
                        count: pinnedTasks.count,
                        collapsed: pinnedCollapsed
                    ) {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            pinnedCollapsed.toggle()
                        }
                    }
                }
            }

            // Today's Events section
            if !visibleEvents.isEmpty {
                Section {
                    ForEach(visibleEvents) { entry in
                        CompactEventRow(entry: entry)
                            .listRowBackground(Theme.background)
                            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                            .listRowSeparatorTint(Theme.borderSubtle)
                    }
                } header: {
                    simpleHeader(text: "Events")
                }
            }

            // Scheduled (today) section
            Section {
                if scheduledItems.isEmpty && visibleEvents.isEmpty && pinnedTasks.isEmpty {
                    EmptyStateView(title: "Nothing scheduled for today", systemImage: "sparkles")
                        .listRowBackground(Theme.background)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(scheduledItems, id: \.id) { item in
                        TaskRowItem(
                            task: item, doneStates: doneStates, store: store,
                            expandedIds: $expandedIds
                        )
                        .listRowBackground(Theme.background)
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                        .listRowSeparatorTint(Theme.borderSubtle)
                    }
                }
            } header: {
                scheduledHeader(open: openCount, done: doneCount, overdue: overdueCount)
            }

            // Upcoming day groups (tomorrow onward)
            ForEach(upcomingGroups, id: \.key) { group in
                Section {
                    ForEach(sortTasks(group.items, by: settings.agendaSort)) { entry in
                        if AgendaEntryClassification.isEvent(entry) {
                            CompactEventRow(entry: entry)
                                .listRowBackground(Theme.background)
                                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                                .listRowSeparatorTint(Theme.borderSubtle)
                        } else {
                            TaskRowItem(
                                task: entry, doneStates: doneStates, store: store,
                                expandedIds: $expandedIds
                            )
                            .listRowBackground(Theme.background)
                            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                            .listRowSeparatorTint(Theme.borderSubtle)
                        }
                    }
                } header: {
                    DayGroupHeader(group: group)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
    }

    // MARK: - Header block (scrolls with content)

    @ViewBuilder
    private func headerBlock(chips: [SummaryChip], showClock: Bool) -> some View {
        VStack(spacing: 0) {
            LargePageHeader(pretitle: "TODAY", title: dateTitle)
            if showClock {
                ClockCard(store: store)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 8)
            }
            if !chips.isEmpty {
                SummaryChipStrip(chips: chips)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 6)
            }
        }
    }

    // MARK: - Section headers

    @ViewBuilder
    private func collapsibleHeader(
        title: String,
        count: Int,
        collapsed: Bool,
        onTap: @escaping () -> Void
    ) -> some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Text("\(title) \u{00B7} \(count)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Solid fill so scrolling content doesn't bleed through the sticky header.
            .background(Theme.background)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .textCase(nil)
        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 0, trailing: 0))
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
                 ? "\(open) open \u{00B7} \(overdue) overdue \u{00B7} \(done) done"
                 : "\(open) open \u{00B7} \(done) done")
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

    // MARK: - Data helpers

    private var dateTitle: String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMM d"
        return f.string(from: Date())
    }

    private var isLoading: Bool {
        store.today.isLoading || store.allTasks.isLoading || store.upcoming.isLoading
    }

    private var firstError: String? {
        store.today.error ?? store.allTasks.error ?? store.upcoming.error
    }

    private func isEventHidden(_ entry: AgendaEntry) -> Bool {
        let hidden = settings.hiddenEventTags
        guard !hidden.isEmpty else { return false }
        for tag in entry.tags where hidden.contains(tag) { return true }
        for tag in entry.inheritedTags where hidden.contains(tag) { return true }
        return false
    }

    private func isOpen(_ item: any TaskDisplayable, doneStates: Set<String>) -> Bool {
        guard let s = item.todoState, !s.isEmpty else { return false }
        return !doneStates.contains(s.uppercased())
    }

    private func isDone(_ item: any TaskDisplayable, doneStates: Set<String>) -> Bool {
        guard let s = item.todoState else { return false }
        return doneStates.contains(s.uppercased())
    }

    /// Sort the mixed Today list.
    ///
    /// .default ("Agenda"): overdue items first (by scheduled time), then the
    /// rest also by scheduled time. This mirrors the classic org-agenda view.
    ///
    /// Any other key: sort the entire list flat — no overdue-floats-to-top
    /// special case — so Priority/Category/etc. work across the whole set.
    private func sortTodayItems(_ items: [any TaskDisplayable], by key: SortKey) -> [any TaskDisplayable] {
        if key == .default {
            let overdue = items.filter { TodayClassifier.isOverdue($0) }
            let due = items.filter { !TodayClassifier.isOverdue($0) }
            let byScheduled: (any TaskDisplayable, any TaskDisplayable) -> Bool = { a, b in
                let at = scheduledMs(a)
                let bt = scheduledMs(b)
                return at < bt
            }
            return overdue.sorted(by: byScheduled) + due.sorted(by: byScheduled)
        }
        return sortByKey(items, key: key)
    }

    /// Sort pinned tasks by the agenda sort key.
    ///
    /// Pinned items have no overdue concept (they are pinned, not overdue-floated),
    /// so .default falls through to a scheduled-time sort for a sensible stable order.
    private func sortPinnedItems(_ items: [OrgTask], by key: SortKey) -> [OrgTask] {
        if key == .default {
            return items.sorted { scheduledMs($0) < scheduledMs($1) }
        }
        return sortByKey(items, key: key).compactMap { $0 as? OrgTask }
    }

    /// Milliseconds since epoch for an item's scheduled (or deadline) timestamp.
    /// Returns .infinity for items with no timestamp so they sort last.
    private func scheduledMs(_ item: any TaskDisplayable) -> Double {
        if let raw = item.scheduled?.raw, !raw.isEmpty,
           let d = OrgTimestamp.parseDateString(raw) {
            return d.timeIntervalSince1970 * 1000
        }
        if let raw = item.deadline?.raw, !raw.isEmpty,
           let d = OrgTimestamp.parseDateString(raw) {
            return d.timeIntervalSince1970 * 1000
        }
        return .infinity
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
            case .category:
                return a.category.localizedCompare(b.category) == .orderedAscending
            case .state:
                return (a.todoState ?? "") < (b.todoState ?? "")
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

    private func buildChips(
        main: [any TaskDisplayable],
        doneStates: Set<String>,
        allTasks: [OrgTask]
    ) -> [SummaryChip] {
        let overdue = main.filter { TodayClassifier.isOverdue($0) }.count
        let todayCount = main.count - overdue
        var chips: [SummaryChip] = [
            SummaryChip(label: "Today", number: "\(todayCount)"),
            SummaryChip(
                label: "Overdue",
                number: "\(overdue)",
                trailingSymbol: overdue > 0 ? "exclamationmark.triangle.fill" : nil,
                trailingSymbolColor: Theme.priorityA
            ),
        ]
        let habits = allTasks.filter { $0.isHabit }
        if !habits.isEmpty {
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

    /// Filter upcoming entries: suppress hidden-event tags and exclude pinned task ids.
    private func filteredUpcoming(_ entries: [AgendaEntry], excludingIds pinnedIds: Set<String>) -> [AgendaEntry] {
        let hidden = settings.hiddenEventTags
        return entries.filter { entry in
            if pinnedIds.contains(entry.id) { return false }
            if AgendaEntryClassification.isEvent(entry) {
                if !hidden.isEmpty {
                    if entry.tags.contains(where: hidden.contains) { return false }
                    if entry.inheritedTags.contains(where: hidden.contains) { return false }
                }
            }
            return true
        }
    }

    /// Group upcoming entries by day, skipping today's group (today is shown above).
    private func upcomingDayGroups(_ entries: [AgendaEntry]) -> [DayGroup] {
        let todayKey = DateQuery.today()
        let groups = upcomingGroupByDay(entries)
        return groups.filter { $0.key != todayKey }
    }

    // MARK: - Load

    private func load() async {
        guard let client = settings.apiClient else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await store.loadToday(using: client) }
            group.addTask { await store.loadAllTasks(using: client, includeDone: false) }
            group.addTask { await store.loadUpcoming(using: client) }
            group.addTask { await store.refreshClock(using: client) }
        }
    }

    private func loadIfNeeded() async {
        if store.today.value == nil || store.allTasks.value == nil || store.upcoming.value == nil {
            await load()
        }
    }
}

// MARK: - Day grouping (mirrors UpcomingView.groupByDay, lifted here to avoid
// a reference to the now-removed UpcomingView struct)

private struct DayGroup {
    let key: String
    let dayNumber: String?
    let label: String
    let relative: String?
    let items: [AgendaEntry]
}

private let isoFormatter: DateFormatter = {
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .gregorian)
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    return f
}()

private let weekdayFormatter: DateFormatter = {
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .gregorian)
    f.locale = Locale.current
    f.dateFormat = "EEEE"
    return f
}()

private let dayNumFormatter: DateFormatter = {
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .gregorian)
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "d"
    return f
}()

private func upcomingGroupByDay(_ entries: [AgendaEntry]) -> [DayGroup] {
    let cal = Calendar.current
    let now = cal.startOfDay(for: Date())

    return TaskFilters.groupAgendaEntriesByDay(entries).map { bucket in
        let key = bucket.key
        guard let date = isoFormatter.date(from: key) else {
            return DayGroup(key: key, dayNumber: nil, label: key, relative: nil, items: bucket.items)
        }
        let startOfDate = cal.startOfDay(for: date)
        let dayNumber = dayNumFormatter.string(from: date)
        let weekday = weekdayFormatter.string(from: date)

        let dayDelta = cal.dateComponents([.day], from: now, to: startOfDate).day ?? 0
        let label: String
        let relative: String?
        switch dayDelta {
        case 0:
            label = "Today"
            relative = nil
        case 1:
            label = "Tomorrow"
            relative = nil
        case 2...6:
            label = weekday
            relative = "IN \(dayDelta) DAYS"
        case 7...13:
            label = weekday
            relative = "NEXT WEEK"
        case 14...27:
            label = weekday
            relative = "IN \(dayDelta) DAYS"
        case 28...:
            label = weekday
            relative = "LATER"
        default:
            label = weekday
            relative = nil
        }
        return DayGroup(key: key, dayNumber: dayNumber, label: label, relative: relative, items: bucket.items)
    }
}

// MARK: - DayGroupHeader (private to HomeView — mirrors the one in UpcomingView)

private struct DayGroupHeader: View {
    let group: DayGroup

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let dn = group.dayNumber {
                Text(dn)
                    .font(.system(size: 22, weight: .bold))
                    .monospacedDigit()
                    .tracking(-0.22)
                    .foregroundStyle(Theme.textPrimary)
            }
            Text(group.label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 8)
            if let rel = group.relative {
                Text(rel)
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.0)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.bottom, 4)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.borderSubtle)
                .frame(height: 0.5)
        }
        .textCase(nil)
        .listRowInsets(EdgeInsets(top: 18, leading: 18, bottom: 4, trailing: 16))
    }
}
#endif
