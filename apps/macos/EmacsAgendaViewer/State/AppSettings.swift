import Foundation
import SwiftUI
import Observation

enum RowHighlightMode: String, CaseIterable, Identifiable {
    case none, priority, todoState

    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: return "Off"
        case .priority: return "By Priority"
        case .todoState: return "By TODO State"
        }
    }
}

enum RowHighlightStyle: String, CaseIterable, Identifiable {
    case edgeBar, backgroundTint

    var id: String { rawValue }
    var label: String {
        switch self {
        case .edgeBar: return "Edge bar"
        case .backgroundTint: return "Background tint"
        }
    }
}

enum RowProgressStyle: String, CaseIterable, Identifiable {
    case line, circle, background

    var id: String { rawValue }
    var label: String {
        switch self {
        case .line: return "Top line"
        case .circle: return "Circle"
        case .background: return "Background fill"
        }
    }
}

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
    private static let hiddenCalendarsKey = "hiddenCalendarIds"
    private static let groupAgendaSecondaryKey = "groupAgendaSecondary"
    private static let groupListSecondaryKey = "groupListSecondary"
    private static let eisenhowerUrgencyDaysKey = "eisenhowerUrgencyDays"
    private static let eisenhowerSpanKey = "eisenhowerSpan"
    private static let rowHighlightModeKey = "rowHighlightMode"
    private static let rowHighlightStyleKey = "rowHighlightStyle"
    private static let rowProgressStyleKey = "rowProgressStyle"

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

    var agendaGroupSecondary: GroupKey {
        didSet { UserDefaults.standard.set(agendaGroupSecondary.rawValue, forKey: Self.groupAgendaSecondaryKey) }
    }

    var listGroupSecondary: GroupKey {
        didSet { UserDefaults.standard.set(listGroupSecondary.rawValue, forKey: Self.groupListSecondaryKey) }
    }

    /// EKCalendar.calendarIdentifier of the calendar to push events into.
    var eventKitCalendarIdentifier: String? {
        didSet { UserDefaults.standard.set(eventKitCalendarIdentifier, forKey: Self.calendarIdKey) }
    }

    var hiddenCalendarIds: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(hiddenCalendarIds), forKey: Self.hiddenCalendarsKey)
        }
    }

    /// When true, Today/Upcoming hide entries that org-agenda surfaces purely
    /// because of an upcoming deadline (deadline within warning period but not
    /// actually due that day).
    var hideUpcomingDeadlines: Bool {
        didSet { UserDefaults.standard.set(hideUpcomingDeadlines, forKey: Self.hideUpcomingDeadlinesKey) }
    }

    var eisenhowerUrgencyDays: Int {
        didSet { UserDefaults.standard.set(eisenhowerUrgencyDays, forKey: Self.eisenhowerUrgencyDaysKey) }
    }

    var eisenhowerSpan: EisenhowerSpan {
        didSet { UserDefaults.standard.set(eisenhowerSpan.rawValue, forKey: Self.eisenhowerSpanKey) }
    }

    /// What dimension drives the row highlight color (priority, todo state, or off).
    var rowHighlightMode: RowHighlightMode {
        didSet { UserDefaults.standard.set(rowHighlightMode.rawValue, forKey: Self.rowHighlightModeKey) }
    }

    /// How the highlight is applied (left edge bar vs subtle background tint).
    var rowHighlightStyle: RowHighlightStyle {
        didSet { UserDefaults.standard.set(rowHighlightStyle.rawValue, forKey: Self.rowHighlightStyleKey) }
    }

    /// How checklist progress is rendered on each row.
    var rowProgressStyle: RowProgressStyle {
        didSet { UserDefaults.standard.set(rowProgressStyle.rawValue, forKey: Self.rowProgressStyleKey) }
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
        colorRevision &+= 1
    }

    func clearCategoryColors() {
        UserDefaults.standard.removeObject(forKey: categoryColorsKey)
        colorRevision &+= 1
    }

    // MARK: - TODO State Colors

    func todoStateColorHex(for state: String) -> String? {
        currentTodoStateMap[state.uppercased()]
    }

    func setTodoStateColorHex(_ hex: String?, for state: String) {
        var map = currentTodoStateMap
        let key = state.uppercased()
        if let hex, !hex.isEmpty {
            map[key] = hex
        } else {
            map.removeValue(forKey: key)
        }
        UserDefaults.standard.set(map, forKey: todoStateColorsKey)
        colorRevision &+= 1
    }

    func clearTodoStateColors() {
        UserDefaults.standard.removeObject(forKey: todoStateColorsKey)
        colorRevision &+= 1
    }

    func resolvedTodoStateColor(for state: String, isDone: Bool) -> Color {
        if let hex = todoStateColorHex(for: state), let c = Color(hex: hex) { return c }
        return Self.defaultTodoStateColor(state, isDone: isDone)
    }

    static func defaultTodoStateColor(_ state: String, isDone: Bool) -> Color {
        if isDone { return Theme.doneGreen }
        switch state.uppercased() {
        case "TODO": return Theme.accent
        case "NEXT", "STARTED", "DOING", "ACTV": return Theme.accentTeal
        case "WAIT", "WAITING", "HOLD", "BLOCKED", "SMDY": return Theme.priorityB
        case "CANCELLED", "CANCELED": return Theme.textTertiary
        default: return Theme.accent
        }
    }

    // MARK: - Priority Colors

    func priorityColorHex(for priority: String) -> String? {
        currentPriorityMap[priority.uppercased()]
    }

    func setPriorityColorHex(_ hex: String?, for priority: String) {
        var map = currentPriorityMap
        let key = priority.uppercased()
        if let hex, !hex.isEmpty {
            map[key] = hex
        } else {
            map.removeValue(forKey: key)
        }
        UserDefaults.standard.set(map, forKey: priorityColorsKey)
        colorRevision &+= 1
    }

    func clearPriorityColors() {
        UserDefaults.standard.removeObject(forKey: priorityColorsKey)
        colorRevision &+= 1
    }

    func resolvedPriorityColor(for priority: String?) -> Color {
        guard let p = priority, !p.isEmpty else { return Theme.textTertiary }
        if let hex = priorityColorHex(for: p), let c = Color(hex: hex) { return c }
        return Self.defaultPriorityColor(p)
    }

    static func defaultPriorityColor(_ priority: String) -> Color {
        switch priority.uppercased() {
        case "A": return Theme.priorityA
        case "B": return Theme.priorityB
        case "C": return Theme.priorityC
        case "D": return Theme.priorityD
        default: return Theme.textTertiary
        }
    }

    // MARK: - Cached Keywords & Priorities

    var cachedTodoKeywords: TodoKeywords? {
        get {
            guard let data = UserDefaults.standard.data(forKey: cachedKeywordsKey) else { return nil }
            return try? JSONDecoder().decode(TodoKeywords.self, from: data)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: cachedKeywordsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: cachedKeywordsKey)
            }
        }
    }

    var cachedPriorities: OrgPriorities? {
        get {
            guard let data = UserDefaults.standard.data(forKey: cachedPrioritiesKey) else { return nil }
            return try? JSONDecoder().decode(OrgPriorities.self, from: data)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: cachedPrioritiesKey)
            } else {
                UserDefaults.standard.removeObject(forKey: cachedPrioritiesKey)
            }
        }
    }

    struct SyncResult {
        var keywordsChanged: Bool
        var prioritiesChanged: Bool
    }

    func syncFromServer(keywords: TodoKeywords, priorities: OrgPriorities) -> SyncResult {
        let kwChanged = cachedTodoKeywords != keywords
        let prChanged = cachedPriorities != priorities
        if kwChanged { cachedTodoKeywords = keywords }
        if prChanged { cachedPriorities = priorities }
        if kwChanged || prChanged { colorRevision &+= 1 }
        return SyncResult(keywordsChanged: kwChanged, prioritiesChanged: prChanged)
    }

    /// Bumped whenever any custom color changes so observing views re-render.
    private(set) var colorRevision: Int = 0

    private var currentCategoryMap: [String: String] {
        (UserDefaults.standard.dictionary(forKey: categoryColorsKey) as? [String: String]) ?? [:]
    }

    private var currentTodoStateMap: [String: String] {
        (UserDefaults.standard.dictionary(forKey: todoStateColorsKey) as? [String: String]) ?? [:]
    }

    private var currentPriorityMap: [String: String] {
        (UserDefaults.standard.dictionary(forKey: priorityColorsKey) as? [String: String]) ?? [:]
    }

    private var serverSuffix: String {
        serverURLString.isEmpty ? "default" : serverURLString
    }

    private var categoryColorsKey: String { "categoryColors_" + serverSuffix }
    private var todoStateColorsKey: String { "todoStateColors_" + serverSuffix }
    private var priorityColorsKey: String { "priorityColors_" + serverSuffix }
    private var cachedKeywordsKey: String { "cachedKeywords_" + serverSuffix }
    private var cachedPrioritiesKey: String { "cachedPriorities_" + serverSuffix }

    init() {
        let d = UserDefaults.standard
        // Leave the URL empty on a fresh install. AppDelegate spawns the
        // bundled eavd helper, polls `/api/debug` until the daemon is
        // listening, and *then* writes the URL — at which point
        // `RootView.task(id: serverURLString)` re-fires and the metadata
        // load runs against a ready daemon. Pre-seeding here would race
        // the helper's bridge auto-load and surface a transient
        // "Could not connect" error on first launch.
        self.serverURLString = d.string(forKey: Self.serverURLKey) ?? ""
        self.appearance = AppearancePreference(rawValue: d.string(forKey: Self.appearanceKey) ?? "")
            ?? .system
        self.agendaSort = SortKey(rawValue: d.string(forKey: Self.sortAgendaKey) ?? "")
            ?? .default
        self.listSort = SortKey(rawValue: d.string(forKey: Self.sortListKey) ?? "")
            ?? .priority
        self.agendaGroup = GroupKey(rawValue: d.string(forKey: Self.groupAgendaKey) ?? "") ?? .none
        self.listGroup = GroupKey(rawValue: d.string(forKey: Self.groupListKey) ?? "") ?? .none
        self.agendaGroupSecondary = GroupKey(rawValue: d.string(forKey: Self.groupAgendaSecondaryKey) ?? "") ?? .none
        self.listGroupSecondary = GroupKey(rawValue: d.string(forKey: Self.groupListSecondaryKey) ?? "") ?? .none
        self.eventKitCalendarIdentifier = d.string(forKey: Self.calendarIdKey)
        self.hiddenCalendarIds = Set(d.stringArray(forKey: Self.hiddenCalendarsKey) ?? [])
        self.hideUpcomingDeadlines = d.bool(forKey: Self.hideUpcomingDeadlinesKey)
        self.eisenhowerUrgencyDays = (d.object(forKey: Self.eisenhowerUrgencyDaysKey) as? Int) ?? 7
        self.eisenhowerSpan = EisenhowerSpan(rawValue: d.string(forKey: Self.eisenhowerSpanKey) ?? "") ?? .twoWeeks
        self.rowHighlightMode = RowHighlightMode(rawValue: d.string(forKey: Self.rowHighlightModeKey) ?? "") ?? .none
        self.rowHighlightStyle = RowHighlightStyle(rawValue: d.string(forKey: Self.rowHighlightStyleKey) ?? "") ?? .edgeBar
        self.rowProgressStyle = RowProgressStyle(rawValue: d.string(forKey: Self.rowProgressStyleKey) ?? "") ?? .line
    }

    var apiClient: APIClient? {
        APIClient(baseURLString: serverURLString)
    }

    var isConfigured: Bool { apiClient != nil }
}
