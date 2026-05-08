import SwiftUI

extension Notification.Name {
    static let eav_refreshAll = Notification.Name("eav_refreshAll")
}

enum SidebarItem: String, CaseIterable, Identifiable {
    case today, upcoming, all, eisenhower, calendar

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: return "Today"
        case .upcoming: return "Upcoming"
        case .all: return "All Tasks"
        case .eisenhower: return "Eisenhower"
        case .calendar: return "Calendar"
        }
    }

    var systemImage: String {
        switch self {
        case .today: return "star.fill"
        case .upcoming: return "list.bullet"
        case .all: return "tray.fill"
        case .eisenhower: return "square.grid.2x2.fill"
        case .calendar: return "calendar"
        }
    }
}

@MainActor
@Observable
final class Selection {
    var taskId: String?
    var refileTask: (any TaskDisplayable)?
    var editingTaskId: String?
    var editingTitle: String = ""
}

struct RootView: View {
    @Environment(AppSettings.self) private var settings
    @State private var store = TasksStore()
    @State private var selection: SidebarItem = .today
    @State private var taskSelection = Selection()
    @State private var clocks = ClockManager()
    @State private var calendarState = CalendarState()
    @State private var eventKit = EventKitService()
    @State private var calendarSync: CalendarSync?
    @State private var showCapture = false
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .automatic
    @State private var eventSubscriber: EventSubscriber?

    var body: some View {
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            sidebar
        } detail: {
            detailArea
        }
        .environment(taskSelection)
        .environment(clocks)
        .environment(calendarState)
        .environment(eventKit)
        .environment(calendarSync ?? makeSync())
        .task(id: settings.serverURLString) {
            guard let client = settings.apiClient else { return }
            store.initialized = false
            await store.loadMetadata(using: client, settings: settings)

            // Re-attach the SSE subscriber whenever the server URL changes.
            // Falls silent when the configured backend doesn't expose
            // /api/events (i.e. the legacy Express server).
            eventSubscriber?.stop()
            let sub = EventSubscriber(baseURLString: settings.serverURLString)
            sub?.start { [weak store] event in
                guard let store else { return }
                Task { @MainActor in
                    guard let client = settings.apiClient else { return }
                    switch event {
                    case .taskChanged(_, let file, let pos):
                        await store.invalidate(taskId: "\(file)::\(pos)", file: file, pos: pos, using: client)
                    case .fileChanged(let file):
                        await store.invalidate(file: file, using: client)
                    case .clockChanged:
                        await store.refreshClock(using: client)
                    case .configChanged:
                        await store.invalidateConfig(using: client, settings: settings)
                    }
                }
            }
            eventSubscriber = sub
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showCapture = true
                } label: {
                    Label("Capture", systemImage: "plus.circle")
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .help("Capture new task (⇧⌘N)")
                .disabled(!settings.isConfigured)
            }
        }
        .sheet(isPresented: $showCapture) {
            CaptureSheet(store: store) {
                Task {
                    guard let client = settings.apiClient else { return }
                    await store.refreshLoaded(using: client)
                }
            }
            .environment(settings)
        }
        .onReceive(NotificationCenter.default.publisher(for: .eav_refreshAll)) { _ in
            Task {
                guard let client = settings.apiClient else { return }
                store.notesCache.removeAll()
                store.refileTargetsLoaded = false
                store.refileTargets = []
                await store.loadMetadata(using: client, settings: settings)
                await store.refreshLoaded(using: client)
                await store.loadRefileTargets(using: client)
            }
        }
        .sheet(item: Binding(
            get: { taskSelection.refileTask.map { RefileSheetItem(task: $0) } },
            set: { if $0 == nil { taskSelection.refileTask = nil } }
        )) { item in
            RefileSheet(store: store, task: item.task)
                .environment(settings)
        }
    }

    @ViewBuilder
    private var detailArea: some View {
        mainPane
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var mainPane: some View {
        VStack(spacing: 0) {
            MacClockDock(store: store)
            detailContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.background)
    }

    private var sidebar: some View {
        List(SidebarItem.allCases, selection: $selection) { item in
            NavigationLink(value: item) {
                Label(item.title, systemImage: item.systemImage)
                    .font(.system(size: 13, weight: .medium))
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
        // simultaneousGesture fires alongside the List's row-selection
        // gesture, so clicks on empty sidebar area, on rows, or anywhere on
        // the sidebar column all dismiss the inspector. .background or
        // .onTapGesture alone don't reach NSTableView-backed sidebar items
        // on macOS.
        .simultaneousGesture(
            TapGesture().onEnded { taskSelection.taskId = nil }
        )
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selection {
        case .today: MacTodayView(store: store)
        case .upcoming: MacUpcomingView(store: store)
        case .all: MacAllTasksView(store: store)
        case .eisenhower: MacEisenhowerView(store: store)
        case .calendar: MacCalendarView(store: store)
        }
    }

    private struct RefileSheetItem: Identifiable {
        let task: any TaskDisplayable
        var id: String { task.id }
    }

    private func makeSync() -> CalendarSync {
        let s = CalendarSync(store: store, settings: settings, ek: eventKit)
        calendarSync = s
        return s
    }
}
