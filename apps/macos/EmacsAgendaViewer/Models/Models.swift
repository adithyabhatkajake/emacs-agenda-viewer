import Foundation

struct OrgTimestamp: Codable, Hashable, Sendable {
    let raw: String
    let date: String
    let start: Component?
    let end: Component?
    let type: String?
    let repeater: Repeater?
    let warning: Warning?

    struct Component: Codable, Hashable, Sendable {
        let year: Int
        let month: Int
        let day: Int
        let hour: Int?
        let minute: Int?
    }

    struct Repeater: Codable, Hashable, Sendable {
        let type: String
        let value: Int
        let unit: String
    }

    struct Warning: Codable, Hashable, Sendable {
        let value: Int
        let unit: String
    }

    var hasTime: Bool { start?.hour != nil }

    var parsedDate: Date? {
        if let comp = start {
            var dc = DateComponents()
            dc.year = comp.year; dc.month = comp.month; dc.day = comp.day
            dc.hour = comp.hour ?? 0; dc.minute = comp.minute ?? 0
            return Calendar.current.date(from: dc)
        }
        return OrgTimestamp.dayFormatter.date(from: date)
    }

    /// Parse the leading YYYY-MM-DD from a free-form org timestamp string
    /// (e.g. `"<2026-04-19 Sun .+1d>"` or `"2026-05-11 Mon 14:32"`).
    /// Returns midnight in `Calendar.current` for the extracted date.
    /// Returns nil when no YYYY-MM-DD prefix can be found.
    static func parseDateString(_ raw: String) -> Date? {
        // Hot path: this is called from list sort comparators and habit
        // streak math, so the old regex-compile + DateFormatter cost
        // dominated render time. Parse the first YYYY-MM-DD run by hand and
        // memoize on the raw string (NSCache is thread-safe and bounded).
        if let hit = dateStringCache.object(forKey: raw as NSString) {
            return hit as Date
        }
        guard let date = scanLeadingDate(raw) else { return nil }
        dateStringCache.setObject(date as NSDate, forKey: raw as NSString)
        return date
    }

    // NSCache is internally thread-safe; the unsafe annotation only silences
    // the global-mutable-state check (the cache has no unsynchronized state).
    nonisolated(unsafe) private static let dateStringCache = NSCache<NSString, NSDate>()

    /// Gregorian / current-time-zone calendar reused across `scanLeadingDate`
    /// calls — building a `Calendar` per parse is itself measurable.
    private static let gregorian: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        return c
    }()

    /// Find the first `YYYY-MM-DD` run in `raw` with no regex and no
    /// `DateFormatter`, returning midnight in the gregorian calendar. Scans
    /// the UTF-8 bytes; multibyte scalars have the high bit set so they never
    /// match the ASCII digit/dash test.
    private static func scanLeadingDate(_ raw: String) -> Date? {
        let b = Array(raw.utf8)
        guard b.count >= 10 else { return nil }
        let zero = UInt8(ascii: "0"), nine = UInt8(ascii: "9"), dash = UInt8(ascii: "-")
        func d(_ x: UInt8) -> Bool { x >= zero && x <= nine }
        var i = 0
        let last = b.count - 10
        while i <= last {
            if d(b[i]), d(b[i+1]), d(b[i+2]), d(b[i+3]), b[i+4] == dash,
               d(b[i+5]), d(b[i+6]), b[i+7] == dash, d(b[i+8]), d(b[i+9]) {
                let year = Int(b[i]-zero)*1000 + Int(b[i+1]-zero)*100
                         + Int(b[i+2]-zero)*10 + Int(b[i+3]-zero)
                let month = Int(b[i+5]-zero)*10 + Int(b[i+6]-zero)
                let day = Int(b[i+8]-zero)*10 + Int(b[i+9]-zero)
                var dc = DateComponents()
                dc.year = year; dc.month = month; dc.day = day
                return gregorian.date(from: dc)
            }
            i += 1
        }
        return nil
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

struct OrgTask: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let title: String
    let todoState: String?
    let priority: String?
    let tags: [String]
    let inheritedTags: [String]
    let scheduled: OrgTimestamp?
    let deadline: OrgTimestamp?
    let closed: String?
    /// Raw org timestamps mined from the heading's LOGBOOK drawer when
    /// the heading is flagged `:STYLE: habit`. Newest-first per the
    /// daemon. Nil for non-habit headings — the daemon doesn't emit
    /// this field outside of habits to keep the wire payload lean.
    let completions: [String]?
    let category: String
    let level: Int
    let file: String
    let pos: Int
    let parentId: String?
    let effort: String?
    let notes: String?
    let activeTimestamps: [OrgTimestamp]?
    let properties: [String: String]?
}

