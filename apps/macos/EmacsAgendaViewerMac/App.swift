import SwiftUI

@main
struct EmacsAgendaViewerMacApp: App {
    @State private var settings = AppSettings()
    @State private var eventKit = EventKitService()

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
