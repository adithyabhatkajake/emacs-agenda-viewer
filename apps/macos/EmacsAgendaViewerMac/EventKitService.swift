import Foundation
import EventKit
import Observation

@MainActor
@Observable
final class EventKitService {
    let store = EKEventStore()
    var calendarAccess: CalendarAccess = .denied
    var calendars: [EKCalendar] = []
    var allCalendars: [EKCalendar] = []
    var lastError: String?
    /// Events for the currently visible date range. Views read this property
    /// (which SwiftUI tracks via @Observable) instead of querying EKEventStore
    /// directly. Mutations call `refetchEvents()` to update it.
    var visibleEvents: [EKEvent] = []
    var hiddenCalendarIds: Set<String> = []
    private var visibleInterval: DateInterval?

    var canRead: Bool { calendarAccess.canRead }
    var canWrite: Bool { calendarAccess.canWrite }

    /// Tracked so the caller can cancel before re-spawning (prevents pile-up
    /// when the view's `.task {}` re-fires on identity changes).
    private var listenTask: Task<Void, Never>?

    init() {
        let status = EKEventStore.authorizationStatus(for: .event)
        calendarAccess = CalendarAccess.access(from: status)
        if calendarAccess.canRead {
            reloadCalendars()
        }
    }

    /// Start listening for external calendar changes. Cancels any prior
    /// listener before starting so re-entries don't accumulate. Call from
    /// `.task {}` — SwiftUI cancels the task when the view disappears.
    func listenForChanges() async {
        listenTask?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            let notifications = NotificationCenter.default.notifications(
                named: .EKEventStoreChanged, object: store
            )
            for await _ in notifications {
                guard !Task.isCancelled else { break }
                await MainActor.run {
                    self.reloadCalendars()
                    self.refetchEvents()
                }
            }
        }
        listenTask = task
        await task.value
    }

    /// Query EventKit for events in the given interval and store them.
    func fetchEvents(in interval: DateInterval) {
        visibleInterval = interval
        refetchEvents()
    }

    /// Re-query EventKit using the last requested interval. The EKEventStore
    /// predicate + scan runs on a detached task to avoid blocking @MainActor;
    /// results are marshalled back before writing `visibleEvents`.
    func refetchEvents() {
        guard canRead, let interval = visibleInterval else { return }
        let ekStore = store
        let hidden = hiddenCalendarIds
        Task.detached {
            let predicate = ekStore.predicateForEvents(
                withStart: interval.start, end: interval.end, calendars: nil
            )
            let all = ekStore.events(matching: predicate)
            let filtered = hidden.isEmpty
                ? all
                : all.filter { !hidden.contains($0.calendar.calendarIdentifier) }
            await MainActor.run { [weak self] in
                self?.visibleEvents = filtered
            }
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
            // Re-read the authorization status after the prompt so we correctly
            // capture whatever the user actually chose (full, write-only, denied).
            let status = EKEventStore.authorizationStatus(for: .event)
            calendarAccess = CalendarAccess.access(from: status)
            if canRead {
                reloadCalendars()
                refetchEvents()
            } else if canWrite && !granted {
                // Write-only: no calendars to list, but writes are permitted.
            }
        } catch {
            calendarAccess = .denied
            lastError = error.localizedDescription
        }
    }

    /// Re-check authorization and reload calendars if access was granted
    /// externally (e.g. via System Settings).
    func refreshAccessIfNeeded() {
        let status = EKEventStore.authorizationStatus(for: .event)
        let current = CalendarAccess.access(from: status)
        let wasRead = canRead
        calendarAccess = current
        if canRead && (!wasRead || calendars.isEmpty) {
            reloadCalendars()
            refetchEvents()
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

    /// Look up an event by the id produced by `CalendarGridItem.stableId(of:)`.
    ///
    /// Resolution order:
    ///   1. If it is a "local:" deterministic id, scan `visibleEvents` by reconstructing
    ///      the same id for each candidate (linear, bounded by the visible date window).
    ///   2. Try `store.calendarItems(withExternalIdentifier:)` (synced events).
    ///   3. Try `store.event(withIdentifier:)` (local eventIdentifier).
    func findEvent(stableId: String) -> EKEvent? {
        if CalendarStableId.isLocalId(stableId) {
            return visibleEvents.first {
                CalendarGridItem.stableId(of: $0) == stableId
            }
        }
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
