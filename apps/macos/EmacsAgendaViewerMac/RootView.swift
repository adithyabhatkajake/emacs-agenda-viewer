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
        NavigationSplitView {
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
            await store.loadMetadata(using: client)
        }
    }

    @ViewBuilder
    private var detailArea: some View {
        if selection == .calendar {
            HSplitView {
                mainPane
                    .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(1)
                MacScheduleTray(store: store)
                    .frame(minWidth: 280, idealWidth: 360, maxWidth: 560)
                    .background(Theme.surface)
            }
        } else {
            mainPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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
}
