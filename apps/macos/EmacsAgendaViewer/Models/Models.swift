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

    private enum CodingKeys: String, CodingKey {
        case id, title, agendaType, todoState, priority, tags, inheritedTags
        case scheduled, deadline, category, level, file, pos
        case effort, warntime, timeOfDay, displayDate, tsDate
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
        let primary = try c.decodeIfPresent(String.self, forKey: .displayDate)
        let fallback = try c.decodeIfPresent(String.self, forKey: .tsDate)
        displayDate = primary ?? fallback
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

    var allActive: [String] { sequences.flatMap(\.active) }
    var allDone: [String] { sequences.flatMap(\.done) }
}

struct OrgConfig: Codable, Hashable, Sendable {
    let deadlineWarningDays: Int
}

struct ClockStatus: Codable, Hashable, Sendable {
    let clocking: Bool
    let file: String?
    let pos: Int?
    let heading: String?
    let startTime: String?
    let elapsed: Int?
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

struct CapturePrompt: Codable, Hashable, Sendable {
    let name: String
    let type: String
    let options: [String]
}
