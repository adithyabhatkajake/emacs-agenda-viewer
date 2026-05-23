import SwiftUI

struct RootView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = TasksStore()
    @State private var notifications = NotificationService()
    @State private var clocks = ClockManager()
    @State private var liveActivities = ClockLiveActivityCoordinator()
    @State private var errorBanner: String?
    @State private var errorBannerDismissTask: Task<Void, Never>?

    var body: some View {
        TabView {
            TodayView(store: store)
                .tabItem { Label("Today", systemImage: "star.fill") }

            PinnedView(store: store)
                .tabItem { Label("Pinned", systemImage: "pin.fill") }

            InboxView(store: store)
                .tabItem { Label("Inbox", systemImage: "tray.fill") }

            UpcomingView(store: store)
                .tabItem { Label("Upcoming", systemImage: "calendar") }

            // iOS auto-collapses the remaining tabs under a "More" tab
            // (TabView shows 5 visible + auto More on iPhone). Most-used
            // views go first; secondary views (All Tasks, Habits, Logbook,
            // Settings) land under More.
            AllTasksView(store: store)
                .tabItem { Label("All Tasks", systemImage: "list.bullet") }

            HabitsView(store: store)
                .tabItem { Label("Habits", systemImage: "repeat.circle") }

            LogbookView(store: store)
                .tabItem { Label("Logbook", systemImage: "checkmark.seal") }

            SettingsView(store: store, notifications: notifications)
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        .environment(notifications)
        .environment(clocks)
        .overlay(alignment: .top) {
            if let errorBanner {
                Text(errorBanner)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Theme.priorityA, in: Capsule())
                    .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
                    .padding(.top, 64)
                    .padding(.horizontal, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.18), value: errorBanner)
        .onChange(of: store.lastMutationError) { _, new in
            guard let msg = new, !msg.isEmpty else { return }
            errorBanner = msg
            errorBannerDismissTask?.cancel()
            errorBannerDismissTask = Task {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if !Task.isCancelled {
                    await MainActor.run { errorBanner = nil }
                }
            }
        }
        .task(id: settings.serverURLString) {
            guard let client = settings.apiClient else { return }
            await store.loadMetadata(using: client)
        }
        // Re-sync notifications whenever the task set changes (load completes,
        // SSE invalidation fires, user toggles a task done, etc.).
        .task(id: store.allTasksRevision) {
            await syncNotifications()
        }
        // Toggling the master switch (or first-launch enabling) triggers a
        // permission prompt + sync without waiting for the next data reload.
        .task(id: settings.notificationsEnabled) {
            if settings.notificationsEnabled,
               notifications.authStatus == .notDetermined {
                _ = await notifications.requestAuthorization()
            }
            await syncNotifications()
        }
        .onChange(of: scenePhase) { _, newPhase in
            // User might have toggled notification access in the iOS Settings
            // app while we were backgrounded — refresh + re-sync on return.
            if newPhase == .active {
                Task {
                    await notifications.refreshAuthStatus()
                    await syncNotifications()
                }
            }
        }
        // Live Activities — pair iOS-owned Activities with the local
        // ClockManager sessions. `reconcileOnLaunch` handles the
        // app-was-killed-while-clocked case (Activity survived; map didn't,
        // or vice-versa). `sync` runs on every sessions mutation thereafter.
        .task { await liveActivities.reconcileOnLaunch(sessions: clocks.sessions) }
        .onChange(of: clocks.sessions) { _, newSessions in
            Task { await liveActivities.sync(sessions: newSessions) }
        }
    }

    private func syncNotifications() async {
        let doneStates = Set((store.keywords?.allDone ?? []).map { $0.uppercased() })
        await notifications.sync(
            tasks: store.allTasks.value ?? [],
            doneStates: doneStates,
            enabled: settings.notificationsEnabled
        )
    }
}
