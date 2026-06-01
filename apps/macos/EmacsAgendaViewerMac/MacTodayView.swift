import SwiftUI

struct MacTodayView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(Selection.self) private var selection
    @Environment(ClockManager.self) private var clocks
    @Environment(CalendarSync.self) private var sync
    let store: TasksStore

    @State private var collapsedGroups: Set<String> = []

    var body: some View {
        @Bindable var bindable = settings
        content
            .navigationTitle(todayTitle)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    SortMenu(options: SortKey.agendaOptions, selection: $bindable.agendaSort)
                }
                ToolbarItem(placement: .primaryAction) {
                    GroupMenu(primary: $bindable.agendaGroup, secondary: $bindable.agendaGroupSecondary)
                }
                ToolbarItem(placement: .primaryAction) {
                    ReloadButton(action: { Task { await load() } }, disabled: !settings.isConfigured)
                }
            }
            .task(id: settings.serverURLString) { await loadIfNeeded() }
    }

    private var todayTitle: String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMM d"
        return f.string(from: Date())
    }

    @ViewBuilder
    private var content: some View {
        if !settings.isConfigured {
            UnconfiguredStateView()
        } else if let entries = store.today.value {
            if entries.isEmpty {
                EmptyStateView(title: "Nothing scheduled for today", systemImage: "sparkles")
            } else {
                agendaList(entries)
            }
        } else if store.today.isLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let msg = store.today.error {
            ErrorStateView(message: msg) { Task { await load() } }
        } else {
            Color.clear
        }
    }

    private func agendaList(_ entries: [AgendaEntry]) -> some View {
        let doneStates = Set((store.keywords?.allDone ?? []).map { $0.uppercased() })
        // Canonical Today rule (same as iOS): upcoming-deadlines are dropped,
        // done tasks are dropped, overdue scheduled is pulled from /api/tasks.
        // Mac's timed-schedule + grouped-untimed layout is built on top.
        let classified = TodayClassifier.buildItems(
            today: entries,
            all: store.allTasks.value ?? [],
            doneStates: doneStates,
            hideHabits: true   // org-task habit rows always suppressed; DB habits shown inline
        )
        let events = classified.events
        // The classifier returns `main` as `[any TaskDisplayable]` — a mix of
        // `AgendaEntry` (today-anchored) and `OrgTask` (overdue pulls). The
        // Mac timed-schedule layout reads minutesOfDay off AgendaEntry; overdue
        // OrgTask rows are all-day by nature, so we route them to the untimed
        // bucket so they appear in the grouped task list under the schedule.
        var todayAgendaEntries: [AgendaEntry] = []
        var overdueOrgTasks: [OrgTask] = []
        for item in classified.main {
            if let a = item as? AgendaEntry { todayAgendaEntries.append(a) }
            else if let t = item as? OrgTask { overdueOrgTasks.append(t) }
        }

        var allDayEvents: [AgendaEntry] = []
        var scheduleItems: [(min: Int, item: ScheduleItem)] = []
        var untimedTasks: [AgendaEntry] = []

        for e in events {
            if let m = MacTodayView.minutesOfDay(e) {
                scheduleItems.append((m, .event(e)))
            } else {
                allDayEvents.append(e)
            }
        }
        for t in todayAgendaEntries {
            if let m = MacTodayView.minutesOfDay(t) {
                scheduleItems.append((m, .task(t)))
            } else {
                untimedTasks.append(t)
            }
        }
        scheduleItems.sort { $0.min < $1.min }

        // dueHabitsToday already excludes done-this-period habits.
        let dueHabits: [Habit] = settings.hideHabitsInToday ? [] : dueHabitsToday(store.habits.value ?? [])
        let sortedUntimed = sortTasks(untimedTasks, by: settings.agendaSort)
        let sortedOverdue = sortTasks(overdueOrgTasks, by: .scheduled)
        let factory = RowActionFactory(store: store, settings: settings, selection: selection, clocks: clocks, sync: sync)
        let totalTasks = scheduleItems.filter { if case .task = $0.item { return true }; return false }.count + sortedUntimed.count + sortedOverdue.count + dueHabits.count
        let totalEvents = scheduleItems.filter { if case .event = $0.item { return true }; return false }.count + allDayEvents.count

        // Habits are always merged with tasks by the same grouping key.
        // When groupKey == .none the flat combined list is produced; when a
        // groupKey is active, mixedGroups places each habit in the group whose
        // key matches the habit's priority/category/etc., matching iOS behavior.
        let combinedItems = buildMacCombinedItems(tasks: sortedUntimed, habits: dueHabits, by: settings.agendaSort)
        let eisCtx = EisenhowerGroupContext(urgencyDays: settings.eisenhowerUrgencyDays, priorities: store.priorities)
        let mixedGroups = groupMixedItems(combinedItems, by: settings.agendaGroup, eisenhower: eisCtx)

        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    dayHead(tasks: totalTasks, events: totalEvents, habits: store.habits.value ?? [])
                    // All-day events: compact card, rendered right after the header.
                    if !allDayEvents.isEmpty {
                        CompactEventCard(entries: allDayEvents)
                    }
                    if !sortedOverdue.isEmpty {
                        overdueSection(sortedOverdue, doneStates: doneStates, factory: factory)
                    }
                    // Timed schedule (events + timed tasks interleaved by time-of-day).
                    if !scheduleItems.isEmpty {
                        scheduleSection(scheduleItems, doneStates: doneStates, factory: factory)
                    }
                    // Unified untimed tasks + due habits, grouped by the active key.
                    if !combinedItems.isEmpty {
                        mixedGroupedSection(
                            mixedGroups,
                            doneStates: doneStates,
                            factory: factory,
                            groupKey: settings.agendaGroup
                        )
                    }
                }
                .padding(.horizontal, 32)
                .padding(.top, 22)
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity, minHeight: 600, alignment: .leading)
                .background(
                    Rectangle()
                        .fill(Theme.background)
                        .contentShape(Rectangle())
                        .onTapGesture { selection.taskId = nil }
                )
            }
            .background(Theme.background)
            .onChange(of: selection.revealTaskId) { _, new in
                consumeReveal(new, proxy: proxy)
            }
            .onAppear { consumeReveal(selection.revealTaskId, proxy: proxy) }
        }
    }

    private func consumeReveal(_ id: String?, proxy: ScrollViewProxy) {
        guard let id else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            proxy.scrollTo(id, anchor: .center)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            if selection.revealTaskId == id { selection.revealTaskId = nil }
        }
    }

    private static let dayHeadFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMM d"
        return f
    }()

    @ViewBuilder
    private func dayHead(tasks: Int, events: Int, habits: [Habit]) -> some View {
        let dayLabel = MacTodayView.dayHeadFormatter.string(from: Date())
        let dueCount = dueHabitsToday(habits).count
        let doneToday = habits.filter { HabitsGroupingNew.isDoneThisPeriod($0) }.count
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text("TODAY")
                    .font(.system(size: 11, weight: .heavy))
                    .tracking(0.6)
                    .foregroundStyle(Theme.accent)
                HStack(alignment: .lastTextBaseline, spacing: 12) {
                    Text(dayLabel)
                        .font(.system(size: 22, weight: .bold))
                        .tracking(-0.4)
                        .foregroundStyle(Theme.textPrimary)
                    Text("\(tasks) task\(tasks == 1 ? "" : "s") · \(events) event\(events == 1 ? "" : "s")")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            if !habits.isEmpty {
                habitChipStrip(doneToday: doneToday, dueCount: dueCount, total: habits.count)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func habitChipStrip(doneToday: Int, dueCount: Int, total: Int) -> some View {
        let allDone = doneToday == total && total > 0
        HStack(spacing: 8) {
            // Done today chip
            HStack(spacing: 4) {
                if allDone {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.doneGreen)
                }
                Text("\(doneToday)/\(total)")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(allDone ? Theme.doneGreen : Theme.textPrimary)
                Text("habits")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.surface.opacity(0.6))
            )
            // Due/overdue chip (only shown when there are pending habits)
            if dueCount > 0 && !allDone {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    Text("\(dueCount) due")
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.textPrimary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Theme.accent.opacity(0.1))
                )
            }
        }
    }

    enum ScheduleItem {
        case event(AgendaEntry)
        case task(AgendaEntry)
    }

    static func minutesOfDay(_ e: AgendaEntry) -> Int? {
        if let s = e.scheduled?.start, let h = s.hour {
            return h * 60 + (s.minute ?? 0)
        }
        if let d = e.deadline?.start, let h = d.hour {
            return h * 60 + (d.minute ?? 0)
        }
        if let t = e.timeOfDay, !t.isEmpty {
            let parts = t.split(separator: ":")
            if parts.count >= 2, let h = Int(parts[0]), let m = Int(parts[1]) {
                return h * 60 + m
            }
            if parts.count == 1, let h = Int(parts[0]) {
                return h * 60
            }
        }
        return nil
    }

    @ViewBuilder
    private func scheduleSection(_ items: [(min: Int, item: ScheduleItem)],
                                 doneStates: Set<String>,
                                 factory: RowActionFactory) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Theme.accent)
                    .frame(width: 8, height: 8)
                Text("SCHEDULE")
                    .font(.system(size: 11, weight: .heavy))
                    .tracking(0.6)
                    .foregroundStyle(Theme.textSecondary)
                Text("\(items.count)")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
            }
            .padding(.leading, 14)
            .padding(.bottom, 2)

            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, slot in
                    switch slot.item {
                    case .event(let e):
                        EventBanner(entry: e)
                    case .task(let t):
                        let rowActions = factory.make(for: t)
                        if selection.taskId == t.id {
                            TaskExpandedCard(
                                store: store,
                                task: t,
                                actions: rowActions,
                                doneStates: doneStates
                            )
                            .id(t.id)
                        } else {
                            MacTaskRow(
                                task: t,
                                isClocked: factory.isClocked(t),
                                isSelected: false,
                                doneStates: doneStates,
                                actions: rowActions,
                                progress: factory.progress(for: t),
                                keywords: store.keywords,
                                priorities: store.priorities,
                                onAppear: factory.prefetch(for: t)
                            )
                            .id(t.id)
                        }
                    }
                }
            }
        }
    }

    // MARK: - TodayMacItem: unified task+habit row type

    /// TodayItem: either a task-displayable or a due habit, for the combined list.
    private enum TodayMacItem: Identifiable {
        case task(any TaskDisplayable)
        case habit(Habit)

        var id: String {
            switch self {
            case .task(let t):  return "task-\(t.id)"
            case .habit(let h): return "habit-\(h.id)"
            }
        }

        var priority: String? {
            switch self {
            case .task(let t):  return t.priority
            case .habit(let h): return h.priority
            }
        }

        var category: String {
            switch self {
            case .task(let t):  return t.category
            case .habit(let h): return h.category ?? ""
            }
        }

        var todoState: String? {
            switch self {
            case .task(let t):  return t.todoState
            case .habit(let h): return h.state
            }
        }

        var tags: [String] {
            switch self {
            case .task(let t):  return t.tags + t.inheritedTags.filter { !t.tags.contains($0) }
            case .habit(let h): return h.tags
            }
        }

        var file: String {
            switch self {
            case .task(let t): return t.file
            case .habit:       return ""
            }
        }
    }

    // MARK: - Mixed grouping

    private struct MixedGroup: Identifiable {
        let id: String
        let label: String
        let items: [TodayMacItem]
    }

    /// Group a mixed task+habit list by the given GroupKey, returning labelled
    /// buckets in the same sort order that `groupTasks` produces.
    private func groupMixedItems(
        _ items: [TodayMacItem],
        by key: GroupKey,
        eisenhower: EisenhowerGroupContext
    ) -> [MixedGroup] {
        guard key != .none else {
            return [MixedGroup(id: "_all", label: "", items: items)]
        }
        var buckets: [String: [TodayMacItem]] = [:]
        var order: [String] = []

        func push(_ groupLabel: String, _ item: TodayMacItem) {
            if buckets[groupLabel] == nil { buckets[groupLabel] = []; order.append(groupLabel) }
            buckets[groupLabel]?.append(item)
        }

        for item in items {
            switch key {
            case .priority:
                let label = item.priority.map { "Priority \($0.uppercased())" } ?? "No Priority"
                push(label, item)
            case .category:
                push(item.category.isEmpty ? "Uncategorized" : item.category, item)
            case .state:
                push((item.todoState?.isEmpty == false ? item.todoState! : "—").uppercased(), item)
            case .tag:
                let combined = item.tags
                if combined.isEmpty {
                    push("Untagged", item)
                } else {
                    for tag in combined { push(tag, item) }
                }
            case .file:
                let name = (item.file as NSString).lastPathComponent
                push(name.isEmpty ? "Uncategorized" : name, item)
            case .eisenhower:
                // Habits have no deadline, so they land in Schedule or Eliminate
                // depending on their priority. We approximate by building a
                // minimal TaskDisplayable-like context using only priority.
                if case .task(let t) = item {
                    push(eisenhowerQuadrant(for: t, context: eisenhower), item)
                } else {
                    // Habits: important (A/B priority) → Schedule, else Eliminate
                    let isImportant = eisenhower.importantPriorities.contains(item.priority?.uppercased() ?? "")
                    push(isImportant ? "Schedule" : "Eliminate", item)
                }
            case .none:
                break
            }
        }

        let sortedKeys: [String]
        switch key {
        case .priority:
            sortedKeys = order.sorted { lhs, rhs in
                if lhs == "No Priority" { return false }
                if rhs == "No Priority" { return true }
                return lhs < rhs
            }
        case .eisenhower:
            let quadrantOrder = ["Do First", "Schedule", "Delegate", "Eliminate"]
            sortedKeys = order.sorted { lhs, rhs in
                (quadrantOrder.firstIndex(of: lhs) ?? 99) < (quadrantOrder.firstIndex(of: rhs) ?? 99)
            }
        default:
            sortedKeys = order.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        }
        return sortedKeys.map { MixedGroup(id: $0, label: $0, items: buckets[$0] ?? []) }
    }

    // MARK: - Mixed grouped section renderer

    /// Renders all mixed groups (tasks + habits merged). When groupKey is .none
    /// there is one unlabelled group showing a flat "SCHEDULED" header.
    @ViewBuilder
    private func mixedGroupedSection(
        _ groups: [MixedGroup],
        doneStates: Set<String>,
        factory: RowActionFactory,
        groupKey: GroupKey
    ) -> some View {
        if groupKey == .none, let single = groups.first {
            // Flat mode: show a single SCHEDULED section header.
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Theme.accent)
                        .frame(width: 8, height: 8)
                    Text("SCHEDULED")
                        .font(.system(size: 11, weight: .heavy))
                        .tracking(0.6)
                        .foregroundStyle(Theme.textSecondary)
                    Text("\(single.items.count)")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(Theme.textTertiary)
                    Spacer()
                }
                .padding(.leading, 14)
                .padding(.bottom, 2)

                mixedItemRows(single.items, doneStates: doneStates, factory: factory)
            }
        } else {
            // Grouped mode: one collapsible section per group label.
            ForEach(groups) { group in
                mixedGroupSection(group, doneStates: doneStates, factory: factory)
            }
        }
    }

    @ViewBuilder
    private func mixedGroupSection(
        _ group: MixedGroup,
        doneStates: Set<String>,
        factory: RowActionFactory
    ) -> some View {
        let isCollapsed = group.label.isEmpty ? false : collapsedGroups.contains(group.label)
        VStack(alignment: .leading, spacing: 6) {
            if !group.label.isEmpty {
                Button {
                    if collapsedGroups.contains(group.label) {
                        collapsedGroups.remove(group.label)
                    } else {
                        collapsedGroups.insert(group.label)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                        Text(group.label)
                            .font(.system(size: 11, weight: .semibold))
                            .tracking(0.6)
                            .textCase(.uppercase)
                            .foregroundStyle(Theme.textSecondary)
                        Text("\(group.items.count)")
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(Theme.textTertiary)
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
                .padding(.leading, 14)
                .padding(.bottom, 2)
            }
            if !isCollapsed {
                mixedItemRows(group.items, doneStates: doneStates, factory: factory)
            }
        }
    }

    @ViewBuilder
    private func mixedItemRows(
        _ items: [TodayMacItem],
        doneStates: Set<String>,
        factory: RowActionFactory
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(items) { item in
                switch item {
                case .task(let t):
                    let rowActions = factory.make(for: t)
                    if selection.taskId == t.id {
                        TaskExpandedCard(
                            store: store,
                            task: t,
                            actions: rowActions,
                            doneStates: doneStates
                        )
                        .id(t.id)
                    } else {
                        MacTaskRow(
                            task: t,
                            isClocked: factory.isClocked(t),
                            isSelected: false,
                            doneStates: doneStates,
                            actions: rowActions,
                            progress: factory.progress(for: t),
                            keywords: store.keywords,
                            priorities: store.priorities,
                            onAppear: factory.prefetch(for: t)
                        )
                        .id(t.id)
                    }
                case .habit(let h):
                    TodayHabitRow(habit: h, store: store, clocks: clocks)
                        .environment(settings)
                        .id("habit-\(h.id)")
                }
            }
        }
    }

    // MARK: - Combined task+habit list builder

    /// Merge untimed tasks and due habits into one sorted list (mirrors iOS buildCombinedItems).
    private func buildMacCombinedItems(
        tasks: [any TaskDisplayable],
        habits: [Habit],
        by key: SortKey
    ) -> [TodayMacItem] {
        let taskItems = tasks.map { TodayMacItem.task($0) }
        let habitItems = habits.map { TodayMacItem.habit($0) }
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
            return overdue.sorted(by: macItemTimeOrder) + rest.sorted(by: macItemTimeOrder)
        }

        return all.sorted { a, b in
            switch key {
            case .priority:
                let rA = macItemPriorityRank(a)
                let rB = macItemPriorityRank(b)
                if rA != rB { return rA < rB }
                let tA = macItemMs(a)
                let tB = macItemMs(b)
                if tA != tB { return tA < tB }
                return macItemTitle(a) < macItemTitle(b)
            case .scheduled:
                let tA = macItemMs(a)
                let tB = macItemMs(b)
                if tA != tB { return tA < tB }
                return macItemTitle(a) < macItemTitle(b)
            case .category:
                let cA = a.category
                let cB = b.category
                if cA != cB { return cA.localizedCompare(cB) == .orderedAscending }
                return macItemTitle(a) < macItemTitle(b)
            default:
                return macItemTitle(a) < macItemTitle(b)
            }
        }
    }

    private func macItemTimeOrder(_ a: TodayMacItem, _ b: TodayMacItem) -> Bool {
        let at = macItemMs(a)
        let bt = macItemMs(b)
        if at != bt { return at < bt }
        return macItemTitle(a) < macItemTitle(b)
    }

    private func macItemPriorityRank(_ item: TodayMacItem) -> Int {
        habitPriorityRank(item.priority)
    }

    private func macItemMs(_ item: TodayMacItem) -> Double {
        switch item {
        case .task(let t):
            if let raw = t.scheduled?.raw, !raw.isEmpty,
               let d = OrgTimestamp.parseDateString(raw) {
                return d.timeIntervalSince1970 * 1000
            }
            if let raw = t.deadline?.raw, !raw.isEmpty,
               let d = OrgTimestamp.parseDateString(raw) {
                return d.timeIntervalSince1970 * 1000
            }
            return Double.infinity
        case .habit(let h):
            guard let nd = h.nextDue, !nd.isEmpty,
                  let d = OrgTimestamp.parseDateString(nd)
            else { return Double.infinity }
            return d.timeIntervalSince1970 * 1000
        }
    }

    private func macItemTitle(_ item: TodayMacItem) -> String {
        switch item {
        case .task(let t): return t.title
        case .habit(let h): return h.title
        }
    }

    /// Overdue OrgTasks pulled from `/api/tasks` — tasks whose scheduled
    /// date is in the past and are still open. iOS displays them inline at
    /// the top of the unified list; Mac gives them a dedicated section
    /// above the schedule because the daily layout is denser.
    @ViewBuilder
    private func overdueSection(_ items: [OrgTask],
                                doneStates: Set<String>,
                                factory: RowActionFactory) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.priorityA)
                Text("OVERDUE")
                    .font(.system(size: 11, weight: .heavy))
                    .tracking(0.6)
                    .foregroundStyle(Theme.textSecondary)
                Text("\(items.count)")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
            }
            .padding(.leading, 14)
            .padding(.bottom, 2)

            VStack(alignment: .leading, spacing: 2) {
                ForEach(items, id: \.id) { t in
                    let rowActions = factory.make(for: t)
                    if selection.taskId == t.id {
                        TaskExpandedCard(
                            store: store,
                            task: t,
                            actions: rowActions,
                            doneStates: doneStates
                        )
                        .id(t.id)
                    } else {
                        MacTaskRow(
                            task: t,
                            isClocked: factory.isClocked(t),
                            isSelected: false,
                            doneStates: doneStates,
                            actions: rowActions,
                            progress: factory.progress(for: t),
                            keywords: store.keywords,
                            priorities: store.priorities,
                            onAppear: factory.prefetch(for: t)
                        )
                        .id(t.id)
                    }
                }
            }
        }
    }

    private func load() async {
        guard let client = settings.apiClient else { return }
        await store.ensureInitialized(using: client, settings: settings)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await store.loadToday(using: client) }
            // Overdue scheduled tasks come from /api/tasks; load alongside Today
            // so TodayClassifier can pull them in when the user lands here first.
            group.addTask { await store.loadAllTasks(using: client, includeDone: false) }
            // Habits slice for the due-habits section and the header chip.
            group.addTask { await store.loadHabits(using: client) }
        }
    }

    private func loadIfNeeded() async {
        if store.today.value == nil || store.allTasks.value == nil { await load() }
    }
}

