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
    @State private var expandedHabitIds: Set<String> = []
    @State private var pinnedCollapsed: Bool = false
    /// Precomputed feed sections. Rebuilt only when inputs change (see .onChange
    /// modifiers below), not on every body evaluation.
    @State private var feedModel: HomeFeedModel = .empty

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
        // Rebuild feedModel only when the relevant inputs change.
        // Fingerprinting captures content mutations (state/pin changes) not just
        // count changes — avoids the optimistic-patch case where the array length
        // stays the same but a habit flips done/undone.
        .onChange(of: todayFingerprint) { _, _ in rebuildFeedModel() }
        .onChange(of: allTasksFingerprint) { _, _ in rebuildFeedModel() }
        .onChange(of: upcomingFingerprint) { _, _ in rebuildFeedModel() }
        .onChange(of: habitsFingerprint) { _, _ in rebuildFeedModel() }
        .onChange(of: settings.agendaSort) { _, _ in rebuildFeedModel() }
        .onChange(of: settings.hideHabitsInToday) { _, _ in rebuildFeedModel() }
        .onChange(of: settings.hiddenEventTags) { _, _ in rebuildFeedModel() }
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

    // MARK: - Model rebuild (runs off the critical render path)

    private func rebuildFeedModel() {
        let todayEntries = store.today.value ?? []
        let allTasks = store.allTasks.value ?? []
        let upcomingEntries = store.upcoming.value ?? []
        let habits = store.habits.value ?? []
        let doneStates = Set((store.keywords?.allDone ?? []).map { $0.uppercased() })
        let sort = settings.agendaSort
        let hideHabits = settings.hideHabitsInToday
        let hiddenTags = settings.hiddenEventTags

        let classified = TodayClassifier.buildItems(
            today: todayEntries,
            all: allTasks,
            doneStates: doneStates,
            hideHabits: hideHabits
        )
        let visibleEvents = dedupeAgendaEntries(
            classified.events.filter { entry in
                guard !hiddenTags.isEmpty else { return true }
                if entry.tags.contains(where: hiddenTags.contains) { return false }
                if entry.inheritedTags.contains(where: hiddenTags.contains) { return false }
                return true
            }
        )
        let mainSorted = sortTodayItems(classified.main, by: sort)
        let pinnedTasks = sortPinnedItems(
            allTasks.filter { TaskFilters.isPinnedToday($0) },
            by: sort
        )
        let pinnedIds = Set(pinnedTasks.map { $0.id })
        let scheduledItems = mainSorted.filter { !pinnedIds.contains($0.id) }
        let upcomingFiltered = filteredUpcoming(upcomingEntries, excludingIds: pinnedIds, hiddenTags: hiddenTags)
        let upcomingGroups = upcomingDayGroups(upcomingFiltered)
        let chips = buildChips(main: classified.main, doneStates: doneStates, allTasks: allTasks, habits: habits, hideHabits: hideHabits)
        let openCount = scheduledItems.filter { isOpen($0, doneStates: doneStates) }.count
        let doneCount = scheduledItems.filter { isDone($0, doneStates: doneStates) }.count
        let overdueCount = scheduledItems.filter { TodayClassifier.isOverdue($0) }.count
        let dueHabits: [Habit] = hideHabits ? [] : dueHabitsToday(habits)
        let combinedItems = buildCombinedItems(tasks: scheduledItems, habits: dueHabits, by: sort)

        feedModel = HomeFeedModel(
            doneStates: doneStates,
            chips: chips,
            pinnedTasks: pinnedTasks,
            visibleEvents: visibleEvents,
            combinedItems: combinedItems,
            openCount: openCount,
            doneCount: doneCount,
            overdueCount: overdueCount,
            upcomingGroups: upcomingGroups,
            agendaSort: sort
        )
    }

    // MARK: - Full feed

    @ViewBuilder
    private var feedContent: some View {
        let m = feedModel

        List {
            // Header block — inside the List so it scrolls away with content.
            // Zero row chrome so it looks like a VStack header.
            Section {
                headerBlock(chips: m.chips, showClock: !clocks.sessions.isEmpty)
                    .listRowBackground(Theme.background)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
            }

            // PINNED section
            if !m.pinnedTasks.isEmpty {
                Section {
                    if !pinnedCollapsed {
                        ForEach(m.pinnedTasks) { task in
                            TaskRowItem(
                                task: task, doneStates: m.doneStates, store: store,
                                expandedIds: $expandedIds
                            )
                            .listRowBackground(Theme.surface)
                            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                            .listRowSeparatorTint(Theme.borderSubtle)
                        }
                    }
                } header: {
                    collapsibleHeader(
                        title: "MY DAY",
                        count: m.pinnedTasks.count,
                        collapsed: pinnedCollapsed
                    ) {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            pinnedCollapsed.toggle()
                        }
                    }
                }
            }

            // Events section — rendered immediately after MY DAY pinned block.
            // All events sit in a single card row (EventCardView) so SwiftUI's
            // per-row minimum height applies once, not once per event.
            if !m.visibleEvents.isEmpty {
                Section {
                    EventCardView(entries: m.visibleEvents)
                        .listRowBackground(Theme.background)
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 8, trailing: 16))
                        .listRowSeparator(.hidden)
                } header: {
                    eventsHeader
                }
            }

            Section {
                if m.combinedItems.isEmpty && m.visibleEvents.isEmpty && m.pinnedTasks.isEmpty {
                    EmptyStateView(title: "Nothing scheduled for today", systemImage: "sparkles")
                        .listRowBackground(Theme.background)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(m.combinedItems) { item in
                        switch item {
                        case .task(let t):
                            TaskRowItem(
                                task: t, doneStates: m.doneStates, store: store,
                                expandedIds: $expandedIds
                            )
                            .listRowBackground(Theme.surface)
                            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                            .listRowSeparatorTint(Theme.borderSubtle)
                        case .habit(let h):
                            HabitExpandableRow(
                                habit: h,
                                store: store,
                                expandedIds: $expandedHabitIds
                            )
                            .listRowBackground(Theme.surface)
                            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                            .listRowSeparatorTint(Theme.borderSubtle)
                        }
                    }
                }
            } header: {
                scheduledHeader(open: m.openCount, done: m.doneCount, overdue: m.overdueCount)
            }

            // Upcoming day groups (tomorrow onward)
            ForEach(m.upcomingGroups, id: \.key) { group in
                Section {
                    // Dedupe per-group: a heading with both SCHEDULED and DEADLINE
                    // on the same day arrives as two AgendaEntry objects sharing
                    // the same file::pos id — keep one so ids are unique for ForEach.
                    let deduped = dedupeAgendaEntries(group.items)
                    // Events render above tasks within each day group, mirroring
                    // the main Today section layout.
                    let groupEvents = deduped.filter { AgendaEntryClassification.isEvent($0) }
                    let groupTasks = sortTasks(deduped.filter { !AgendaEntryClassification.isEvent($0) }, by: m.agendaSort)
                    if !groupEvents.isEmpty {
                        EventCardView(entries: groupEvents)
                            .listRowBackground(Theme.background)
                            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: groupTasks.isEmpty ? 8 : 6, trailing: 16))
                            .listRowSeparator(.hidden)
                    }
                    ForEach(groupTasks) { entry in
                        TaskRowItem(
                            task: entry, doneStates: m.doneStates, store: store,
                            expandedIds: $expandedIds
                        )
                        .listRowBackground(Theme.surface)
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                        .listRowSeparatorTint(Theme.borderSubtle)
                    }
                } header: {
                    DayGroupHeader(group: group)
                }
            }
        }
        .listStyle(.plain)
        // Collapse SwiftUI's default inter-section gap (plain List still adds ~18pt
        // between sections on iOS 17). Each section header already carries its own
        // top inset so the visual rhythm is preserved.
        .listSectionSpacing(0)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .onAppear { rebuildFeedModel() }
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

    /// Events section header. When the user has hidden calendar tags,
    /// shows a "Show hidden (N)" button so they can restore without going
    /// to Settings.
    @ViewBuilder
    private var eventsHeader: some View {
        HStack(spacing: 8) {
            Text("Events")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            let hiddenCount = settings.hiddenEventTags.count
            if hiddenCount > 0 {
                Button {
                    settings.hiddenEventTags = []
                } label: {
                    Label("Show hidden (\(hiddenCount))", systemImage: "eye")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
            }
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

    /// Lightweight fingerprints used by `.onChange` to detect when content
    /// actually changed (including optimistic patches that don't change array
    /// length). Cheap to compute — just concatenate the ids and a few key fields.
    private var todayFingerprint: String {
        (store.today.value ?? []).map { "\($0.id):\($0.todoState ?? "")" }.joined(separator: ",")
    }
    private var allTasksFingerprint: String {
        (store.allTasks.value ?? []).map { "\($0.id):\($0.todoState ?? ""):\($0.properties?["PINNED"] ?? "")" }.joined(separator: ",")
    }
    private var upcomingFingerprint: String {
        (store.upcoming.value ?? []).map { $0.id }.joined(separator: ",")
    }
    private var habitsFingerprint: String {
        // Includes a hash of `notes` and `priority` so that mutations which
        // DON'T change state/completions still rebuild the memoized feed —
        // notably a checklist toggle (which only edits notes). Without the
        // notes hash the toggled row never re-rendered and the tap appeared to
        // do nothing (only the button highlight "flashed").
        (store.habits.value ?? []).map {
            "\($0.id):\($0.state ?? ""):\($0.priority ?? ""):\($0.completions.first ?? ""):\((($0.notes ?? "")).hashValue)"
        }.joined(separator: ",")
    }

    private var dateTitle: String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMM d"
        return f.string(from: Date())
    }

    private var isLoading: Bool {
        store.today.isLoading || store.allTasks.isLoading || store.upcoming.isLoading
    }

    private var hasAnyContent: Bool {
        store.today.value != nil || store.allTasks.value != nil || store.upcoming.value != nil
    }

    /// Escalate to a full-screen error only on a true cold failure — when no
    /// slice has any cached content. With stale-while-revalidate, a refresh
    /// failure keeps last-good content loaded and surfaces via the RootView
    /// connection/staleness banner instead of blanking the whole feed.
    private var firstError: String? {
        guard !hasAnyContent else { return nil }
        return store.today.error ?? store.allTasks.error ?? store.upcoming.error
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
        allTasks: [OrgTask],
        habits: [Habit],
        hideHabits: Bool
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
        // Habit summary chip: show due/overdue count from the DB-backed habits
        // store when habits are visible in Today.
        if !hideHabits && !habits.isEmpty {
            let due = dueHabitsToday(habits)
            // isDoneThisCycle is server-truth (anchored on nextDue); avoids
            // monthly-habit inflation from HabitMath calendar-period comparison.
            let doneToday = habits.filter { $0.isDoneThisCycle }.count
            if !due.isEmpty || doneToday > 0 {
                chips.append(SummaryChip(
                    label: "Habits",
                    number: "\(doneToday)/\(habits.count)",
                    trailingSymbol: due.isEmpty ? nil : "exclamationmark.circle.fill",
                    trailingSymbolColor: Theme.accent
                ))
            }
        }
        return chips
    }

    /// Filter upcoming entries: suppress hidden-event tags, exclude pinned task ids,
    /// and drop habit entries (habits are DB-managed and shown only in the Habits tab).
    private func filteredUpcoming(
        _ entries: [AgendaEntry],
        excludingIds pinnedIds: Set<String>,
        hiddenTags: Set<String> = []
    ) -> [AgendaEntry] {
        return entries.filter { entry in
            if pinnedIds.contains(entry.id) { return false }
            if entry.isHabit { return false }
            if AgendaEntryClassification.isEvent(entry) {
                if !hiddenTags.isEmpty {
                    if entry.tags.contains(where: hiddenTags.contains) { return false }
                    if entry.inheritedTags.contains(where: hiddenTags.contains) { return false }
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

    // MARK: - Combined task+habit list

    /// Merges scheduled tasks and due habits into one sorted list.
    ///
    /// Merges scheduled tasks and due habits into one sorted list.
    ///
    /// `.default`: overdue items float to the top, then the rest sort by scheduled/nextDue
    /// time + title. Non-default keys sort the unified list so habits with a given priority
    /// appear among tasks of the same priority — a habit with priority B sorts alongside
    /// tasks of priority B, not appended after all tasks.
    private func buildCombinedItems(
        tasks: [any TaskDisplayable],
        habits: [Habit],
        by key: SortKey
    ) -> [TodayItem] {
        let taskItems = tasks.map { TodayItem.task($0) }
        let habitItems = habits.map { TodayItem.habit($0) }
        let all = taskItems + habitItems

        if key == .default {
            let overdue = all.filter { item in
                switch item {
                case .task(let t): return TodayClassifier.isOverdue(t)
                case .habit(let h): return h.state == "overdue"
                }
            }
            let rest = all.filter { item in
                switch item {
                case .task(let t): return !TodayClassifier.isOverdue(t)
                case .habit(let h): return h.state != "overdue"
                }
            }
            return overdue.sorted(by: todayItemTimeOrder) + rest.sorted(by: todayItemTimeOrder)
        }

        // For non-default sort keys, build a unified list so habits with a given
        // priority appear among tasks of the same priority, not appended after.
        return all.sorted { a, b in
            switch key {
            case .priority:
                let rA = todayItemPriorityRank(a)
                let rB = todayItemPriorityRank(b)
                if rA != rB { return rA < rB }
                // Secondary: scheduled/nextDue time, then title.
                let tA = todayItemMs(a)
                let tB = todayItemMs(b)
                if tA != tB { return tA < tB }
                return todayItemTitle(a) < todayItemTitle(b)
            case .scheduled:
                let tA = todayItemMs(a)
                let tB = todayItemMs(b)
                if tA != tB { return tA < tB }
                return todayItemTitle(a) < todayItemTitle(b)
            case .deadline:
                let dA: String
                let dB: String
                switch a {
                case .task(let t): dA = t.deadline?.raw ?? t.scheduled?.raw ?? ""
                case .habit(let h): dA = h.nextDue ?? ""
                }
                switch b {
                case .task(let t): dB = t.deadline?.raw ?? t.scheduled?.raw ?? ""
                case .habit(let h): dB = h.nextDue ?? ""
                }
                if dA != dB { return dA < dB }
                return todayItemTitle(a) < todayItemTitle(b)
            case .category:
                let cA: String
                let cB: String
                switch a {
                case .task(let t): cA = t.category
                case .habit(let h): cA = h.category ?? ""
                }
                switch b {
                case .task(let t): cB = t.category
                case .habit(let h): cB = h.category ?? ""
                }
                if cA != cB { return cA.localizedCompare(cB) == .orderedAscending }
                return todayItemTitle(a) < todayItemTitle(b)
            case .state:
                let sA: String
                let sB: String
                switch a {
                case .task(let t): sA = t.todoState ?? ""
                case .habit(let h): sA = h.state ?? ""
                }
                switch b {
                case .task(let t): sB = t.todoState ?? ""
                case .habit(let h): sB = h.state ?? ""
                }
                if sA != sB { return sA < sB }
                return todayItemTitle(a) < todayItemTitle(b)
            case .default:
                return false
            }
        }
    }

    /// Comparison by effective timestamp: scheduled (or nextDue for habits) ascending,
    /// then title ascending as tiebreak.
    private func todayItemTimeOrder(_ a: TodayItem, _ b: TodayItem) -> Bool {
        let at = todayItemMs(a)
        let bt = todayItemMs(b)
        if at != bt { return at < bt }
        return todayItemTitle(a) < todayItemTitle(b)
    }

    private func todayItemPriorityRank(_ item: TodayItem) -> Int {
        switch item {
        case .task(let t):  return priorityRank(t.priority)
        case .habit(let h): return habitPriorityRank(h.priority)
        }
    }

    private func todayItemMs(_ item: TodayItem) -> Double {
        switch item {
        case .task(let t):  return scheduledMs(t)
        case .habit(let h):
            guard let nd = h.nextDue, !nd.isEmpty,
                  let d = OrgTimestamp.parseDateString(nd)
            else { return .infinity }
            return d.timeIntervalSince1970 * 1000
        }
    }

    private func todayItemTitle(_ item: TodayItem) -> String {
        switch item {
        case .task(let t):  return t.title
        case .habit(let h): return h.title
        }
    }

    // MARK: - Load

    private func load() async {
        guard let client = settings.apiClient else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await store.loadToday(using: client) }
            group.addTask { await store.loadAllTasks(using: client, includeDone: false) }
            group.addTask { await store.loadUpcoming(using: client) }
            group.addTask { await store.refreshClock(using: client) }
            group.addTask { await store.loadHabits(using: client) }
        }
    }

    private func loadIfNeeded() async {
        if store.today.value == nil || store.allTasks.value == nil || store.upcoming.value == nil {
            await load()
        }
    }
}

// MARK: - HomeFeedModel: precomputed feed sections, rebuilt only when inputs change

/// All the data that `feedContent` needs, computed once per relevant input change
/// rather than on every body re-evaluation. Stored in `@State` so SwiftUI does not
/// re-derive it on unrelated state writes (e.g. `expandedIds` changes).
private struct HomeFeedModel {
    let doneStates: Set<String>
    let chips: [SummaryChip]
    let pinnedTasks: [OrgTask]
    let visibleEvents: [AgendaEntry]
    let combinedItems: [TodayItem]
    let openCount: Int
    let doneCount: Int
    let overdueCount: Int
    let upcomingGroups: [DayGroup]
    let agendaSort: SortKey

    static let empty = HomeFeedModel(
        doneStates: [],
        chips: [],
        pinnedTasks: [],
        visibleEvents: [],
        combinedItems: [],
        openCount: 0,
        doneCount: 0,
        overdueCount: 0,
        upcomingGroups: [],
        agendaSort: .default
    )
}

// MARK: - TodayItem: unified task+habit row type for the combined Today list

private enum TodayItem: Identifiable {
    case task(any TaskDisplayable)
    case habit(Habit)

    var id: String {
        switch self {
        case .task(let t):  return "task-\(t.id)"
        case .habit(let h): return "habit-\(h.id)"
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