struct AgendaEntry: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let title: String
    let agendaType: String
    let todoState: String?
    let priority: String?
    let tags: [String]
    let inheritedTags: [String]
    let scheduled: OrgTimestamp?
    let deadline: OrgTimestamp?
    let category: String
    let level: Int
    let file: String
    let pos: Int
    let effort: String?
    let warntime: String?
    let timeOfDay: String?
    let displayDate: String?
    /// The date of the triggering timestamp (YYYY-MM-DD). Distinct from
    /// `displayDate`: org-agenda may render a row on one day while the
    /// underlying timestamp lives on another (e.g. range entries, diary
    /// sexps). Kept as a separate stored field so encode→decode round
    /// trips don't conflate the two.
    let tsDate: String?
    /// Org-agenda's computed offset descriptor, e.g. "In 3 d.:" or "1 d. ago:".
    /// Passed through from elisp; nil when org-agenda did not produce one.
    let extra: String?
    /// Mirrors `:STYLE: habit` on the underlying heading. Lets list
    /// views filter habit-driven rows from Today/Upcoming without
    /// cross-referencing `/api/tasks`.
    let isHabit: Bool
    /// Heading body content, mirroring `OrgTask.notes`. Nil when unset.
    let notes: String?

    /// Legacy flatten: prefer `displayDate`, fall back to `tsDate`. Use
    /// from UI grouping/filter sites that previously read `displayDate`
    /// before the two were split.
    var effectiveDate: String? { displayDate ?? tsDate }

    private enum CodingKeys: String, CodingKey {
        case id, title, agendaType, todoState, priority, tags, inheritedTags
        case scheduled, deadline, category, level, file, pos
        case effort, warntime, timeOfDay, displayDate, tsDate, extra, isHabit, notes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        agendaType = try c.decode(String.self, forKey: .agendaType)
        todoState = try c.decodeIfPresent(String.self, forKey: .todoState)
        priority = try c.decodeIfPresent(String.self, forKey: .priority)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        inheritedTags = try c.decodeIfPresent([String].self, forKey: .inheritedTags) ?? []
        scheduled = try c.decodeIfPresent(OrgTimestamp.self, forKey: .scheduled)
        deadline = try c.decodeIfPresent(OrgTimestamp.self, forKey: .deadline)
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? ""
        // Server sends Int from /api/tasks but a whitespace-prefix String from /api/agenda;
        // count non-space characters or fall back to the string length.
        if let intLevel = try? c.decode(Int.self, forKey: .level) {
            level = intLevel
        } else if let strLevel = try? c.decode(String.self, forKey: .level) {
            level = strLevel.count
        } else {
            level = 0
        }
        file = try c.decode(String.self, forKey: .file)
        pos = try c.decode(Int.self, forKey: .pos)
        effort = try c.decodeIfPresent(String.self, forKey: .effort)
        warntime = try c.decodeIfPresent(String.self, forKey: .warntime)
        timeOfDay = try c.decodeIfPresent(String.self, forKey: .timeOfDay)
        displayDate = try c.decodeIfPresent(String.self, forKey: .displayDate)
        tsDate = try c.decodeIfPresent(String.self, forKey: .tsDate)
        extra = try c.decodeIfPresent(String.self, forKey: .extra)
        isHabit = (try? c.decodeIfPresent(Bool.self, forKey: .isHabit)) ?? false
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(agendaType, forKey: .agendaType)
        try c.encodeIfPresent(todoState, forKey: .todoState)
        try c.encodeIfPresent(priority, forKey: .priority)
        try c.encode(tags, forKey: .tags)
        try c.encode(inheritedTags, forKey: .inheritedTags)
        try c.encodeIfPresent(scheduled, forKey: .scheduled)
        try c.encodeIfPresent(deadline, forKey: .deadline)
        try c.encode(category, forKey: .category)
        try c.encode(level, forKey: .level)
        try c.encode(file, forKey: .file)
        try c.encode(pos, forKey: .pos)
        try c.encodeIfPresent(effort, forKey: .effort)
        try c.encodeIfPresent(warntime, forKey: .warntime)
        try c.encodeIfPresent(timeOfDay, forKey: .timeOfDay)
        try c.encodeIfPresent(displayDate, forKey: .displayDate)
        try c.encodeIfPresent(tsDate, forKey: .tsDate)
        try c.encodeIfPresent(extra, forKey: .extra)
        if isHabit { try c.encode(true, forKey: .isHabit) }
        try c.encodeIfPresent(notes, forKey: .notes)
    }
}

