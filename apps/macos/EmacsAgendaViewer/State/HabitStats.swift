import Foundation

/// Cadence + completion analytics for `:STYLE: habit` headings.
///
/// The math collapses all completion timestamps into "periods" (a day, a
/// week, a month, …) sized to match the heading's scheduled repeater.
/// Anything we render — streak number, last-N cells, completion ratio
/// — is computed in periods, not days, so the same machinery serves
/// daily, weekly, and monthly habits identically.

/// What a single cell in the strip represents. Past cells were either
/// completed in that period or not. The newest cell may also be
/// `upcoming` — the period is still open and the habit hasn't been
/// done yet (no failure judgement until the period closes).
enum HabitCellState: Equatable {
    case done
    case missed
    case upcoming   // current period, not yet completed
}

struct HabitCadence: Equatable, Sendable {
    let component: Calendar.Component   // .day / .weekOfYear / .month / .year
    let value: Int                      // how many of that component per period
    let unitLabel: String               // "d" / "w" / "mo" / "y"

    /// Uniform default window across cadences — the dashboard strip
    /// always renders exactly this many cells regardless of cadence, so
    /// the columnar layout lines up cell-for-cell across rows. A daily
    /// habit shows the last 14 days, a weekly habit the last 14 weeks,
    /// a monthly habit the last 14 months. Per-cadence customization
    /// is intentionally left to a setting (see `defaultHabitWindow`).
    var defaultWindow: Int { 14 }

    static func from(_ repeater: OrgTimestamp.Repeater?) -> HabitCadence {
        // Org's repeater units: h / d / w / m / y (m = month here; minutes
        // never appear on a repeater in practice). Default to daily when a
        // habit somehow has no repeater (rare — usually `org-habit` requires
        // one). Hours land in `.day` because we don't render finer than a day.
        guard let r = repeater, r.value > 0 else {
            return HabitCadence(component: .day, value: 1, unitLabel: "d")
        }
        switch r.unit.lowercased() {
        case "h", "d": return HabitCadence(component: .day,        value: max(1, r.value), unitLabel: "d")
        case "w":      return HabitCadence(component: .weekOfYear, value: max(1, r.value), unitLabel: "w")
        case "m":      return HabitCadence(component: .month,      value: max(1, r.value), unitLabel: "mo")
        case "y":      return HabitCadence(component: .year,       value: max(1, r.value), unitLabel: "y")
        default:       return HabitCadence(component: .day,        value: max(1, r.value), unitLabel: r.unit)
        }
    }
}

struct HabitStats {
    let cadence: HabitCadence
    let currentStreak: Int
    let longestStreak: Int
    /// Oldest cell at index 0, newest (current period) at the end.
    let cells: [HabitCellState]
    let completionRate: Double  // [0, 1] over the same window

    /// Convenience for the dashboard row: "14d" / "3w" / "0mo".
    var streakLabel: String {
        "\(currentStreak)\(cadence.unitLabel)"
    }

    var bestLabel: String {
        "\(longestStreak)\(cadence.unitLabel)"
    }
}

enum HabitMath {
    /// Compute stats for one habit. `completions` are the raw org
    /// timestamp strings from the daemon (e.g. `"2026-05-11 Mon 14:32"`);
    /// we extract just the date and bucket by period.
    ///
    /// `lastRepeat` is org-habit's `:LAST_REPEAT:` property
    /// (`"[2026-05-12 Tue 09:52]"` — brackets included). On habit
    /// completion via `.+1d` / `++1w` repeaters, org-habit advances
    /// SCHEDULED and writes LAST_REPEAT but doesn't always append a
    /// `State "DONE"` line to LOGBOOK. Without merging LAST_REPEAT in,
    /// today's completion would be invisible to the dashboard.
    static func stats(
        completions: [String]?,
        repeater: OrgTimestamp.Repeater?,
        lastRepeat: String? = nil,
        window: Int? = nil,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> HabitStats {
        let cadence = HabitCadence.from(repeater)
        let windowLength = window ?? cadence.defaultWindow

        // Bucket the completion dates by period. We hash periods by the
        // period's start-date timestamp (truncated via DateComponents).
        var dates = (completions ?? []).compactMap(parseOrgDate)
        if let lr = lastRepeat,
           let d = parseOrgDate(lr.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))) {
            dates.append(d)
        }
        var doneSet = Set<Date>()
        for d in dates {
            doneSet.insert(periodStart(for: d, cadence: cadence, calendar: calendar))
        }

