import Foundation
import EventKit
import Observation

@MainActor
@Observable
final class EventKitService {
    let store = EKEventStore()
    var hasAccess: Bool = false
    var calendars: [EKCalendar] = []
    var lastError: String?
    /// Bumped whenever EventKit notifies us of changes. Views observing this
    /// will re-fetch their events automatically.
    var changeToken: Int = 0
    private var observer: NSObjectProtocol?

    init() {
        let status = EKEventStore.authorizationStatus(for: .event)
        if status == .fullAccess || status == .authorized {
            hasAccess = true
            reloadCalendars()
        }
        observer = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: store,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.changeToken &+= 1 }
        }
    }

    /// Fetch events overlapping the given interval. Returns empty array if no access.
    func events(in interval: DateInterval) -> [EKEvent] {
        guard hasAccess else { return [] }
        let predicate = store.predicateForEvents(
            withStart: interval.start, end: interval.end, calendars: nil
        )
        return store.events(matching: predicate)
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
            if granted { reloadCalendars() }
        } catch {
            hasAccess = false
            lastError = error.localizedDescription
        }
    }

    func reloadCalendars() {
        calendars = store.calendars(for: .event).filter { $0.allowsContentModifications }
    }

    /// Create a new event. Returns the calendarItemExternalIdentifier (stable for synced calendars).
    func createEvent(title: String, start: Date, end: Date, calendarId: String?) -> String? {
        guard let cal = pickCalendar(id: calendarId) else { return nil }
        let event = EKEvent(eventStore: store)
        event.calendar = cal
        event.title = title
        event.startDate = start
        event.endDate = end
        do {
            try store.save(event, span: .thisEvent, commit: true)
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
