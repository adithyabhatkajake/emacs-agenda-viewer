import Foundation
@testable import EAVCore

func fixtureData(_ name: String) throws -> Data {
    guard let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil) else {
        fatalError("Missing fixture: \(name)")
    }
    return try Data(contentsOf: url)
}

func decodeFixture<T: Decodable>(_ name: String, as type: T.Type = T.self) throws -> T {
    try JSONDecoder().decode(T.self, from: fixtureData(name))
}

func makeTimestamp(
    raw: String = "<2026-04-18 Sat>",
    date: String = "2026-04-18",
    year: Int = 2026, month: Int = 4, day: Int = 18,
    hour: Int? = nil, minute: Int? = nil,
    type: String = "active"
) -> OrgTimestamp {
    let json: [String: Any] = [
        "raw": raw,
        "date": date,
        "start": (
            ["year": year, "month": month, "day": day] as [String: Any]
        ).merging(
            hour.map { ["hour": $0] } ?? [:], uniquingKeysWith: { _, b in b }
        ).merging(
            minute.map { ["minute": $0] } ?? [:], uniquingKeysWith: { _, b in b }
        ),
        "type": type,
    ]
    let data = try! JSONSerialization.data(withJSONObject: json)
    return try! JSONDecoder().decode(OrgTimestamp.self, from: data)
}

func makeTask(
    id: String = "test::task",
    title: String = "Test task",
    todoState: String? = "TODO",
    priority: String? = nil,
    tags: [String] = [],
    inheritedTags: [String] = [],
    scheduled: OrgTimestamp? = nil,
    deadline: OrgTimestamp? = nil,
    category: String = "Test",
    file: String = "/test.org",
    pos: Int = 1
) -> OrgTask {
    let json: [String: Any?] = [
        "id": id, "title": title, "todoState": todoState,
        "priority": priority, "tags": tags, "inheritedTags": inheritedTags,
        "category": category, "level": 1, "file": file, "pos": pos,
    ]
    let filtered = json.compactMapValues { $0 }
    var merged = filtered as [String: Any]
    if let s = scheduled {
        merged["scheduled"] = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(s))
    }
    if let d = deadline {
        merged["deadline"] = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(d))
    }
    let data = try! JSONSerialization.data(withJSONObject: merged)
    return try! JSONDecoder().decode(OrgTask.self, from: data)
}

func makeAgendaEntry(
    id: String = "test::entry",
    title: String = "Test entry",
    agendaType: String = "scheduled",
    todoState: String? = "TODO",
    priority: String? = nil,
    tags: [String] = [],
    inheritedTags: [String] = [],
    scheduled: OrgTimestamp? = nil,
    deadline: OrgTimestamp? = nil,
    category: String = "Test",
    file: String = "/test.org",
    pos: Int = 1,
    timeOfDay: String? = nil,
    displayDate: String? = "2026-04-18"
) -> AgendaEntry {
    let json: [String: Any?] = [
        "id": id, "title": title, "agendaType": agendaType,
        "todoState": todoState, "priority": priority,
        "tags": tags, "inheritedTags": inheritedTags,
        "category": category, "level": 1, "file": file, "pos": pos,
        "timeOfDay": timeOfDay, "displayDate": displayDate,
    ]
    var merged = json.compactMapValues { $0 } as [String: Any]
    if let s = scheduled {
        merged["scheduled"] = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(s))
    }
    if let d = deadline {
        merged["deadline"] = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(d))
    }
    let data = try! JSONSerialization.data(withJSONObject: merged)
    return try! JSONDecoder().decode(AgendaEntry.self, from: data)
}