struct AgendaFile: Codable, Hashable, Identifiable, Sendable {
    var id: String { path }
    let path: String
    let name: String
    let category: String
}

struct TodoKeywords: Codable, Hashable, Sendable {
    let sequences: [Sequence]

    struct Sequence: Codable, Hashable, Sendable {
        let active: [String]
        let done: [String]
    }

    /// Flatten all sequences' active keywords, deduped in first-seen order.
    /// Users with multiple TODO sequences typically repeat the same keyword
    /// names across them (e.g. each `… | DONE KILL`), which would otherwise
    /// appear as dupes in pickers and break `id: \.self` ForEach iteration.
    var allActive: [String] {
        var seen = Set<String>()
        return sequences.flatMap(\.active).filter { seen.insert($0).inserted }
    }
    var allDone: [String] {
        var seen = Set<String>()
        return sequences.flatMap(\.done).filter { seen.insert($0).inserted }
    }
}

struct OrgConfig: Codable, Hashable, Sendable {
    let deadlineWarningDays: Int
}

struct OrgListConfig: Codable, Hashable, Sendable {
    let allowAlphabetical: Bool
}

struct OrgPriorities: Codable, Hashable, Sendable {
    let highest: String
    let lowest: String
    let `default`: String

    var all: [String] {
        guard let h = highest.unicodeScalars.first?.value,
              let l = lowest.unicodeScalars.first?.value,
              h <= l else { return [] }
        return (h...l).compactMap { UnicodeScalar($0) }.map { String($0) }
    }
}

struct ClockStatus: Codable, Hashable, Sendable {
    let clocking: Bool
    let file: String?
    let pos: Int?
    let heading: String?
    let startTime: String?
    let elapsed: Int?
}

struct Clock: Codable, Identifiable, Hashable, Sendable {
    let id: Int64
    let taskId: String
    let file: String?
    let title: String?
    let start: Int64
    let end: Int64?
    let note: String?
}

struct RefileTarget: Codable, Hashable, Identifiable, Sendable {
    var id: String { "\(file):\(pos)" }
    let name: String
    let file: String
    let pos: Int
}

struct CaptureTemplate: Codable, Hashable, Identifiable, Sendable {
    var id: String { key }
    let key: String
    let description: String
    let type: String?
    let isGroup: Bool
    let targetType: String?
    let targetFile: String?
    let targetHeadline: String?
    let template: String?
    let templateIsFunction: Bool?
    let prompts: [CapturePrompt]?
    let webSupported: Bool
}

struct HabitCadenceSpec: Codable, Hashable, Sendable {
    /// One of `+`, `++`, `.+`.
    let kind: String
    /// The "due" interval value.
    let value: Int64
    /// One of `d`, `w`, `m`, `y`.
    let unit: String
    /// Relaxed-range upper interval value (the `/2w` in `.+1w/2w`). Nil for
    /// simple cadences.
    let maxValue: Int64?
    /// Unit for the upper interval; can differ from `unit` (e.g. `+5d/3w`).
    let maxUnit: String?
}

struct Habit: Codable, Identifiable, Hashable, Sendable {
    /// Server-generated UUID; satisfies `Identifiable`.
    let id: String
    let title: String
    let cadence: HabitCadenceSpec
    let category: String?
    let priority: String?
    let tags: [String]
    let notes: String?
    /// `YYYY-MM-DD`, the base date for `+`/`++` cycle math.
    let anchorDate: String?
    let active: Bool
    /// When true, the habit's checklist resets on each completion.
    let resetChecklistOnComplete: Bool
    /// Completion timestamps as org-style strings (`YYYY-MM-DD Day HH:MM`).
    let completions: [String]
    /// Server-computed `YYYY-MM-DD` of the next due date.
    let nextDue: String?
    /// Server-computed `due` | `overdue` | `ok`.
    let state: String?
}

struct CapturePrompt: Codable, Hashable, Sendable {
    let name: String
    let type: String
    let options: [String]
}
