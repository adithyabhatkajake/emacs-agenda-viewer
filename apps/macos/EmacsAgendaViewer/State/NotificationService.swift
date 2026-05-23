#if !os(macOS)
import Foundation
import Observation
import UserNotifications

/// Schedules local notifications for tasks with a scheduled time component.
/// Sync is idempotent: call `sync(tasks:doneStates:enabled:)` whenever the
/// task set changes; the service diffs against pending requests and adds /
/// removes as needed. Identifier is `"eav:" + task.id` so we only touch our
/// own pending requests and leave anything else alone.
@Observable
@MainActor
final class NotificationService {
    /// iOS caps pending local notifications at 64 per app. Cap to 60 to
    /// leave headroom for future system reservations.
    static let pendingLimit = 60

    /// Prefix used on every request identifier we own. Lets `sync` cleanly
    /// remove only our own pending requests (no risk of trashing reminders
    /// scheduled by another framework / extension in the same app).
    static let identifierPrefix = "eav:"

    var authStatus: UNAuthorizationStatus = .notDetermined
    var lastError: String?

    init() {
        Task { await refreshAuthStatus() }
    }

    func refreshAuthStatus() async {
        let s = await UNUserNotificationCenter.current().notificationSettings()
        self.authStatus = s.authorizationStatus
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            await refreshAuthStatus()
            return granted
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Diff the desired pending-notification set against what's currently
    /// scheduled and add / remove the delta. Safe to call repeatedly.
    func sync(tasks: [OrgTask], doneStates: Set<String>, enabled: Bool) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let ownedPendingIds = pending.compactMap { req -> String? in
            req.identifier.hasPrefix(Self.identifierPrefix) ? req.identifier : nil
        }

        // Disabled or permission revoked → drop everything we own.
        guard enabled,
              authStatus == .authorized || authStatus == .provisional || authStatus == .ephemeral
        else {
            if !ownedPendingIds.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: ownedPendingIds)
            }
            return
        }

        // Snapshot now once. Any task whose fireDate is between this snapshot
        // and the end of the async scheduling loop will still be scheduled —
        // the trigger fires at the correct calendar time regardless. The small
        // race (a task that fires during the loop is added then immediately
        // delivered) is acceptable; the next sync call prunes it.
        let now = Date()
        let eligible: [(OrgTask, Date)] = tasks.compactMap { task in
            guard let state = task.todoState, !state.isEmpty,
                  !doneStates.contains(state.uppercased()),
                  let sched = task.scheduled,
                  let comp = sched.start, comp.hour != nil,
                  let fireDate = sched.parsedDate,
                  fireDate > now
            else { return nil }
            return (task, fireDate)
        }
        .sorted { $0.1 < $1.1 }
        .prefix(Self.pendingLimit)
        .map { $0 }

        let wantedIds = Set(eligible.map { identifier(for: $0.0) })

        // Remove stale (owned by us, not in wanted).
        let stale = ownedPendingIds.filter { !wantedIds.contains($0) }
        if !stale.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: stale)
        }

        // Add / update wanted. UNUserNotificationCenter replaces a pending
        // request with the same identifier, so we re-add to pick up edited
        // titles or shifted times.
        for (task, _) in eligible {
            let content = UNMutableNotificationContent()
            content.title = stripOrgMarkup(task.title)
            if !task.category.isEmpty {
                content.subtitle = task.category
            }
            content.sound = .default
            content.userInfo = ["taskId": task.id, "file": task.file, "pos": task.pos]

            guard let comp = task.scheduled?.start else { continue }
            var dc = DateComponents()
            dc.year = comp.year; dc.month = comp.month; dc.day = comp.day
            dc.hour = comp.hour; dc.minute = comp.minute ?? 0
            let trigger = UNCalendarNotificationTrigger(dateMatching: dc, repeats: false)

            let req = UNNotificationRequest(
                identifier: identifier(for: task),
                content: content,
                trigger: trigger
            )
            do {
                try await center.add(req)
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    // MARK: - Helpers

    private func identifier(for task: OrgTask) -> String {
        Self.identifierPrefix + task.id
    }

    // Compiled once at class-load time. Compiling an NSRegularExpression is
    // non-trivial (~microseconds per call); doing it inside stripOrgMarkup on
    // every notification title would repeat that cost O(tasks) times per sync.
    private static let labeledLinkRegex = try! NSRegularExpression(
        pattern: #"\[\[[^\]]+\]\[([^\]]+)\]\]"#)
    private static let bareLinkRegex = try! NSRegularExpression(
        pattern: #"\[\[([^\]]+)\]\]"#)
    // One regex per emphasis marker. Built eagerly so hot-path is just lookup.
    private static let emphasisRegexes: [NSRegularExpression] = {
        ["*", "/", "=", "~", "_", "+"].map { m in
            let esc = NSRegularExpression.escapedPattern(for: m)
            let pat = "(?<![\\w])\(esc)([^\(esc)\\s][^\(esc)]*?)\(esc)(?![\\w])"
            return try! NSRegularExpression(pattern: pat)
        }
    }()

    /// Strip the cheapest org-emphasis markup so notification titles read
    /// naturally on the lock screen. Not as thorough as `renderInline` —
    /// notifications are plain-text, so we trade fidelity for legibility.
    private func stripOrgMarkup(_ s: String) -> String {
        let range = NSRange(s.startIndex..., in: s)
        var out = Self.labeledLinkRegex.stringByReplacingMatches(
            in: s, range: range, withTemplate: "$1")
        let r2 = NSRange(out.startIndex..., in: out)
        out = Self.bareLinkRegex.stringByReplacingMatches(
            in: out, range: r2, withTemplate: "$1")
        for rx in Self.emphasisRegexes {
            let r = NSRange(out.startIndex..., in: out)
            out = rx.stringByReplacingMatches(in: out, range: r, withTemplate: "$1")
        }
        return out
    }
}
#endif
