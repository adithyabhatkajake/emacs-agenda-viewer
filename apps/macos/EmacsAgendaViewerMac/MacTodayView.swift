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
                    GroupMenu(selection: $bindable.agendaGroup)
                }
                ToolbarItem(placement: .primaryAction) {
                    Toggle(isOn: Binding(
                        get: { !settings.hideUpcomingDeadlines },
                        set: { settings.hideUpcomingDeadlines = !$0 }
                    )) {
                        Label("Show upcoming deadlines",
                              systemImage: settings.hideUpcomingDeadlines ? "eye.slash" : "eye")
                    }
                    .toggleStyle(.button)
                    .help(settings.hideUpcomingDeadlines
                          ? "Showing only today's tasks. Click to also show upcoming deadlines within the warning period."
                          : "Showing today + upcoming deadlines. Click to hide upcoming deadlines for focus.")
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
        var visible = entries
        if settings.hideUpcomingDeadlines {
            visible = visible.filter { $0.agendaType != "upcoming-deadline" }
        }
        let deduped = Self.dedupe(visible)
        let events = deduped.filter(AgendaEntryClassification.isEvent)
        let nonEvents = deduped.filter { !AgendaEntryClassification.isEvent($0) }
        let sorted = sortTasks(nonEvents, by: settings.agendaSort)
        let groups = groupTasks(sorted, by: settings.agendaGroup)
        let factory = RowActionFactory(store: store, settings: settings, selection: selection, clocks: clocks, sync: sync)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if !events.isEmpty {
                    MacEventBanners(entries: events)
                        .padding(.bottom, 4)
                }
                ForEach(groups) { group in
                    GroupSection(
                        label: group.label,
                        items: group.items,
                        doneStates: doneStates,
                        factory: factory,
                        selection: selection,
                        store: store,
                        collapsed: $collapsedGroups
                    )
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.background)
    }

    /// org-agenda emits the same task twice when both scheduled and deadline
    /// fall on the same day (or once-each across other agenda types). Collapse
    /// by task id, preferring the entry with hour info so the row keeps its time.
    private static func dedupe(_ entries: [AgendaEntry]) -> [AgendaEntry] {
        var seen: [String: AgendaEntry] = [:]
        var order: [String] = []
        for e in entries {
            let hasTime = (e.scheduled?.hasTime ?? false) || (e.deadline?.hasTime ?? false)
            if let existing = seen[e.id] {
                let existingHasTime = (existing.scheduled?.hasTime ?? false) || (existing.deadline?.hasTime ?? false)
                if hasTime && !existingHasTime { seen[e.id] = e }
            } else {
                seen[e.id] = e
                order.append(e.id)
            }
        }
        return order.compactMap { seen[$0] }
    }

    private func load() async {
        guard let client = settings.apiClient else { return }
        await store.loadToday(using: client)
    }

    private func loadIfNeeded() async {
        if store.today.value == nil { await load() }
    }
}
