import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case today, upcoming, all, calendar

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: return "Today"
        case .upcoming: return "Upcoming"
        case .all: return "All Tasks"
        case .calendar: return "Calendar"
        }
    }

    var systemImage: String {
        switch self {
        case .today: return "star.fill"
        case .upcoming: return "list.bullet"
        case .all: return "tray.fill"
        case .calendar: return "calendar"
        }
    }
}

@MainActor
@Observable
final class Selection {
    var taskId: String?
    var inspectorVisible: Bool = true
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

    var body: some View {
        @Bindable var sel = taskSelection
        NavigationSplitView {
            sidebar
        } content: {
            VStack(spacing: 0) {
                MacClockDock(store: store)
                detailContent
            }
            .background(Theme.background)
        } detail: {
            detailColumn
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    taskSelection.inspectorVisible.toggle()
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .help("Toggle Inspector")
                .keyboardShortcut("i", modifiers: [.command, .option])
            }
        }
        .environment(taskSelection)
        .environment(clocks)
        .environment(calendarState)
        .environment(eventKit)
        .environment(calendarSync ?? makeSync())
        .task(id: settings.serverURLString) {
            guard let client = settings.apiClient else { return }
            await store.loadMetadata(using: client)
        }
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
    }

    @ViewBuilder
    private var detailColumn: some View {
        if selection == .calendar {
            MacScheduleTray(store: store)
                .background(Theme.surface)
                .frame(minWidth: 320, idealWidth: 360, maxWidth: 520)
        } else if taskSelection.inspectorVisible {
            MacInspectorView(
                store: store,
                selectedTask: currentSelectedTask,
                onClose: { taskSelection.taskId = nil }
            )
            .background(Theme.surface)
            .frame(minWidth: 320, idealWidth: 360)
        } else {
            Color.clear.frame(width: 0)
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selection {
        case .today: MacTodayView(store: store)
        case .upcoming: MacUpcomingView(store: store)
        case .all: MacAllTasksView(store: store)
        case .calendar: MacCalendarView(store: store)
        }
    }

    private func makeSync() -> CalendarSync {
        let s = CalendarSync(store: store, settings: settings, ek: eventKit)
        calendarSync = s
        return s
    }

    private var currentSelectedTask: (any TaskDisplayable)? {
        guard let id = taskSelection.taskId else { return nil }
        // Try OrgTask first
        if let tasks = store.allTasks.value, let t = tasks.first(where: { $0.id == id }) {
            return t
        }
        if let entries = store.today.value, let e = entries.first(where: { $0.id == id }) {
            return e
        }
        if let entries = store.upcoming.value, let e = entries.first(where: { $0.id == id }) {
            return e
        }
        return nil
    }
}
