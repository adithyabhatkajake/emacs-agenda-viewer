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
    // MARK: - UserDefaults Keys

    private static let serverURLKey = "serverURL"
    private static let appearanceKey = "appearance"
    private static let sortAgendaKey = "sortAgenda"
    private static let sortListKey = "sortList"
    private static let groupAgendaKey = "groupAgenda"
    private static let groupListKey = "groupList"
    private static let calendarIdKey = "eventKitCalendarId"
    private static let hideUpcomingDeadlinesKey = "hideUpcomingDeadlines"
    private static let hideHabitsKey = "hideHabitsInToday"
    private static let hiddenCalendarsKey = "hiddenCalendarIds"
    private static let groupAgendaSecondaryKey = "groupAgendaSecondary"
    private static let groupListSecondaryKey = "groupListSecondary"
    private static let eisenhowerUrgencyDaysKey = "eisenhowerUrgencyDays"
    private static let eisenhowerSpanKey = "eisenhowerSpan"
    private static let rowHighlightModeKey = "rowHighlightMode"
    private static let rowHighlightStyleKey = "rowHighlightStyle"
    private static let rowProgressStyleKey = "rowProgressStyle"
    private static let notificationsEnabledKey = "notificationsEnabled"
    private static let hiddenEventTagsKey = "hiddenEventTags"
    private static let lastCaptureTemplateKey = "lastCaptureTemplate"

    // MARK: - Persistence helpers

    /// The UserDefaults suite used for all persistence. Overridable in tests.
    var defaults: UserDefaults = .standard

    private func persist(_ value: Any?, to key: String) {
        defaults.set(value, forKey: key)
    }

    private func persist<T: RawRepresentable>(_ value: T, to key: String) where T.RawValue == String {
        defaults.set(value.rawValue, forKey: key)
    }

    private func persist(_ value: Set<String>, to key: String) {
        defaults.set(Array(value), forKey: key)
    }

    // MARK: - Settings properties

    var serverURLString: String {
        didSet { persist(serverURLString, to: Self.serverURLKey) }
    }

    var appearance: AppearancePreference {
        didSet { persist(appearance, to: Self.appearanceKey) }
    }

    /// Sort key used by Today/Upcoming agenda views.
    var agendaSort: SortKey {
        didSet { persist(agendaSort, to: Self.sortAgendaKey) }
    }

    /// Sort key used by All Tasks list view.
    var listSort: SortKey {
        didSet { persist(listSort, to: Self.sortListKey) }
    }

    var agendaGroup: GroupKey {
        didSet { persist(agendaGroup, to: Self.groupAgendaKey) }
    }

    var listGroup: GroupKey {
        didSet { persist(listGroup, to: Self.groupListKey) }
    }

    var agendaGroupSecondary: GroupKey {
        didSet { persist(agendaGroupSecondary, to: Self.groupAgendaSecondaryKey) }
    }

    var listGroupSecondary: GroupKey {
        didSet { persist(listGroupSecondary, to: Self.groupListSecondaryKey) }
    }

    /// EKCalendar.calendarIdentifier of the calendar to push events into.
    var eventKitCalendarIdentifier: String? {
        didSet { persist(eventKitCalendarIdentifier, to: Self.calendarIdKey) }
    }

    var hiddenCalendarIds: Set<String> {
        didSet { persist(hiddenCalendarIds, to: Self.hiddenCalendarsKey) }
    }

    /// When true, Today/Upcoming hide entries that org-agenda surfaces purely
    /// because of an upcoming deadline (deadline within warning period but not
    /// actually due that day).
    var hideUpcomingDeadlines: Bool {
        didSet { persist(hideUpcomingDeadlines, to: Self.hideUpcomingDeadlinesKey) }
    }

    /// When true, Today and Upcoming drop `:STYLE: habit` headings.
    /// Helpful for users whose habits are noisy daily/weekly chores
    /// that crowd out one-shot tasks. The dedicated Habits view still
    /// shows them.
    var hideHabitsInToday: Bool {
        didSet { persist(hideHabitsInToday, to: Self.hideHabitsKey) }
    }

    var eisenhowerUrgencyDays: Int {
        didSet { persist(eisenhowerUrgencyDays, to: Self.eisenhowerUrgencyDaysKey) }
    }

    var eisenhowerSpan: EisenhowerSpan {
        didSet { persist(eisenhowerSpan, to: Self.eisenhowerSpanKey) }
    }

    /// What dimension drives the row highlight color (priority, todo state, or off).
    var rowHighlightMode: RowHighlightMode {
        didSet { persist(rowHighlightMode, to: Self.rowHighlightModeKey) }
    }

    /// How the highlight is applied (left edge bar vs subtle background tint).
    var rowHighlightStyle: RowHighlightStyle {
        didSet { persist(rowHighlightStyle, to: Self.rowHighlightStyleKey) }
    }

    /// How checklist progress is rendered on each row.
    var rowProgressStyle: RowProgressStyle {
        didSet { persist(rowProgressStyle, to: Self.rowProgressStyleKey) }
    }

    /// Local-notification reminders fired at each task's scheduled time
    /// (only tasks with a time component, not bare-date scheduled). Off by
    /// default — user opts in from Settings.
    var notificationsEnabled: Bool {
        didSet { persist(notificationsEnabled, to: Self.notificationsEnabledKey) }
    }

    /// Tags (typically calendar names like "HarshithaDEPTcalendar") whose
    /// events are suppressed from the Events list in Today / Upcoming.
    /// Matched against an event's direct OR inherited tags.
    var hiddenEventTags: Set<String> {
        didSet { persist(hiddenEventTags, to: Self.hiddenEventTagsKey) }
    }

    func isEventTagHidden(_ tag: String) -> Bool {
        hiddenEventTags.contains(tag)
    }

    func hideEventTag(_ tag: String) {
        guard !tag.isEmpty else { return }
        hiddenEventTags.insert(tag)
    }

    func showEventTag(_ tag: String) {
        hiddenEventTags.remove(tag)
    }

    /// Last capture template the user picked; seeds the CaptureSheet picker
    /// so repeat captures don't require re-selecting the same template.
    var lastCaptureTemplateKey: String? {
        didSet {
            if let v = lastCaptureTemplateKey, !v.isEmpty {
                defaults.set(v, forKey: Self.lastCaptureTemplateKey)
            } else {
                defaults.removeObject(forKey: Self.lastCaptureTemplateKey)
            }
        }
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
        defaults.set(map, forKey: categoryColorsKey)
        // Bump observable touch so views re-render.
        colorRevision &+= 1
    }

    func clearCategoryColors() {
        defaults.removeObject(forKey: categoryColorsKey)
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
        defaults.set(map, forKey: todoStateColorsKey)
        colorRevision &+= 1
    }

    func clearTodoStateColors() {
        defaults.removeObject(forKey: todoStateColorsKey)
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
        defaults.set(map, forKey: priorityColorsKey)
        colorRevision &+= 1
    }

    func clearPriorityColors() {
        defaults.removeObject(forKey: priorityColorsKey)
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
            guard let data = defaults.data(forKey: cachedKeywordsKey) else { return nil }
            return try? JSONDecoder().decode(TodoKeywords.self, from: data)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: cachedKeywordsKey)
            } else {
                defaults.removeObject(forKey: cachedKeywordsKey)
            }
        }
    }

    var cachedPriorities: OrgPriorities? {
        get {
            guard let data = defaults.data(forKey: cachedPrioritiesKey) else { return nil }
            return try? JSONDecoder().decode(OrgPriorities.self, from: data)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: cachedPrioritiesKey)
            } else {
                defaults.removeObject(forKey: cachedPrioritiesKey)
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
        (defaults.dictionary(forKey: categoryColorsKey) as? [String: String]) ?? [:]
    }

    private var currentTodoStateMap: [String: String] {
        (defaults.dictionary(forKey: todoStateColorsKey) as? [String: String]) ?? [:]
    }

    private var currentPriorityMap: [String: String] {
        (defaults.dictionary(forKey: priorityColorsKey) as? [String: String]) ?? [:]
    }

    private var serverSuffix: String {
        serverURLString.isEmpty ? "default" : serverURLString
    }

    private var categoryColorsKey: String { "categoryColors_" + serverSuffix }
    private var todoStateColorsKey: String { "todoStateColors_" + serverSuffix }
    private var priorityColorsKey: String { "priorityColors_" + serverSuffix }
    private var cachedKeywordsKey: String { "cachedKeywords_" + serverSuffix }
    private var cachedPrioritiesKey: String { "cachedPriorities_" + serverSuffix }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let d = defaults
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
        self.hideHabitsInToday = d.bool(forKey: Self.hideHabitsKey)
        self.eisenhowerUrgencyDays = (d.object(forKey: Self.eisenhowerUrgencyDaysKey) as? Int) ?? 7
        self.eisenhowerSpan = EisenhowerSpan(rawValue: d.string(forKey: Self.eisenhowerSpanKey) ?? "") ?? .twoWeeks
        self.rowHighlightMode = RowHighlightMode(rawValue: d.string(forKey: Self.rowHighlightModeKey) ?? "") ?? .none
        self.rowHighlightStyle = RowHighlightStyle(rawValue: d.string(forKey: Self.rowHighlightStyleKey) ?? "") ?? .edgeBar
        self.rowProgressStyle = RowProgressStyle(rawValue: d.string(forKey: Self.rowProgressStyleKey) ?? "") ?? .line
        self.notificationsEnabled = d.bool(forKey: Self.notificationsEnabledKey)
        self.hiddenEventTags = Set(d.stringArray(forKey: Self.hiddenEventTagsKey) ?? [])
        self.lastCaptureTemplateKey = d.string(forKey: Self.lastCaptureTemplateKey)
    }

    var apiClient: APIClient? {
        APIClient(baseURLString: serverURLString)
    }

    var isConfigured: Bool { apiClient != nil }

    /// True when the app should manage the bundled local `eavd` helper — i.e.
    /// spawn it on launch and gate the UI on its readiness. That's the case on
    /// a fresh install (empty URL: the AppDelegate fills it with the local
    /// endpoint once the helper is serving) or when the configured URL
    /// explicitly points at the local helper on 127.0.0.1:3002.
    ///
    /// A remote URL (e.g. a Tailscale host) means the user supplies their own
    /// server, so the bundled helper must NOT be spawned and — crucially —
    /// must not gate the UI. Otherwise a local-helper failure (no local Emacs
    /// bridge socket, a port conflict, an unsigned binary) blocks an app that
    /// is perfectly able to reach its configured remote server. Consulted only
    /// by the macOS target; the iOS app has no bundled helper.
    var usesBundledDaemon: Bool {
        let trimmed = serverURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        guard let url = APIClient(baseURLString: trimmed)?.baseURL,
              let host = url.host else { return false }
        let isLoopback = host == "127.0.0.1" || host == "localhost" || host == "::1"
        // The bundled helper always binds 3002. A loopback URL on any other
        // port is some other local server the user chose to point at, so treat
        // only :3002 (or an unspecified port) as "the bundled helper".
        return isLoopback && (url.port == nil || url.port == 3002)
    }
}
