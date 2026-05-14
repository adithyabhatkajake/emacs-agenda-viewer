import SwiftUI
import AppKit

@main
struct EmacsAgendaViewerMacApp: App {
    @State private var settings = AppSettings()
    @State private var eventKit = EventKitService()
    @State private var daemonHost = DaemonHost()

    /// AppDelegate just for the lifecycle hooks SwiftUI doesn't expose.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        appDelegate.daemonHost = daemonHost
        appDelegate.settings = settings
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(settings)
                .environment(eventKit)
                .environment(daemonHost)
                .preferredColorScheme(settings.appearance.colorScheme)
                .tint(Theme.accent)
                .frame(minWidth: 820, idealWidth: 1080, minHeight: 560, idealHeight: 720)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 1080, height: 720)
        .commands {
            SidebarCommands()
            CommandGroup(after: .sidebar) {
                Button("Toggle Sidebar") {
                    NSApp.keyWindow?.contentViewController?.tryToPerform(
                        #selector(NSSplitViewController.toggleSidebar(_:)), with: nil
                    )
                }
                .keyboardShortcut("/", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
                .environment(settings)
                .environment(eventKit)
                .preferredColorScheme(settings.appearance.colorScheme)
                .tint(Theme.accent)
                .frame(width: 520, height: 720)
        }
    }
}

/// Owns the bundled `eavd` helper process: spawns it on launch, cleans up
/// on quit. Without an `NSApplicationDelegate` SwiftUI doesn't give us a
/// reliable termination hook, and a stranded daemon clinging to port 3002
/// would block the next launch.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var daemonHost: DaemonHost?
    var settings: AppSettings?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard daemonHost != nil else { return }
        // `start()` is async because the version handshake probes the
        // existing daemon (if any) before deciding whether to spawn fresh.
        // Don't set the URL until the daemon is actually serving, otherwise
        // the RootView task fires and races the helper's bridge auto-load.
        Task { @MainActor [weak self] in
            guard let self, let host = self.daemonHost else { return }
            host.phase = .starting
            do {
                try await host.start()
            } catch {
                NSLog("eavd helper failed to start: %@", String(describing: error))
                // Don't clobber a `.crashed` phase that the termination
                // handler may have set in the same tick — if proc.run()
                // succeeded but the child died immediately, that's what
                // we want to show.
                if case .starting = host.phase {
                    host.phase = .failedToStart(reason: "Could not launch helper: \(error)")
                }
                return
            }
            let ready = await host.waitForReady()
            guard let s = self.settings else { return }
            if !ready {
                NSLog("eavd helper didn't become ready within timeout")
                // The termination handler wins if the child died first;
                // only mark "timed out" when the process is still alive.
                switch host.phase {
                case .starting:
                    host.phase = .failedToStart(reason:
                        "Polled /api/debug for 15 seconds with no response. "
                        + "The process is running but never bound the port — "
                        + "another service may be on 3002.")
                default: break  // crashed/failedToStart already set by handler
                }
            } else {
                host.phase = .ready
            }
            // Set even on failure: the user gets a working "Retry"
            // button in the failure view; the URL just needs to be
            // populated for when retry succeeds.
            if s.serverURLString.isEmpty {
                s.serverURLString = host.endpointURL.absoluteString
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        daemonHost?.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
