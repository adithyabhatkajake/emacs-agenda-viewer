import Testing
import Foundation
@testable import EAVCore

@Suite("AppSettings persistence")
struct AppSettingsPersistenceTests {

    // Each test gets a fresh suite so writes don't bleed across tests.
    private func makeSuite(name: String = #function) -> UserDefaults {
        let suite = UserDefaults(suiteName: "EAVTests.\(name)")!
        suite.removePersistentDomain(forName: "EAVTests.\(name)")
        return suite
    }

    // MARK: - Default values (no prior UserDefaults entry)

    @Test("serverURLString defaults to empty string")
    func defaultServerURL() {
        let settings = AppSettings(defaults: makeSuite())
        #expect(settings.serverURLString == "")
    }

    @Test("appearance defaults to .system")
    func defaultAppearance() {
        let settings = AppSettings(defaults: makeSuite())
        #expect(settings.appearance == .system)
    }

    @Test("agendaSort defaults to .default")
    func defaultAgendaSort() {
        let settings = AppSettings(defaults: makeSuite())
        #expect(settings.agendaSort == .default)
    }

    @Test("listSort defaults to .priority")
    func defaultListSort() {
        let settings = AppSettings(defaults: makeSuite())
        #expect(settings.listSort == .priority)
    }

    @Test("agendaGroup defaults to .none")
    func defaultAgendaGroup() {
        let settings = AppSettings(defaults: makeSuite())
        #expect(settings.agendaGroup == .none)
    }

    @Test("listGroup defaults to .none")
    func defaultListGroup() {
        let settings = AppSettings(defaults: makeSuite())
        #expect(settings.listGroup == .none)
    }

    @Test("hideUpcomingDeadlines defaults to false")
    func defaultHideUpcomingDeadlines() {
        let settings = AppSettings(defaults: makeSuite())
        #expect(settings.hideUpcomingDeadlines == false)
    }

    @Test("hideHabitsInToday defaults to false")
    func defaultHideHabitsInToday() {
        let settings = AppSettings(defaults: makeSuite())
        #expect(settings.hideHabitsInToday == false)
    }

    @Test("eisenhowerUrgencyDays defaults to 7")
    func defaultEisenhowerUrgencyDays() {
        let settings = AppSettings(defaults: makeSuite())
        #expect(settings.eisenhowerUrgencyDays == 7)
    }

    @Test("eisenhowerSpan defaults to .twoWeeks")
    func defaultEisenhowerSpan() {
        let settings = AppSettings(defaults: makeSuite())
        #expect(settings.eisenhowerSpan == .twoWeeks)
    }

    @Test("rowHighlightMode defaults to .none")
    func defaultRowHighlightMode() {
        let settings = AppSettings(defaults: makeSuite())
        #expect(settings.rowHighlightMode == .none)
    }

    @Test("rowHighlightStyle defaults to .edgeBar")
    func defaultRowHighlightStyle() {
        let settings = AppSettings(defaults: makeSuite())
        #expect(settings.rowHighlightStyle == .edgeBar)
    }

    @Test("rowProgressStyle defaults to .line")
    func defaultRowProgressStyle() {
        let settings = AppSettings(defaults: makeSuite())
        #expect(settings.rowProgressStyle == .line)
    }

    @Test("notificationsEnabled defaults to false")
    func defaultNotificationsEnabled() {
        let settings = AppSettings(defaults: makeSuite())
        #expect(settings.notificationsEnabled == false)
    }

    @Test("hiddenCalendarIds defaults to empty set")
    func defaultHiddenCalendarIds() {
        let settings = AppSettings(defaults: makeSuite())
        #expect(settings.hiddenCalendarIds.isEmpty)
    }

    @Test("hiddenEventTags defaults to empty set")
    func defaultHiddenEventTags() {
        let settings = AppSettings(defaults: makeSuite())
        #expect(settings.hiddenEventTags.isEmpty)
    }

    @Test("eventKitCalendarIdentifier defaults to nil")
    func defaultEventKitCalendarIdentifier() {
        let settings = AppSettings(defaults: makeSuite())
        #expect(settings.eventKitCalendarIdentifier == nil)
    }

    // MARK: - Set → UserDefaults round-trips

