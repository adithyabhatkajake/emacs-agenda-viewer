import SwiftUI

struct TodayView: View {
    @Environment(AppSettings.self) private var settings
    let store: TasksStore

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(todayTitle)
                .navigationBarTitleDisplayMode(.large)
                .toolbarBackground(Theme.background, for: .navigationBar)
                .background(Theme.background)
                .refreshable { await load() }
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
        List(entries) { entry in
            TaskRow(task: entry, doneStates: Set((store.keywords?.allDone ?? []).map { $0.uppercased() }))
                .listRowBackground(Theme.background)
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                .listRowSeparatorTint(Theme.borderSubtle)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
    }

    private func load() async {
        guard let client = settings.apiClient else { return }
        await store.loadToday(using: client)
    }

    private func loadIfNeeded() async {
        if store.today.value == nil { await load() }
    }
}
