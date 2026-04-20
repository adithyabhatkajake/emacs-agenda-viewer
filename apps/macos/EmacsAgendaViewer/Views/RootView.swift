import SwiftUI

struct RootView: View {
    @Environment(AppSettings.self) private var settings
    @State private var store = TasksStore()

    var body: some View {
        TabView {
            TodayView(store: store)
                .tabItem { Label("Today", systemImage: "star.fill") }

            UpcomingView(store: store)
                .tabItem { Label("Upcoming", systemImage: "calendar") }

            AllTasksView(store: store)
                .tabItem { Label("All Tasks", systemImage: "tray.fill") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        .task(id: settings.serverURLString) {
            guard let client = settings.apiClient else { return }
            await store.loadMetadata(using: client)
        }
    }
}
