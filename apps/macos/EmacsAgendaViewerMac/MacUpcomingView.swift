import SwiftUI

struct MacUpcomingView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(Selection.self) private var selection
    @Environment(ClockManager.self) private var clocks
    @Environment(CalendarSync.self) private var sync
    let store: TasksStore

    var body: some View {
        @Bindable var bindable = settings
        content
            .navigationTitle("Upcoming")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    SortMenu(options: SortKey.agendaOptions, selection: $bindable.agendaSort)
                }
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
        } else if let entries = store.upcoming.value {
            if entries.isEmpty {
                EmptyStateView(title: "Nothing upcoming", systemImage: "calendar")
            } else {
                groupedList(entries)
            }
        } else if store.upcoming.isLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let msg = store.upcoming.error {
            ErrorStateView(message: msg) { Task { await load() } }
        } else {
            Color.clear
        }
    }

    private func groupedList(_ entries: [AgendaEntry]) -> some View {
        // Group EVERYTHING by day; within each day, events render as banners and
        // remaining tasks render as rows below. Dedupe per-day so scheduled +
        // deadline on the same day collapse to one row.
        let groups = Self.groupByDay(entries).map { g in
            DayGroup(key: g.key, label: g.label, items: dedupeAgendaEntries(g.items))
        }
        let doneStates = Set((store.keywords?.allDone ?? []).map { $0.uppercased() })
        let factory = RowActionFactory(store: store, settings: settings, selection: selection, clocks: clocks, sync: sync)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                ForEach(groups, id: \.key) { group in
                    daySection(group, doneStates: doneStates, factory: factory)
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, minHeight: 600, alignment: .leading)
            .background(
                Rectangle()
                    .fill(Theme.background)
                    .contentShape(Rectangle())
                    .onTapGesture { selection.taskId = nil }
            )
        }
        .background(Theme.background)
    }

    @ViewBuilder
    private func daySection(_ group: DayGroup, doneStates: Set<String>, factory: RowActionFactory) -> some View {
        let events = group.items.filter(AgendaEntryClassification.isEvent)
        let tasks = sortTasks(group.items.filter { !AgendaEntryClassification.isEvent($0) },
                              by: settings.agendaSort)

        VStack(alignment: .leading, spacing: 8) {
            dayHead(for: group, tasks: tasks.count, events: events.count)

            if !events.isEmpty {
                MacEventBanners(entries: events)
            }

            if !tasks.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(tasks, id: \.id) { entry in
                        let rowActions = factory.make(for: entry)
                        if selection.taskId == entry.id {
                            TaskExpandedCard(
                                store: store,
                                task: entry,
                                actions: rowActions,
                                doneStates: doneStates
                            )
                            .id(entry.id)
                        } else {
                            MacTaskRow(
                                task: entry,
                                isClocked: factory.isClocked(entry),
                                isSelected: false,
                                doneStates: doneStates,
                                actions: rowActions,
                                progress: factory.progress(for: entry),
                                keywords: store.keywords,
                                onAppear: factory.prefetch(for: entry)
                            )
                        }
                    }
                }
            }
        }
    }

    private static let isoFmt: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let dayHeadFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEEE, MMM d"; return f
    }()

    private static let weekdayFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEEE"; return f
    }()

    @ViewBuilder
    private func dayHead(for group: DayGroup, tasks: Int, events: Int) -> some View {
        let date = MacUpcomingView.isoFmt.date(from: group.key)
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        let target = date.map { cal.startOfDay(for: $0) }
        let days = target.flatMap { cal.dateComponents([.day], from: todayStart, to: $0).day } ?? 0

        let overline: String = {
            switch days {
            case 0: return "TODAY"
            case 1: return "TOMORROW"
            case 2...6: return "IN \(days) DAYS"
            case 7...13: return "NEXT WEEK"
            default:
                let weeks = days / 7
                let months = days / 30
                if weeks <= 4 { return "IN \(weeks) WEEKS" }
                return months <= 1 ? "IN A MONTH" : "IN \(months) MONTHS"
            }
        }()

        let primary = date.map { MacUpcomingView.dayHeadFmt.string(from: $0) } ?? group.label

        VStack(alignment: .leading, spacing: 4) {
            Text(overline)
                .font(.system(size: 11, weight: .heavy))
                .tracking(0.6)
                .foregroundStyle(overlineColor(for: days))
            HStack(alignment: .lastTextBaseline, spacing: 12) {
                Text(primary)
                    .font(.system(size: 22, weight: .bold))
                    .tracking(-0.4)
                    .foregroundStyle(Theme.textPrimary)
                if tasks + events > 0 {
                    Text("\(tasks) task\(tasks == 1 ? "" : "s") · \(events) event\(events == 1 ? "" : "s")")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 4)
    }

    private func overlineColor(for daysFromToday: Int) -> Color {
        switch daysFromToday {
        case 0...1: return Theme.accent
        case 2...6: return Theme.textPrimary
        default: return Theme.textSecondary
        }
    }

    private struct DayGroup {
        let key: String
        let label: String
        let items: [AgendaEntry]
    }

    private static func groupByDay(_ entries: [AgendaEntry]) -> [DayGroup] {
        var buckets: [String: [AgendaEntry]] = [:]
        var order: [String] = []
        for entry in entries {
            let dayKey = entry.displayDate
                ?? entry.scheduled?.date
                ?? entry.deadline?.date
                ?? "—"
            if buckets[dayKey] == nil {
                buckets[dayKey] = []
                order.append(dayKey)
            }
            buckets[dayKey]?.append(entry)
        }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return order.map { key in
            let date = formatter.date(from: key)
            let label = date.map { DateBadge.relativeLabel(for: $0) } ?? key
            return DayGroup(key: key, label: label, items: buckets[key] ?? [])
        }
    }

    private func load() async {
        guard let client = settings.apiClient else { return }
        await store.ensureInitialized(using: client, settings: settings)
        await store.loadUpcoming(using: client)
    }

    private func loadIfNeeded() async {
        if store.upcoming.value == nil { await load() }
    }
}