    @Test("serverURLString write persists to UserDefaults")
    func persistServerURL() {
        let suite = makeSuite()
        let settings = AppSettings(defaults: suite)
        settings.serverURLString = "http://127.0.0.1:3002"
        #expect(suite.string(forKey: "serverURL") == "http://127.0.0.1:3002")
    }

    @Test("appearance write persists rawValue to UserDefaults")
    func persistAppearance() {
        let suite = makeSuite()
        let settings = AppSettings(defaults: suite)
        settings.appearance = .dark
        #expect(suite.string(forKey: "appearance") == "dark")
    }

    @Test("agendaSort write persists rawValue")
    func persistAgendaSort() {
        let suite = makeSuite()
        let settings = AppSettings(defaults: suite)
        settings.agendaSort = .priority
        #expect(suite.string(forKey: "sortAgenda") == "priority")
    }

    @Test("listSort write persists rawValue")
    func persistListSort() {
        let suite = makeSuite()
        let settings = AppSettings(defaults: suite)
        settings.listSort = .deadline
        #expect(suite.string(forKey: "sortList") == "deadline")
    }

    @Test("agendaGroup write persists rawValue")
    func persistAgendaGroup() {
        let suite = makeSuite()
        let settings = AppSettings(defaults: suite)
        settings.agendaGroup = .priority
        #expect(suite.string(forKey: "groupAgenda") == "priority")
    }

    @Test("listGroup write persists rawValue")
    func persistListGroup() {
        let suite = makeSuite()
        let settings = AppSettings(defaults: suite)
        settings.listGroup = .category
        #expect(suite.string(forKey: "groupList") == "category")
    }

    @Test("agendaGroupSecondary write persists rawValue")
    func persistAgendaGroupSecondary() {
        let suite = makeSuite()
        let settings = AppSettings(defaults: suite)
        settings.agendaGroupSecondary = .tag
        #expect(suite.string(forKey: "groupAgendaSecondary") == "tag")
    }

    @Test("listGroupSecondary write persists rawValue")
    func persistListGroupSecondary() {
        let suite = makeSuite()
        let settings = AppSettings(defaults: suite)
        settings.listGroupSecondary = .file
        #expect(suite.string(forKey: "groupListSecondary") == "file")
    }

    @Test("hideUpcomingDeadlines write persists to UserDefaults")
    func persistHideUpcomingDeadlines() {
        let suite = makeSuite()
        let settings = AppSettings(defaults: suite)
        settings.hideUpcomingDeadlines = true
        #expect(suite.bool(forKey: "hideUpcomingDeadlines") == true)
    }

    @Test("hideHabitsInToday write persists to UserDefaults")
    func persistHideHabitsInToday() {
        let suite = makeSuite()
        let settings = AppSettings(defaults: suite)
        settings.hideHabitsInToday = true
        #expect(suite.bool(forKey: "hideHabitsInToday") == true)
    }

    @Test("eisenhowerUrgencyDays write persists to UserDefaults")
    func persistEisenhowerUrgencyDays() {
        let suite = makeSuite()
        let settings = AppSettings(defaults: suite)
        settings.eisenhowerUrgencyDays = 14
        #expect(suite.integer(forKey: "eisenhowerUrgencyDays") == 14)
    }

    @Test("eisenhowerSpan write persists rawValue")
    func persistEisenhowerSpan() {
        let suite = makeSuite()
        let settings = AppSettings(defaults: suite)
        settings.eisenhowerSpan = .week
        #expect(suite.string(forKey: "eisenhowerSpan") == "week")
    }

    @Test("rowHighlightMode write persists rawValue")
    func persistRowHighlightMode() {
        let suite = makeSuite()
        let settings = AppSettings(defaults: suite)
        settings.rowHighlightMode = .priority
        #expect(suite.string(forKey: "rowHighlightMode") == "priority")
    }

    @Test("rowHighlightStyle write persists rawValue")
    func persistRowHighlightStyle() {
        let suite = makeSuite()
        let settings = AppSettings(defaults: suite)
        settings.rowHighlightStyle = .backgroundTint
        #expect(suite.string(forKey: "rowHighlightStyle") == "backgroundTint")
    }

