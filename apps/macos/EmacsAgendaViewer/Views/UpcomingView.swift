import SwiftUI

struct UpcomingView: View {
    @Environment(AppSettings.self) private var settings
    let store: TasksStore

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Upcoming")
                .navigationBarTitleDisplayMode(.large)
                .toolbarBackground(Theme.background, for: .navigationBar)
                .background(Theme.background)
                .refreshable { await load() }
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
        let groups = Self.groupByDay(entries)
        let doneStates = Set((store.keywords?.allDone ?? []).map { $0.uppercased() })
        return List {
            ForEach(groups, id: \.key) { group in
                Section {
                    ForEach(group.items) { entry in
                        TaskRow(task: entry, doneStates: doneStates)
                            .listRowBackground(Theme.background)
                            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                            .listRowSeparatorTint(Theme.borderSubtle)
                    }
                } header: {
                    Text(group.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .textCase(nil)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
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
        await store.loadUpcoming(using: client)
    }

    private func loadIfNeeded() async {
        if store.upcoming.value == nil { await load() }
    }
}
