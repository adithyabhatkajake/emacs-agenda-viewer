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
                // Today follows the canonical iOS rule (see TodayClassifier):
                // upcoming-deadlines are ALWAYS dropped and done tasks are
                // ALWAYS hidden, so the per-view "show deadlines" and "show
                // completed" toggles are gone. The habits toggle stays
                // because both platforms expose it.
                ToolbarItem(placement: .primaryAction) {
                    Toggle(isOn: Binding(
                        get: { !settings.hideHabitsInToday },
                        set: { settings.hideHabitsInToday = !$0 }
                    )) {
                        Label("Show habits",
                              systemImage: settings.hideHabitsInToday
                                ? "arrow.triangle.2.circlepath.circle"
                                : "arrow.triangle.2.circlepath.circle.fill")
                    }
                    .toggleStyle(.button)
                    .help(settings.hideHabitsInToday
                          ? "Habits hidden in Today. Click to show. (Dedicated Habits view is unaffected.)"
                          : "Showing habits inline. Click to hide for less daily/weekly clutter.")
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
            hideHabits: settings.hideHabitsInToday
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

        let sortedUntimed = sortTasks(untimedTasks, by: settings.agendaSort)
        let sortedOverdue = sortTasks(overdueOrgTasks, by: .scheduled)
        let eisCtx = EisenhowerGroupContext(urgencyDays: settings.eisenhowerUrgencyDays, priorities: store.priorities)
        let groups = groupTasks(sortedUntimed, by: settings.agendaGroup, eisenhower: eisCtx)
        let factory = RowActionFactory(store: store, settings: settings, selection: selection, clocks: clocks, sync: sync)
        let totalTasks = scheduleItems.filter { if case .task = $0.item { return true }; return false }.count + sortedUntimed.count + sortedOverdue.count
        let totalEvents = scheduleItems.filter { if case .event = $0.item { return true }; return false }.count + allDayEvents.count
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    dayHead(tasks: totalTasks, events: totalEvents)
                    if !allDayEvents.isEmpty {
                        MacEventBanners(entries: allDayEvents, showHeader: true)
                    }
                    if !sortedOverdue.isEmpty {
                        overdueSection(sortedOverdue, doneStates: doneStates, factory: factory)
                    }
                    if !scheduleItems.isEmpty {
                        scheduleSection(scheduleItems, doneStates: doneStates, factory: factory)
                    }
                    GroupedTaskList(
                        groups: groups,
                        secondaryKey: settings.agendaGroupSecondary,
                        eisenhower: eisCtx,
                        doneStates: doneStates,
                        factory: factory,
                        selection: selection,
                        store: store,
                        collapsed: $collapsedGroups
                    )
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
    private func dayHead(tasks: Int, events: Int) -> some View {
        let dayLabel = MacTodayView.dayHeadFormatter.string(from: Date())
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
        .padding(.horizontal, 14)
        .padding(.bottom, 4)
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
                                onAppear: factory.prefetch(for: t)
                            )
                            .id(t.id)
                        }
                    }
                }
            }
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
        await store.loadToday(using: client)
        // Today now matches iOS: overdue scheduled tasks come from
        // /api/tasks. Load them so the classifier can pull them in even
        // when the user lands on Today first (other views also load
        // allTasks lazily — duplicate fetches coalesce in TasksStore).
        await store.loadAllTasks(using: client, includeDone: false)
    }

    private func loadIfNeeded() async {
        if store.today.value == nil || store.allTasks.value == nil { await load() }
    }
}
