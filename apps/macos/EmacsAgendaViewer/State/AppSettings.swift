import Foundation
import SwiftUI
import Observation

enum AppearancePreference: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

@Observable
final class AppSettings {
    private static let serverURLKey = "serverURL"
    private static let appearanceKey = "appearance"
    private static let sortAgendaKey = "sortAgenda"
    private static let sortListKey = "sortList"
    private static let groupAgendaKey = "groupAgenda"
    private static let groupListKey = "groupList"
    private static let calendarIdKey = "eventKitCalendarId"
    private static let hideUpcomingDeadlinesKey = "hideUpcomingDeadlines"

    var serverURLString: String {
        didSet { UserDefaults.standard.set(serverURLString, forKey: Self.serverURLKey) }
    }

    var appearance: AppearancePreference {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: Self.appearanceKey) }
    }

    /// Sort key used by Today/Upcoming agenda views.
    var agendaSort: SortKey {
        didSet { UserDefaults.standard.set(agendaSort.rawValue, forKey: Self.sortAgendaKey) }
    }

    /// Sort key used by All Tasks list view.
    var listSort: SortKey {
        didSet { UserDefaults.standard.set(listSort.rawValue, forKey: Self.sortListKey) }
    }

    var agendaGroup: GroupKey {
        didSet { UserDefaults.standard.set(agendaGroup.rawValue, forKey: Self.groupAgendaKey) }
    }

    var listGroup: GroupKey {
        didSet { UserDefaults.standard.set(listGroup.rawValue, forKey: Self.groupListKey) }
    }

    /// EKCalendar.calendarIdentifier of the calendar to push events into.
    var eventKitCalendarIdentifier: String? {
        didSet { UserDefaults.standard.set(eventKitCalendarIdentifier, forKey: Self.calendarIdKey) }
    }

    /// When true, Today/Upcoming hide entries that org-agenda surfaces purely
    /// because of an upcoming deadline (deadline within warning period but not
    /// actually due that day).
    var hideUpcomingDeadlines: Bool {
        didSet { UserDefaults.standard.set(hideUpcomingDeadlines, forKey: Self.hideUpcomingDeadlinesKey) }
    }

    /// Per-server category color overrides. Map of category name → hex string
    /// (e.g. "#FF0000"). Stored separately per server URL so different setups
    /// can keep their own palettes.
    func categoryColorHex(for category: String) -> String? {
        currentCategoryMap[category]
    }

    func setCategoryColorHex(_ hex: String?, for category: String) {
        var map = currentCategoryMap
        if let hex, !hex.isEmpty {
            map[category] = hex
        } else {
            map.removeValue(forKey: category)
        }
        UserDefaults.standard.set(map, forKey: categoryColorsKey)
        // Bump observable touch so views re-render.
        categoryColorsRevision &+= 1
    }

    func clearCategoryColors() {
        UserDefaults.standard.removeObject(forKey: categoryColorsKey)
        categoryColorsRevision &+= 1
    }

    /// Bumped whenever per-category colors change so observing views re-render.
    private(set) var categoryColorsRevision: Int = 0

    private var currentCategoryMap: [String: String] {
        (UserDefaults.standard.dictionary(forKey: categoryColorsKey) as? [String: String]) ?? [:]
    }

    private var categoryColorsKey: String {
        // Namespaced by server URL so per-server palettes don't collide.
        "categoryColors_" + (serverURLString.isEmpty ? "default" : serverURLString)
    }

    init() {
        let d = UserDefaults.standard
        self.serverURLString = d.string(forKey: Self.serverURLKey) ?? ""
        self.appearance = AppearancePreference(rawValue: d.string(forKey: Self.appearanceKey) ?? "")
            ?? .system
        self.agendaSort = SortKey(rawValue: d.string(forKey: Self.sortAgendaKey) ?? "")
            ?? .default
        self.listSort = SortKey(rawValue: d.string(forKey: Self.sortListKey) ?? "")
            ?? .priority
        self.agendaGroup = GroupKey(rawValue: d.string(forKey: Self.groupAgendaKey) ?? "") ?? .none
        self.listGroup = GroupKey(rawValue: d.string(forKey: Self.groupListKey) ?? "") ?? .none
        self.eventKitCalendarIdentifier = d.string(forKey: Self.calendarIdKey)
        self.hideUpcomingDeadlines = d.bool(forKey: Self.hideUpcomingDeadlinesKey)
    }

    var apiClient: APIClient? {
        APIClient(baseURLString: serverURLString)
    }

    var isConfigured: Bool { apiClient != nil }
}
