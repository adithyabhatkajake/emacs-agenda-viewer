import SwiftUI

@main
struct EmacsAgendaViewerApp: App {
    @State private var settings = AppSettings()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(settings)
                // Honor the user's AppearancePreference: .system follows iOS
                // dark-mode setting; .light / .dark force the corresponding
                // scheme. AppearancePreference.colorScheme returns nil for
                // .system, which SwiftUI interprets as "no override".
                .preferredColorScheme(settings.appearance.colorScheme)
                .tint(Theme.accent)
        }
    }
}