// MARK: - TodayHabitRow

/// Habit row for Today / All Tasks views. Renders through `MacTaskRow` so it
/// is visually identical to a regular task row — same completion ring, state
/// pill, priority box, scheduled/repeater pills, tags, category, and the
/// user's row-highlight / progress styling. The habit's `nextDue` + cadence
/// are mapped onto a synthetic `scheduled` timestamp (a habit is, in org
/// terms, a SCHEDULED heading with a `.+` repeater). Habit-specific actions
/// (Done/Skip/Clock/Reset/Edit/Delete) ride on a context-menu override and the
/// row's `TaskRowActions`; tap toggles the inline notes/checklist body.
struct TodayHabitRow: View {
    @Environment(AppSettings.self) private var settings
    let habit: Habit
    let store: TasksStore
    let clocks: ClockManager

    @State private var isExpanded = false
    @State private var showEdit = false
    @State private var showSchedulePopover = false
    @State private var showDeleteConfirmation = false

    private var isDoneThisPeriod: Bool { HabitsGroupingNew.isDoneThisPeriod(habit) }
    private var checklistItems: [ChecklistItem] { OrgChecklist.parse(habit.notes ?? "") }
    private var hasNotes: Bool { !(habit.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var doneStates: Set<String> {
        Set((store.keywords?.allDone ?? ["DONE"]).map { $0.uppercased() })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MacTaskRow(
                task: HabitTaskAdapter(
                    habit: habit,
                    isDoneThisPeriod: isDoneThisPeriod,
                    activeKeyword: store.keywords?.allActive.first ?? "TODO",
                    doneKeyword: store.keywords?.allDone.first ?? "DONE"
                ),
                isClocked: clocks.isClocked(taskId: habit.id),
                isSelected: false,
                doneStates: doneStates,
                actions: habitRowActions,
                progress: ChecklistProgress.compute(from: habit.notes ?? ""),
                keywords: store.keywords,
                priorities: store.priorities,
                contextMenuOverride: { AnyView(todayContextMenuItems) }
            )

            if isExpanded, hasNotes {
                HabitNotesBody(
                    habit: habit,
                    store: store,
                    settings: settings,
                    checklistItems: checklistItems
                )
                .padding(.top, 4)
                .padding(.bottom, 10)
                .padding(.horizontal, 44)
            }
        }
        .popover(isPresented: $showSchedulePopover, arrowEdge: .bottom) {
            todayScheduleDatePicker
        }
        .sheet(isPresented: $showEdit) {
            HabitFormSheet(store: store, existingHabit: habit)
                .environment(settings)
        }
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

    /// Bridges habit operations onto the task row's action surface. State
    /// changes map to complete/uncomplete; priority maps to the habit
    /// endpoint; schedule reschedules `nextDue`; tap toggles the notes body.
    /// Task-only actions (deadline, refile, pin, archive) stay no-ops.
    private var habitRowActions: TaskRowActions {
        var actions = TaskRowActions()
        actions.toggleDone = { toggleDone() }
        actions.setPriority = { p in setPriority(p.isEmpty ? nil : p) }
        actions.setState = { s in
            let isDone = doneStates.contains(s.uppercased())
            if isDone != isDoneThisPeriod { toggleDone() }
        }
        actions.schedule = { date in
            if let date { rescheduleHabit(to: date) }
        }
        actions.scheduleAt = { date, _ in
            if let date { rescheduleHabit(to: date) }
        }
        actions.clockIn = { clockIn() }
        actions.clockOut = { clockOut() }
        actions.openInspector = {
            withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
        }
        actions.editInspector = { showEdit = true }
        return actions
    }

    @ViewBuilder
    private var todayContextMenuItems: some View {
        if isDoneThisPeriod {
            Button("Undo Done") { toggleDone() }
        } else {
            Button("Done") { toggleDone() }
        }
        Button("Skip") { skipHabit() }
        Button("Schedule…") { showSchedulePopover = true }
        Divider()
        if clocks.isClocked(taskId: habit.id) {
            Button("Clock Out") { clockOut() }
        } else {
            Button("Clock In") { clockIn() }
        }
        Divider()
        if !checklistItems.isEmpty {
            Button("Reset Checklist") { resetChecklist() }
        }
        Button("Edit Habit") { showEdit = true }
        Divider()
        Button("Delete", role: .destructive) { showDeleteConfirmation = true }
    }

    @ViewBuilder
    private var todayScheduleDatePicker: some View {
        let initial = habit.nextDue.flatMap { OrgTimestamp.parseDateString($0) } ?? Date()
        DatePickerPopover(
            initialDate: initial,
            initialHasTime: false,
            tint: Theme.accent,
            onSet: { date, _, _ in
                showSchedulePopover = false
                rescheduleHabit(to: date)
            },
            onClear: { showSchedulePopover = false }
        )
    }

    private func setPriority(_ priority: String?) {
        Task { @MainActor in
            guard let client = settings.apiClient else { return }
            _ = await store.setHabitPriority(habit, priority: priority, using: client)
        }
    }

    private func toggleDone() {
        Task { @MainActor in
            guard let client = settings.apiClient else { return }
            if isDoneThisPeriod {
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

    private func rescheduleHabit(to date: Date) {
        let dateStr = DateQuery.string(from: date)
        Task { @MainActor in
            guard let client = settings.apiClient else { return }
            _ = await store.rescheduleHabit(habit, to: dateStr, using: client)
        }
    }

    private func resetChecklist() {
        guard let notes = habit.notes else { return }
        let reset = OrgChecklist.resetAll(notes)
        guard reset != notes else { return }
        Task { @MainActor in
            guard let client = settings.apiClient else { return }
            _ = await store.setHabitNotes(habit, notes: reset, using: client)
        }
    }

    private func deleteHabit() {
        Task { @MainActor in
            guard let client = settings.apiClient else { return }
            _ = await store.deleteHabit(habit, using: client)
        }
    }

    private func clockIn() {
        Task { @MainActor in
            guard let client = settings.apiClient else { return }
            await clocks.clockInHabit(id: habit.id, title: habit.title, using: client)
        }
    }

    private func clockOut() {
        Task { @MainActor in
            guard let client = settings.apiClient else { return }
            guard let clock = clocks.clockFor(taskId: habit.id) else { return }
            await clocks.clockOut(clockId: clock.id, using: client)
        }
    }
}

// MARK: - HabitTaskAdapter

/// Presents a `Habit` through the `TaskDisplayable` surface so it can render in
/// `MacTaskRow` exactly like a regular task. The habit's done-this-period state
/// becomes a synthesized TODO/DONE keyword (so the row's strikethrough, state
/// pill, and highlight modes all work), and `nextDue` + cadence become a
/// synthetic SCHEDULED timestamp carrying a `.+` repeater — which is precisely
/// how org models a habit. `file`/`pos` are empty: every habit action is keyed
/// by `id`, never by file location.
struct HabitTaskAdapter: TaskDisplayable {
    let habit: Habit
    let isDoneThisPeriod: Bool
    let activeKeyword: String
    let doneKeyword: String

    var id: String { habit.id }
    var title: String { habit.title }
    var todoState: String? { isDoneThisPeriod ? doneKeyword : activeKeyword }
    var priority: String? { habit.priority }
    var tags: [String] { habit.tags }
    var inheritedTags: [String] { [] }
    var deadline: OrgTimestamp? { nil }
    var category: String { habit.category ?? "" }
    var file: String { "" }
    var pos: Int { 0 }

    /// `nextDue` rendered as a scheduled date + cadence repeater. `parsedDate`
    /// falls back to the `date` string when `start` is nil, so the calendar
    /// pill resolves without hand-building a `Component`. The repeater shows
    /// only the min interval (e.g. "1w") — matching how task rows render a
    /// repeater and dropping the relaxed-range upper bound.
    var scheduled: OrgTimestamp? {
        guard let nd = habit.nextDue, !nd.isEmpty else { return nil }
        let repeater = OrgTimestamp.Repeater(
            type: habit.cadence.kind,
            value: Int(habit.cadence.value),
            unit: habit.cadence.unit
        )
        return OrgTimestamp(
            raw: nd, date: nd, start: nil, end: nil,
            type: nil, repeater: repeater, warning: nil
        )
    }
}

// Duplicate the minimal cadence label helper here (MacHabitsView keeps its own copy).
private func cadenceLabel(_ spec: HabitCadenceSpec) -> String {
    let kindLabel: String
    switch spec.kind {
    case "+":  kindLabel = "every"
    case "++": kindLabel = "strict every"
    case ".+": kindLabel = "at least every"
    default:   kindLabel = "every"
    }
    let unitName: String
    switch spec.unit.lowercased() {
    case "d": unitName = spec.value == 1 ? "day" : "days"
    case "w": unitName = spec.value == 1 ? "week" : "weeks"
    case "m": unitName = spec.value == 1 ? "month" : "months"
    case "y": unitName = spec.value == 1 ? "year" : "years"
    default:  unitName = spec.unit
    }
    return "\(kindLabel) \(spec.value) \(unitName)"
}
