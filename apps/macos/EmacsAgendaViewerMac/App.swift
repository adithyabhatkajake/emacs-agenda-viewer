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
        guard let host = daemonHost else { return }
        do {
            try host.start()
        } catch {
            NSLog("eavd helper failed to start: %@", String(describing: error))
            return
        }
        // Don't set the URL until the daemon is actually serving, otherwise
        // the RootView task fires and races the helper's bridge auto-load.
        // The URL change will retrigger any `.task(id: serverURLString)`.
        Task { @MainActor [weak self] in
            guard let self, let host = self.daemonHost else { return }
            let ready = await host.waitForReady()
            guard let s = self.settings else { return }
            if !ready {
                NSLog("eavd helper didn't become ready within timeout")
            }
            // Set even on `!ready`: the first ContentStates 'Couldn't load'
            // is preferable to a forever-empty UI, and the user gets a
            // working `Try again` button once the daemon comes up.
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
