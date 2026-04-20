import Foundation
import EventKit
import Observation

/// Bridges EventKit changes back into org-mode tasks tagged with `:GCAL_EVENT_ID:`.
@MainActor
@Observable
final class CalendarSync {
    let store: TasksStore
    let settings: AppSettings
    let ek: EventKitService

    var lastReconciledAt: Date?
    private var observer: NSObjectProtocol?

    init(store: TasksStore, settings: AppSettings, ek: EventKitService) {
        self.store = store
        self.settings = settings
        self.ek = ek
        observer = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: ek.store,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.reconcileFromCalendar() }
        }
    }

    /// Push the org task's current scheduled time/title to its mirror EKEvent (if any).
    func pushIfLinked(task: any TaskDisplayable) {
        guard let extId = (task as? OrgTask)?.properties?[Self.eventIdKey], !extId.isEmpty else { return }
        guard let scheduled = task.scheduled, let start = scheduled.parsedDate else { return }
        let end = computeEnd(scheduled, default: 60)
        ek.updateEvent(externalId: extId, title: task.title, start: start, end: end)
    }

    /// Fetch tasks afresh and push to EventKit any whose org-side timestamp differs.
    func pushAllLinked() async {
        guard let client = settings.apiClient else { return }
        if store.allTasks.value == nil {
            await store.loadAllTasks(using: client)
        }
        for task in store.allTasks.value ?? [] {
            pushIfLinked(task: task)
        }
    }

    /// Walk linked tasks and update their org SCHEDULED to match EventKit if drift exists.
    func reconcileFromCalendar() async {
        guard ek.hasAccess, let client = settings.apiClient else { return }
        if store.allTasks.value == nil {
            await store.loadAllTasks(using: client)
        }
        for task in store.allTasks.value ?? [] {
            guard let extId = task.properties?[Self.eventIdKey], !extId.isEmpty,
                  let event = ek.findEvent(externalId: extId)
            else { continue }
            // Compare event start/end to org scheduled.
            let orgStart = task.scheduled?.parsedDate
            let orgDur = task.scheduled.map { duration(of: $0) } ?? 0
            let evDur = max(15, Int(event.endDate.timeIntervalSince(event.startDate) / 60))

            let drift = abs((orgStart ?? .distantPast).timeIntervalSince(event.startDate))
            if drift > 30 || orgDur != evDur {
                let ts = OrgTimestampFormat.string(date: event.startDate, includeTime: true, durationMinutes: evDur)
                try? await client.setScheduled(taskId: task.id, file: task.file, pos: task.pos, timestamp: ts)
            }
        }
        lastReconciledAt = Date()
        await store.refreshLoaded(using: client)
    }

    private func duration(of ts: OrgTimestamp) -> Int {
        guard let s = ts.start, let sh = s.hour,
              let e = ts.end, let eh = e.hour else { return 0 }
        let startMin = sh * 60 + (s.minute ?? 0)
        let endMin = eh * 60 + (e.minute ?? 0)
        return max(0, endMin - startMin)
    }

    static let eventIdKey = "GCAL_EVENT_ID"
}

/// Compute the end date for an org timestamp, defaulting to `default` minutes past start
/// if no end is recorded.
@MainActor
func computeEnd(_ ts: OrgTimestamp, default defaultMinutes: Int) -> Date {
    guard let start = ts.parsedDate else { return Date() }
    if let end = ts.end, let eh = end.hour, let s = ts.start,
       end.year == s.year, end.month == s.month, end.day == s.day {
        var dc = Calendar.current.dateComponents([.year, .month, .day], from: start)
        dc.hour = eh; dc.minute = end.minute ?? 0
        return Calendar.current.date(from: dc) ?? start.addingTimeInterval(TimeInterval(defaultMinutes * 60))
    }
    return start.addingTimeInterval(TimeInterval(defaultMinutes * 60))
}
