import Foundation
import EventKit
import Observation

@MainActor
@Observable
final class EventKitService {
    let store = EKEventStore()
    var hasAccess: Bool = false
    var calendars: [EKCalendar] = []
    var allCalendars: [EKCalendar] = []
    var lastError: String?
    /// Events for the currently visible date range. Views read this property
    /// (which SwiftUI tracks via @Observable) instead of querying EKEventStore
    /// directly. Mutations call `refetchEvents()` to update it.
    var visibleEvents: [EKEvent] = []
    var hiddenCalendarIds: Set<String> = []
    private var visibleInterval: DateInterval?

    init() {
        let status = EKEventStore.authorizationStatus(for: .event)
        if status == .fullAccess || status == .authorized {
            hasAccess = true
            reloadCalendars()
        }
    }

    /// Start listening for external calendar changes. Call from `.task {}`.
    func listenForChanges() async {
        let notifications = NotificationCenter.default.notifications(
            named: .EKEventStoreChanged, object: store
        )
        for await _ in notifications {
            reloadCalendars()
            refetchEvents()
        }
    }

    /// Query EventKit for events in the given interval and store them.
    func fetchEvents(in interval: DateInterval) {
        visibleInterval = interval
        refetchEvents()
    }

    /// Re-query EventKit using the last requested interval.
    func refetchEvents() {
        guard hasAccess, let interval = visibleInterval else { return }
        let predicate = store.predicateForEvents(
            withStart: interval.start, end: interval.end, calendars: nil
        )
        let all = store.events(matching: predicate)
        if hiddenCalendarIds.isEmpty {
            visibleEvents = all
        } else {
            visibleEvents = all.filter { !hiddenCalendarIds.contains($0.calendar.calendarIdentifier) }
        }
    }

    /// Events from `visibleEvents` that overlap a specific day.
    func events(for day: Date) -> [EKEvent] {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: day)
        let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        return visibleEvents.filter { $0.startDate < dayEnd && $0.endDate > dayStart }
    }

    func requestAccess() async {
        do {
            let granted: Bool
            if #available(macOS 14.0, *) {
                granted = try await store.requestFullAccessToEvents()
            } else {
                granted = try await store.requestAccess(to: .event)
            }
            hasAccess = granted
            if granted {
                reloadCalendars()
                refetchEvents()
            }
        } catch {
            hasAccess = false
            lastError = error.localizedDescription
        }
    }

    /// Re-check authorization and reload calendars if access was granted
    /// externally (e.g. via System Settings).
    func refreshAccessIfNeeded() {
        let status = EKEventStore.authorizationStatus(for: .event)
        let granted = status == .fullAccess || status == .authorized
        if granted && !hasAccess {
            hasAccess = true
            reloadCalendars()
            refetchEvents()
        } else if granted && calendars.isEmpty {
            reloadCalendars()
        }
    }

    func reloadCalendars() {
        allCalendars = store.calendars(for: .event)
        calendars = allCalendars.filter { $0.allowsContentModifications }
    }

    /// Create a new event. Returns the calendarItemExternalIdentifier (stable for synced calendars).
    func createEvent(title: String, start: Date, end: Date, calendarId: String?) -> String? {
        refreshAccessIfNeeded()
        guard let cal = pickCalendar(id: calendarId) else { return nil }
        let event = EKEvent(eventStore: store)
        event.calendar = cal
        event.title = title
        event.startDate = start
        event.endDate = end
        do {
            try store.save(event, span: .thisEvent, commit: true)
            refetchEvents()
            return event.calendarItemExternalIdentifier
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func updateEvent(externalId: String, title: String, start: Date, end: Date) -> Bool {
        guard let event = findEvent(externalId: externalId) else { return false }
        event.title = title
        event.startDate = start
        event.endDate = end
        do {
            try store.save(event, span: .thisEvent, commit: true)
            refetchEvents()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func deleteEvent(externalId: String) -> Bool {
        guard let event = findEvent(externalId: externalId) else { return false }
        do {
            try store.remove(event, span: .thisEvent, commit: true)
            refetchEvents()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func findEvent(externalId: String) -> EKEvent? {
        store.calendarItems(withExternalIdentifier: externalId)
            .compactMap { $0 as? EKEvent }
            .first
    }

    /// Look up an event by its external identifier, falling back to the local
    /// EKEvent.eventIdentifier for events that haven't synced an external id yet.
    func findEvent(stableId: String) -> EKEvent? {
        if let ev = findEvent(externalId: stableId) { return ev }
        return store.event(withIdentifier: stableId)
    }

    @discardableResult
    func updateEvent(stableId: String, title: String, start: Date, end: Date) -> Bool {
        guard let event = findEvent(stableId: stableId) else { return false }
        event.title = title
        event.startDate = start
        event.endDate = end
        do {
            try store.save(event, span: .thisEvent, commit: true)
            refetchEvents()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func deleteEvent(stableId: String) -> Bool {
        guard let event = findEvent(stableId: stableId) else { return false }
        do {
            try store.remove(event, span: .thisEvent, commit: true)
            refetchEvents()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    private func pickCalendar(id: String?) -> EKCalendar? {
        if let id, let match = calendars.first(where: { $0.calendarIdentifier == id }) {
            return match
        }
        return store.defaultCalendarForNewEvents ?? calendars.first
    }
}
