import Testing
import Foundation
@testable import EAVCore

@Suite("Model Decoding")
struct ModelDecodingTests {

    // MARK: - OrgTask

    @Test("Full OrgTask decodes all fields")
    func fullTaskDecoding() throws {
        let tasks: [OrgTask] = try decodeFixture("tasks.json")
        let task = tasks[0]

        #expect(task.id == "/home/user/org/work.org::Buy groceries")
        #expect(task.title == "Buy groceries")
        #expect(task.todoState == "TODO")
        #expect(task.priority == "A")
        #expect(task.tags == ["errand"])
        #expect(task.inheritedTags == ["personal"])
        #expect(task.category == "Work")
        #expect(task.level == 2)
        #expect(task.file == "/home/user/org/work.org")
        #expect(task.pos == 1234)
        #expect(task.effort == "1:00")
        #expect(task.notes == "Don't forget milk")
        #expect(task.properties?["STYLE"] == "habit")
    }

    @Test("Task scheduled timestamp decodes correctly")
    func taskScheduledTimestamp() throws {
        let tasks: [OrgTask] = try decodeFixture("tasks.json")
        let s = try #require(tasks[0].scheduled)

        #expect(s.raw == "<2026-04-18 Sat 14:30>")
        #expect(s.date == "2026-04-18")
        #expect(s.start?.year == 2026)
        #expect(s.start?.month == 4)
        #expect(s.start?.day == 18)
        #expect(s.start?.hour == 14)
        #expect(s.start?.minute == 30)
        #expect(s.type == "active")
        #expect(s.hasTime == true)
    }

    @Test("Task deadline with warning period")
    func taskDeadlineWarning() throws {
        let tasks: [OrgTask] = try decodeFixture("tasks.json")
        let d = try #require(tasks[0].deadline)
        let warn = try #require(d.warning)

        #expect(d.date == "2026-04-20")
        #expect(warn.value == 3)
        #expect(warn.unit == "d")
    }

    @Test("Minimal task decodes with null optionals")
    func minimalTaskDecoding() throws {
        let tasks: [OrgTask] = try decodeFixture("tasks.json")
        let task = tasks[1]

        #expect(task.todoState == "NEXT")
        #expect(task.priority == "B")
        #expect(task.scheduled == nil)
        #expect(task.deadline == nil)
        #expect(task.effort == nil)
        #expect(task.notes == nil)
        #expect(task.properties == nil)
        #expect(task.tags.isEmpty)
    }

    @Test("Task with parentId and closed date")
    func taskWithParentAndClosed() throws {
        let tasks: [OrgTask] = try decodeFixture("tasks.json")
        let task = tasks[2]

        #expect(task.todoState == "DONE")
        #expect(task.priority == nil)
        #expect(task.closed == "[2026-04-10 Fri 09:00]")
        #expect(task.parentId == "/home/user/org/archive.org::Parent")
    }

    // MARK: - AgendaEntry

    @Test("AgendaEntry decodes displayDate")
    func agendaEntryDisplayDate() throws {
        let entries: [AgendaEntry] = try decodeFixture("agenda-entries.json")
        let entry = entries[0]

        #expect(entry.id == "/home/user/org/work.org::Standup")
        #expect(entry.agendaType == "scheduled")
        #expect(entry.timeOfDay == " 9:30")
        #expect(entry.displayDate == "2026-04-18")
        #expect(entry.category == "Work")
    }

    @Test("AgendaEntry falls back to tsDate when displayDate absent")
    func agendaEntryTsDateFallback() throws {
        let entries: [AgendaEntry] = try decodeFixture("agenda-entries.json")
        let entry = entries[3]

        #expect(entry.title == "Team sync")
        #expect(entry.displayDate == "2026-04-19")
    }

    @Test("AgendaEntry decodes string level as character count")
    func agendaEntryStringLevel() throws {
        let entries: [AgendaEntry] = try decodeFixture("agenda-entries.json")
        let entry = entries[3]

        #expect(entry.level == 2)
    }