        // Build the cells, oldest-first. Index 0 is `window-1` periods
        // before the current period; the last index is the current period.
        let currentPeriod = periodStart(for: now, cadence: cadence, calendar: calendar)
        var cells: [HabitCellState] = []
        cells.reserveCapacity(windowLength)
        for offset in stride(from: windowLength - 1, through: 0, by: -1) {
            guard let cellStart = calendar.date(
                byAdding: cadence.component,
                value: -offset * cadence.value,
                to: currentPeriod
            ) else { continue }
            let cellKey = periodStart(for: cellStart, cadence: cadence, calendar: calendar)
            if doneSet.contains(cellKey) {
                cells.append(.done)
            } else if cellKey == currentPeriod {
                cells.append(.upcoming)
            } else {
                cells.append(.missed)
            }
        }

        // Current streak: walk backwards from the most recently *closed*
        // period (i.e. yesterday for daily, last week for weekly). The
        // open current period doesn't break a streak — you haven't missed
        // it yet, you just haven't done it yet.
        var currentStreak = 0
        var cursor = calendar.date(
            byAdding: cadence.component,
            value: -cadence.value,
            to: currentPeriod
        ) ?? currentPeriod
        while doneSet.contains(cursor) {
            currentStreak += 1
            guard let prev = calendar.date(
                byAdding: cadence.component,
                value: -cadence.value,
                to: cursor
            ) else { break }
            cursor = prev
        }
        // If the current period is already done, prepend it to the streak —
        // the streak runs through "today" inclusively when we've shipped.
        if doneSet.contains(currentPeriod) {
            currentStreak += 1
        }

        // Longest streak: scan all unique completed periods in order, count
        // consecutive runs by cadence step.
        let sortedDone = doneSet.sorted()
        var longestStreak = 0
        var run = 0
        var prev: Date? = nil
        for d in sortedDone {
            if let p = prev, let expected = calendar.date(
                byAdding: cadence.component,
                value: cadence.value,
                to: p
            ), calendar.isDate(expected, equalTo: d, toGranularity: cadence.component) {
                run += 1
            } else {
                run = 1
            }
            longestStreak = max(longestStreak, run)
            prev = d
        }

        // Completion rate: fraction of window cells that are .done.
        let doneCount = cells.filter { $0 == .done }.count
        let rate = cells.isEmpty ? 0.0 : Double(doneCount) / Double(cells.count)

        return HabitStats(
            cadence: cadence,
            currentStreak: currentStreak,
            longestStreak: longestStreak,
            cells: cells,
            completionRate: rate
        )
    }

    /// `2026-05-11 Mon 14:32` → 2026-05-11. We don't care about the
    /// time-of-day for periodization — anything completed inside the
    /// period counts as that period being done.
    static func parseOrgDate(_ raw: String) -> Date? {
        // Strip the day-of-week + clock portion: keep only the leading
        // YYYY-MM-DD. Doing this with substring + scanning avoids the
        // DateFormatter locale-sensitivity that's burned us before.
        let prefix = raw.prefix(10)
        let parts = prefix.split(separator: "-")
        guard parts.count == 3,
              let y = Int(parts[0]),
              let m = Int(parts[1]),
              let d = Int(parts[2]) else { return nil }
        var dc = DateComponents()
        dc.year = y; dc.month = m; dc.day = d
        return Calendar.current.date(from: dc)
    }

    /// First instant of the period containing `date`. For daily cadence
    /// that's startOfDay; for weekly it's the start of the calendar
    /// week; for monthly the 1st of the month; etc.
    ///
    /// Week starts on Monday and ends on Sunday — explicit override of
    /// the system locale's `firstWeekday` (US sets Sunday). A weekly
    /// habit completed on Sunday belongs to the Monday-Sunday week
    /// that contains that Sunday, not the next week that starts the
    /// following Monday.
    ///
    /// Month is calendar-month (1st through 28/29/30/31), regardless
    /// of which day-of-month the timestamp falls on.
    private static func periodStart(
        for date: Date,
        cadence: HabitCadence,
        calendar: Calendar
    ) -> Date {
        switch cadence.component {
        case .day:
            return calendar.startOfDay(for: date)
        case .weekOfYear:
            var cal = calendar
            cal.firstWeekday = 2  // Monday (ISO-8601). 1 = Sunday in NSCalendar terms.
            return cal.date(from: cal.dateComponents(
                [.yearForWeekOfYear, .weekOfYear], from: date)) ?? date
        case .month:
            return calendar.date(from: calendar.dateComponents(
                [.year, .month], from: date)) ?? date
        case .year:
            return calendar.date(from: calendar.dateComponents(
                [.year], from: date)) ?? date
        default:
            return calendar.startOfDay(for: date)
        }
    }
}

extension OrgTask {
    /// True when the org heading carries `:STYLE: habit`. Case-insensitive
    /// because property keys are uppercase on the wire but property
    /// values are user-supplied.
    var isHabit: Bool {
        guard let v = properties?["STYLE"] else { return false }
        return v.caseInsensitiveCompare("habit") == .orderedSame
    }
}
