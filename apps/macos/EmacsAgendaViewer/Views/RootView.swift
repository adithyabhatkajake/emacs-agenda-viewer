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
    @State private var eventSubscriber: EventSubscriber?

    var body: some View {
        TabView {
            // Exactly 5 tabs — all visible on iPhone with no auto "More".
            HomeView(store: store)
                .tabItem { Label("Home", systemImage: "house.fill") }

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
        // Fire error haptic whenever the banner transitions from nil to a
        // message — one pulse per error, not per render.
        .sensoryFeedback(.error, trigger: errorBanner)
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
            // Fix #3: pass settings so syncFromServer fires and initialized
            // flips to true on normal launch, not only after Settings is opened.
            await store.loadMetadata(using: client, settings: settings)

            // Fix #2: attach the SSE subscriber so daemon-driven events
            // (task edits in Emacs, file saves, clock changes) refresh the
            // iOS UI without requiring a manual pull-to-refresh.
            // Mirror of EmacsAgendaViewerMac/RootView.swift:108-130.
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
            } else if newPhase == .background {
                // Tear down the SSE connection when backgrounded so the OS
                // doesn't terminate us for holding an open network socket.
                eventSubscriber?.stop()
                eventSubscriber = nil
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