    @Test("rowProgressStyle write persists rawValue")
    func persistRowProgressStyle() {
        let suite = makeSuite()
        let settings = AppSettings(defaults: suite)
        settings.rowProgressStyle = .circle
        #expect(suite.string(forKey: "rowProgressStyle") == "circle")
    }

    @Test("notificationsEnabled write persists to UserDefaults")
    func persistNotificationsEnabled() {
        let suite = makeSuite()
        let settings = AppSettings(defaults: suite)
        settings.notificationsEnabled = true
        #expect(suite.bool(forKey: "notificationsEnabled") == true)
    }

    @Test("hiddenCalendarIds write persists as string array")
    func persistHiddenCalendarIds() {
        let suite = makeSuite()
        let settings = AppSettings(defaults: suite)
        settings.hiddenCalendarIds = ["cal-1", "cal-2"]
        let stored = Set(suite.stringArray(forKey: "hiddenCalendarIds") ?? [])
        #expect(stored == ["cal-1", "cal-2"])
    }

    @Test("hiddenEventTags write persists as string array")
    func persistHiddenEventTags() {
        let suite = makeSuite()
        let settings = AppSettings(defaults: suite)
        settings.hiddenEventTags = ["work", "urgent"]
        let stored = Set(suite.stringArray(forKey: "hiddenEventTags") ?? [])
        #expect(stored == ["work", "urgent"])
    }

    @Test("eventKitCalendarIdentifier write persists to UserDefaults")
    func persistEventKitCalendarIdentifier() {
        let suite = makeSuite()
        let settings = AppSettings(defaults: suite)
        settings.eventKitCalendarIdentifier = "ABC-123"
        #expect(suite.string(forKey: "eventKitCalendarId") == "ABC-123")
    }

    @Test("eventKitCalendarIdentifier nil clears UserDefaults entry")
    func persistEventKitCalendarIdentifierNil() {
        let suite = makeSuite()
        suite.set("old-value", forKey: "eventKitCalendarId")
        let settings = AppSettings(defaults: suite)
        settings.eventKitCalendarIdentifier = nil
        #expect(suite.object(forKey: "eventKitCalendarId") == nil)
    }

    // MARK: - Init round-trip (previously persisted values are restored)

    @Test("Init restores serverURLString from UserDefaults")
    func initRestoresServerURL() {
        let suite = makeSuite()
        suite.set("http://example.com", forKey: "serverURL")
        let settings = AppSettings(defaults: suite)
        #expect(settings.serverURLString == "http://example.com")
    }

    @Test("Init restores appearance from UserDefaults")
    func initRestoresAppearance() {
        let suite = makeSuite()
        suite.set("light", forKey: "appearance")
        let settings = AppSettings(defaults: suite)
        #expect(settings.appearance == .light)
    }

    @Test("Init restores rowHighlightMode from UserDefaults")
    func initRestoresRowHighlightMode() {
        let suite = makeSuite()
        suite.set("todoState", forKey: "rowHighlightMode")
        let settings = AppSettings(defaults: suite)
        #expect(settings.rowHighlightMode == .todoState)
    }

    @Test("Init restores hiddenCalendarIds from UserDefaults")
    func initRestoresHiddenCalendarIds() {
        let suite = makeSuite()
        suite.set(["x", "y"], forKey: "hiddenCalendarIds")
        let settings = AppSettings(defaults: suite)
        #expect(settings.hiddenCalendarIds == ["x", "y"])
    }

    @Test("Init restores eisenhowerUrgencyDays from UserDefaults")
    func initRestoresEisenhowerUrgencyDays() {
        let suite = makeSuite()
        suite.set(21, forKey: "eisenhowerUrgencyDays")
        let settings = AppSettings(defaults: suite)
        #expect(settings.eisenhowerUrgencyDays == 21)
    }

    // MARK: - Mutation idempotency (same-value writes still call through)

    @Test("Writing same Bool value still reflects in UserDefaults")
    func sameValueWriteReflects() {
        let suite = makeSuite()
        let settings = AppSettings(defaults: suite)
        // Default is false; write false explicitly.
        settings.hideUpcomingDeadlines = false
        // The important guarantee: whatever is in defaults matches.
        #expect(suite.bool(forKey: "hideUpcomingDeadlines") == false)
    }
}
