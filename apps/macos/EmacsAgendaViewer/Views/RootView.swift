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
            VStack(spacing: 8) {
                if let errorBanner {
                    Text(errorBanner)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Theme.priorityA, in: Capsule())
                        .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if let notice = connectionNotice {
                    connectionBanner(notice)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(.top, 64)
            .padding(.horizontal, 16)
        }
        .animation(.easeOut(duration: 0.18), value: errorBanner)
        .animation(.easeOut(duration: 0.18), value: connectionNotice)
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
            startEventSubscriber(settings: settings)
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
            if newPhase == .active {
                // The SSE socket was torn down on background, so while asleep
                // the daemon may have changed data behind our back. Reconnect
                // and refresh before the user acts on a stale list — otherwise
                // a completion could fight a server change. connectionState
                // drives the "connecting — showing last update" banner until
                // the stream is live again.
                if eventSubscriber == nil {
                    store.connectionState = .connecting
                    startEventSubscriber(settings: settings)
                }
                Task {
                    if let client = settings.apiClient {
                        await store.refreshLoaded(using: client)
                    }
                    // User might have toggled notification access in the iOS
                    // Settings app while we were backgrounded.
                    await notifications.refreshAuthStatus()
                    await syncNotifications()
                }
            } else if newPhase == .background {
                // Tear down the SSE connection when backgrounded so the OS
                // doesn't terminate us for holding an open network socket.
                eventSubscriber?.stop()
                eventSubscriber = nil
                store.connectionState = .disconnected
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

    private struct ConnectionNotice: Equatable {
        let text: String
        let isReconnecting: Bool
    }

    /// A little kitten that bobs and wiggles while we reconnect — stands in for
    /// the usual spinner. `cat.fill` ships in SF Symbols 5 (iOS 17); the wiggle
    /// is hand-rolled so we don't need the iOS-18-only `.symbolEffect(.wiggle)`.
    private struct ConnectingKitten: View {
        @State private var hop = false
        var body: some View {
            Image(systemName: "cat.fill")
                .font(.system(size: 14, weight: .semibold))
                .rotationEffect(.degrees(hop ? 9 : -9), anchor: .bottom)
                .offset(y: hop ? -1.5 : 1.5)
                .animation(.easeInOut(duration: 0.42).repeatForever(autoreverses: true), value: hop)
                .onAppear { hop = true }
                .accessibilityLabel("Reconnecting")
        }
    }

    /// Status notice shown while the live link is down or a refresh failed,
    /// *only* when we already have content to keep showing. Tells the user the
    /// displayed data may be behind the server so they don't act on a stale
    /// list right after waking. Returns nil during normal connected operation.
    private var connectionNotice: ConnectionNotice? {
        let hasContent = store.today.value != nil
            || store.allTasks.value != nil
            || store.upcoming.value != nil
        guard hasContent else { return nil }
        // Only treat a dropped link as "reconnecting" once we've actually been
        // connected — avoids a cold-launch flash and a permanent banner on the
        // legacy Express backend (no SSE endpoint).
        if store.connectionState != .connected, store.sseEverConnected {
            return ConnectionNotice(text: "Reconnecting… showing last update", isReconnecting: true)
        }
        if store.lastRefreshError != nil {
            return ConnectionNotice(text: "Couldn’t refresh — showing last update", isReconnecting: false)
        }
        return nil
    }

    @ViewBuilder
    private func connectionBanner(_ notice: ConnectionNotice) -> some View {
        HStack(spacing: 8) {
            if notice.isReconnecting {
                ConnectingKitten()
            } else {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 12, weight: .semibold))
            }
            Text(notice.text)
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.secondary, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 5, y: 2)
    }

    /// (Re)attach the SSE subscriber for the current server URL. Falls silent
    /// when the configured backend doesn't expose `/api/events` (legacy
    /// Express). Connection-state transitions are forwarded to the store so the
    /// status banner reflects the live link.
    private func startEventSubscriber(settings: AppSettings) {
        eventSubscriber?.stop()
        let sub = EventSubscriber(baseURLString: settings.serverURLString)
        sub?.onStateChange = { [weak store] state in
            store?.connectionState = state
        }
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

    private func syncNotifications() async {
        let doneStates = Set((store.keywords?.allDone ?? []).map { $0.uppercased() })
        await notifications.sync(
            tasks: store.allTasks.value ?? [],
            doneStates: doneStates,
            enabled: settings.notificationsEnabled
        )
    }
}
