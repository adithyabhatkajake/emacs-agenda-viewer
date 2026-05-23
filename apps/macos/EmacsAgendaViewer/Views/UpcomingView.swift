import SwiftUI

struct UpcomingView: View {
    @Environment(AppSettings.self) private var settings
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
        .task(id: settings.serverURLString) { await loadIfNeeded() }
    }

    @ViewBuilder
    private var content: some View {
        if !settings.isConfigured {
            VStack(spacing: 0) {
                LargePageHeader(pretitle: nil, title: "Upcoming")
                UnconfiguredStateView()
            }
            .background(Theme.background)
        } else if let entries = store.upcoming.value {
            if entries.isEmpty {
                VStack(spacing: 0) {
                    LargePageHeader(pretitle: nil, title: "Upcoming")
                    EmptyStateView(title: "Nothing upcoming", systemImage: "calendar")
                }
                .background(Theme.background)
            } else {
                groupedList(entries)
            }
        } else if store.upcoming.isLoading {
            VStack(spacing: 0) {
                LargePageHeader(pretitle: nil, title: "Upcoming")
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Theme.background)
        } else if let msg = store.upcoming.error {
            VStack(spacing: 0) {
                LargePageHeader(pretitle: nil, title: "Upcoming")
                ErrorStateView(message: msg) { Task { await load() } }
            }
            .background(Theme.background)
        } else {
            Color.clear
        }
    }

    private func groupedList(_ entries: [AgendaEntry]) -> some View {
        // Suppress event entries whose tags match the user's hidden set.
        // Non-event entries (TODO tasks) pass through untouched.
        let hidden = settings.hiddenEventTags
        let filtered: [AgendaEntry] = hidden.isEmpty ? entries : entries.filter { entry in
            guard AgendaEntryClassification.isEvent(entry) else { return true }
            if entry.tags.contains(where: hidden.contains) { return false }
            if entry.inheritedTags.contains(where: hidden.contains) { return false }
            return true
        }
        let groups = Self.groupByDay(filtered)
        let doneStates = Set((store.keywords?.allDone ?? []).map { $0.uppercased() })
        let openCount = entries.filter { entry in
            guard let s = entry.todoState, !s.isEmpty else { return false }
            return !doneStates.contains(s.uppercased())
        }.count
        let dayCount = groups.count
        let subtitle = "\(openCount) task\(openCount == 1 ? "" : "s") across \(dayCount) day\(dayCount == 1 ? "" : "s")"

        return VStack(spacing: 0) {
            LargePageHeader(pretitle: nil, title: "Upcoming", subtitle: subtitle)
            List {
                ForEach(groups, id: \.key) { group in
                    Section {
                        ForEach(sortTasks(group.items, by: settings.agendaSort)) { entry in
                            if AgendaEntryClassification.isEvent(entry) {
                                EventRow(entry: entry)
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
        .background(Theme.background)
    }

    struct DayGroup {
        let key: String
        let dayNumber: String?
        let label: String
        let relative: String?
        let items: [AgendaEntry]
    }

    private static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale.current
        f.dateFormat = "EEEE"
        return f
    }()

    private static let dayNumFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "d"
        return f
    }()

    private static func groupByDay(_ entries: [AgendaEntry]) -> [DayGroup] {
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

            // Relative label mirrors Things 3 / the design's "In N days"
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

    private func load() async {
        guard let client = settings.apiClient else { return }
        await store.loadUpcoming(using: client)
    }

    private func loadIfNeeded() async {
        if store.upcoming.value == nil { await load() }
    }
}

private struct DayGroupHeader: View {
    let group: UpcomingView.DayGroup

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