    @Test("AgendaEntry decodes int level directly")
    func agendaEntryIntLevel() throws {
        let entries: [AgendaEntry] = try decodeFixture("agenda-entries.json")

        #expect(entries[0].level == 2)
    }

    @Test("AgendaEntry with repeater on scheduled timestamp")
    func agendaEntryRepeater() throws {
        let entries: [AgendaEntry] = try decodeFixture("agenda-entries.json")
        let rep = try #require(entries[2].scheduled?.repeater)

        #expect(rep.type == ".+")
        #expect(rep.value == 1)
        #expect(rep.unit == "d")
    }

    // MARK: - TodoKeywords

    @Test("TodoKeywords allActive and allDone computed properties")
    func todoKeywords() throws {
        let kw: TodoKeywords = try decodeFixture("keywords.json")

        #expect(kw.allActive == ["TODO", "NEXT", "ACTV", "WAIT"])
        #expect(kw.allDone == ["DONE", "CANCELLED", "SMDY"])
        #expect(kw.sequences.count == 2)
    }

    // MARK: - OrgPriorities

    @Test("OrgPriorities.all generates range A through D")
    func prioritiesAll() throws {
        let p: OrgPriorities = try decodeFixture("priorities.json")

        #expect(p.highest == "A")
        #expect(p.lowest == "D")
        #expect(p.default == "B")
        #expect(p.all == ["A", "B", "C", "D"])
    }

    // MARK: - ClockStatus

    @Test("ClockStatus decodes active clock")
    func clockStatus() throws {
        let c: ClockStatus = try decodeFixture("clock-status.json")

        #expect(c.clocking == true)
        #expect(c.file == "/home/user/org/work.org")
        #expect(c.pos == 500)
        #expect(c.heading == "Standup")
        #expect(c.elapsed == 1800)
    }

    // MARK: - AgendaFile

    @Test("AgendaFile decodes and generates id from path")
    func agendaFiles() throws {
        let files: [AgendaFile] = try decodeFixture("files.json")

        #expect(files.count == 3)
        #expect(files[0].id == "/home/user/org/work.org")
        #expect(files[0].name == "work")
        #expect(files[0].category == "Work")
    }

    // MARK: - OrgTimestamp computed properties

    @Test("OrgTimestamp.hasTime returns true when hour present")
    func timestampHasTime() {
        let ts = makeTimestamp(hour: 14, minute: 30)
        #expect(ts.hasTime == true)
    }

    @Test("OrgTimestamp.hasTime returns false when hour absent")
    func timestampNoTime() {
        let ts = makeTimestamp()
        #expect(ts.hasTime == false)
    }

    @Test("OrgTimestamp.parsedDate produces correct Date")
    func timestampParsedDate() {
        let ts = makeTimestamp(year: 2026, month: 4, day: 18, hour: 14, minute: 30)
        let date = ts.parsedDate
        let cal = Calendar.current
        #expect(date != nil)
        #expect(cal.component(.year, from: date!) == 2026)
        #expect(cal.component(.month, from: date!) == 4)
        #expect(cal.component(.day, from: date!) == 18)
        #expect(cal.component(.hour, from: date!) == 14)
        #expect(cal.component(.minute, from: date!) == 30)
    }

    // MARK: - Round-trip encoding

    @Test("OrgTask round-trips through encode/decode")
    func taskRoundTrip() throws {
        let original: [OrgTask] = try decodeFixture("tasks.json")
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode([OrgTask].self, from: encoded)
        #expect(decoded == original)
    }

    @Test("AgendaEntry round-trips through encode/decode")
    func agendaEntryRoundTrip() throws {
        let original: [AgendaEntry] = try decodeFixture("agenda-entries.json")
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode([AgendaEntry].self, from: encoded)
        #expect(decoded == original)
    }
}
