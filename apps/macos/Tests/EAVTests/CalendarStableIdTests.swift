import Testing
import Foundation
@testable import EAVCore

@Suite("CalendarStableId.makeStableId")
struct CalendarStableIdTests {

    private let refDate = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let endDate  = Date(timeIntervalSinceReferenceDate: 800_003_600)

    // 1. eventIdentifier present → use it (highest priority).
    @Test("Returns eventIdentifier when non-nil, ignoring other fields")
    func returnsEventIdentifierWhenPresent() {
        let id = CalendarStableId.makeStableId(
            eventIdentifier: "evt-abc",
            externalIdentifier: "ext-xyz",
            title: "Meeting",
            start: refDate,
            end: endDate,
            calendarId: "cal-1"
        )
        #expect(id == "evt-abc")
    }

    // 2. eventIdentifier nil, externalIdentifier non-nil → use external id.
    @Test("Returns externalIdentifier when eventIdentifier is nil")
    func returnsExternalIdentifierWhenEventIdNil() {
        let id = CalendarStableId.makeStableId(
            eventIdentifier: nil,
            externalIdentifier: "ext-xyz",
            title: "Meeting",
            start: refDate,
            end: endDate,
            calendarId: "cal-1"
        )
        #expect(id == "ext-xyz")
    }

    // 3. Both nil → deterministic fallback (not UUID).
    @Test("Returns deterministic local id when both identifiers are nil")
    func returnsDeterministicIdWhenBothNil() {
        let id1 = CalendarStableId.makeStableId(
            eventIdentifier: nil,
            externalIdentifier: nil,
            title: "Standup",
            start: refDate,
            end: endDate,
            calendarId: "cal-2"
        )
        let id2 = CalendarStableId.makeStableId(
            eventIdentifier: nil,
            externalIdentifier: nil,
            title: "Standup",
            start: refDate,
            end: endDate,
            calendarId: "cal-2"
        )
        #expect(id1 == id2)
        #expect(id1.hasPrefix(CalendarStableId.localPrefix))
    }

    // 3b. Different start → different id (not colliding).
    @Test("Different start dates produce different local ids")
    func differentStartProducesDifferentId() {
        let later = refDate.addingTimeInterval(3600)
        let id1 = CalendarStableId.makeStableId(
            eventIdentifier: nil,
            externalIdentifier: nil,
            title: "Standup",
            start: refDate,
            end: endDate,
            calendarId: "cal-2"
        )
        let id2 = CalendarStableId.makeStableId(
            eventIdentifier: nil,
            externalIdentifier: nil,
            title: "Standup",
            start: later,
            end: endDate,
            calendarId: "cal-2"
        )
        #expect(id1 != id2)
    }

    // 3c. Different title → different id.
    @Test("Different titles produce different local ids")
    func differentTitleProducesDifferentId() {
        let id1 = CalendarStableId.makeStableId(
            eventIdentifier: nil, externalIdentifier: nil,
            title: "Alpha", start: refDate, end: endDate, calendarId: "cal-1"
        )
        let id2 = CalendarStableId.makeStableId(
            eventIdentifier: nil, externalIdentifier: nil,
            title: "Beta",  start: refDate, end: endDate, calendarId: "cal-1"
        )
        #expect(id1 != id2)
    }

    // 3d. Different calendarId → different id.
    @Test("Different calendar ids produce different local ids")
    func differentCalendarIdProducesDifferentId() {
        let id1 = CalendarStableId.makeStableId(
            eventIdentifier: nil, externalIdentifier: nil,
            title: "Alpha", start: refDate, end: endDate, calendarId: "cal-A"
        )
        let id2 = CalendarStableId.makeStableId(
            eventIdentifier: nil, externalIdentifier: nil,
            title: "Alpha", start: refDate, end: endDate, calendarId: "cal-B"
        )
        #expect(id1 != id2)
    }

    // isLocalId correctly classifies ids.
    @Test("isLocalId returns true only for local-prefix ids")
    func isLocalIdClassifiesCorrectly() {
        let localId = CalendarStableId.makeLocalId(
            title: "X", start: refDate, end: nil, calendarId: "c"
        )
        #expect(CalendarStableId.isLocalId(localId) == true)
        #expect(CalendarStableId.isLocalId("evt-abc") == false)
        #expect(CalendarStableId.isLocalId("ext-xyz") == false)
    }

    // nil end date is handled without crash.
    @Test("Nil end date produces a stable id without crash")
    func nilEndDateIsStable() {
        let id1 = CalendarStableId.makeStableId(
            eventIdentifier: nil, externalIdentifier: nil,
            title: "All-day", start: refDate, end: nil, calendarId: "cal-1"
        )
        let id2 = CalendarStableId.makeStableId(
            eventIdentifier: nil, externalIdentifier: nil,
            title: "All-day", start: refDate, end: nil, calendarId: "cal-1"
        )
        #expect(id1 == id2)
        #expect(id1.hasPrefix(CalendarStableId.localPrefix))
    }
}
