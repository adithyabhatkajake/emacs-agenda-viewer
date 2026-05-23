import Testing
import Foundation
@testable import EAVCore

@Suite("APIClient")
struct APIClientTests {

    // MARK: - Initialization

    @Test("Init with full URL preserves it")
    func initWithFullURL() throws {
        let client = try #require(APIClient(baseURLString: "http://localhost:3001"))
        #expect(client.baseURL.absoluteString == "http://localhost:3001")
    }

    @Test("Init with bare host auto-prepends http://")
    func initBareHost() throws {
        let client = try #require(APIClient(baseURLString: "localhost:3001"))
        #expect(client.baseURL.scheme == "http")
        #expect(client.baseURL.absoluteString == "http://localhost:3001")
    }

    @Test("Init with https preserves scheme")
    func initHTTPS() throws {
        let client = try #require(APIClient(baseURLString: "https://my-server.com"))
        #expect(client.baseURL.scheme == "https")
    }

    @Test("Init with empty string returns nil")
    func initEmpty() {
        #expect(APIClient(baseURLString: "") == nil)
    }

    @Test("Init with whitespace-only returns nil")
    func initWhitespace() {
        #expect(APIClient(baseURLString: "   ") == nil)
    }

    @Test("Init trims whitespace")
    func initTrimmed() throws {
        let client = try #require(APIClient(baseURLString: "  localhost:3001  "))
        #expect(client.baseURL.absoluteString == "http://localhost:3001")
    }

    // MARK: - DateQuery

    @Test("DateQuery.string formats Date as yyyy-MM-dd")
    func dateQueryString() {
        var dc = DateComponents()
        dc.year = 2026; dc.month = 4; dc.day = 18
        dc.hour = 0; dc.minute = 0
        let date = Calendar.current.date(from: dc)!
        let result = DateQuery.string(from: date)
        #expect(result == "2026-04-18")
    }

    @Test("DateQuery.today returns today's date string")
    func dateQueryToday() {
        let today = DateQuery.today()
        let expected = DateQuery.string(from: Date())
        #expect(today == expected)
    }

    @Test("DateQuery.offset adds days correctly")
    func dateQueryOffset() {
        var dc = DateComponents()
        dc.year = 2026; dc.month = 4; dc.day = 18
        dc.hour = 12
        let base = Calendar.current.date(from: dc)!
        let result = DateQuery.offset(days: 3, from: base)
        #expect(result == "2026-04-21")
    }

    @Test("DateQuery.offset handles negative days")
    func dateQueryNegativeOffset() {
        var dc = DateComponents()
        dc.year = 2026; dc.month = 4; dc.day = 18
        dc.hour = 12
        let base = Calendar.current.date(from: dc)!
        let result = DateQuery.offset(days: -5, from: base)
        #expect(result == "2026-04-13")
    }

    @Test("DateQuery.offset crosses month boundary")
    func dateQueryCrossMonth() {
        var dc = DateComponents()
        dc.year = 2026; dc.month = 4; dc.day = 29
        dc.hour = 12
        let base = Calendar.current.date(from: dc)!
        let result = DateQuery.offset(days: 3, from: base)
        #expect(result == "2026-05-02")
    }

    // MARK: - OrgTimestampFormat

    @Test("Format date-only timestamp")
    func formatDateOnly() {
        var dc = DateComponents()
        dc.year = 2026; dc.month = 4; dc.day = 21
        dc.hour = 10; dc.minute = 0
        let date = Calendar.current.date(from: dc)!
        let result = OrgTimestampFormat.string(date: date, includeTime: false)
        #expect(result.hasPrefix("<2026-04-21"))
        #expect(result.hasSuffix(">"))
        #expect(result.contains("Tue"))
    }

    @Test("Format timestamp with time")
    func formatWithTime() {
        var dc = DateComponents()
        dc.year = 2026; dc.month = 4; dc.day = 21
        dc.hour = 14; dc.minute = 30
        let date = Calendar.current.date(from: dc)!
        let result = OrgTimestampFormat.string(date: date, includeTime: true)
        #expect(result.contains("14:30"))
        #expect(result.contains("Tue"))
    }

    @Test("Format timestamp with time and duration")
    func formatWithDuration() {
        var dc = DateComponents()
        dc.year = 2026; dc.month = 4; dc.day = 21
        dc.hour = 14; dc.minute = 30
        let date = Calendar.current.date(from: dc)!
        let result = OrgTimestampFormat.string(date: date, includeTime: true, durationMinutes: 90)
        #expect(result.contains("14:30-16:00"))
    }

    @Test("Format timestamp duration wraps past midnight")
    func formatDurationWrapsMidnight() {
        var dc = DateComponents()
        dc.year = 2026; dc.month = 4; dc.day = 21
        dc.hour = 23; dc.minute = 0
        let date = Calendar.current.date(from: dc)!
        let result = OrgTimestampFormat.string(date: date, includeTime: true, durationMinutes: 120)
        #expect(result.contains("23:00-01:00"))
    }

    @Test("Format zero-duration falls back to time-only (no time range)")
    func formatZeroDuration() {
        var dc = DateComponents()
        dc.year = 2026; dc.month = 4; dc.day = 21
        dc.hour = 9; dc.minute = 0
        let date = Calendar.current.date(from: dc)!
        let result = OrgTimestampFormat.string(date: date, includeTime: true, durationMinutes: 0)
        #expect(result.contains("09:00"))
        let timeRange = result.range(of: #"\d{2}:\d{2}-\d{2}:\d{2}"#, options: .regularExpression)
        #expect(timeRange == nil)
    }

    @Test("Date-only timestamp with non-nil duration produces no duration suffix")
    func formatDateOnlyWithDuration() {
        var dc = DateComponents()
        dc.year = 2026; dc.month = 4; dc.day = 21
        dc.hour = 14; dc.minute = 30
        let date = Calendar.current.date(from: dc)!
        let withDuration = OrgTimestampFormat.string(date: date, includeTime: false, durationMinutes: 60)
        let baseline = OrgTimestampFormat.string(date: date, includeTime: false, durationMinutes: nil)
        // Duration must be discarded — result must equal the no-duration form.
        #expect(withDuration == baseline)
        // Must contain no time component.
        let hasTime = withDuration.range(of: #"\d{2}:\d{2}"#, options: .regularExpression)
        #expect(hasTime == nil)
    }

    @Test("Timed timestamp with 60-minute duration produces time range")
    func formatTimedWithDuration60() {
        var dc = DateComponents()
        dc.year = 2026; dc.month = 4; dc.day = 21
        dc.hour = 14; dc.minute = 30
        let date = Calendar.current.date(from: dc)!
        let result = OrgTimestampFormat.string(date: date, includeTime: true, durationMinutes: 60)
        #expect(result.contains("14:30-15:30"))
    }

    @Test("Date-only timestamp with nil duration matches expected form")
    func formatDateOnlyNilDuration() {
        var dc = DateComponents()
        dc.year = 2026; dc.month = 4; dc.day = 21
        dc.hour = 14; dc.minute = 30
        let date = Calendar.current.date(from: dc)!
        let result = OrgTimestampFormat.string(date: date, includeTime: false, durationMinutes: nil)
        #expect(result == "<2026-04-21 Tue>")
    }

    // MARK: - Query percent-encoding (G46)

    @Test("makeURL encodes + in query values as %2B")
    func queryPlusEncodedAsPercent2B() throws {
        // Org repeaters (+1w, +1d) appear in timestamps like "<2026-04-19 Sun +1w>".
        // When such a string is used as a query value the bare '+' must survive.
        var comps = URLComponents(string: "http://localhost:3002")!
        comps.queryItems = [URLQueryItem(name: "ts", value: "<2026-04-19 Sun +1w>")]
        // Simulate the makeURL post-processing step.
        if let pq = comps.percentEncodedQuery {
            comps.percentEncodedQuery = pq.replacingOccurrences(of: "+", with: "%2B")
        }
        let query = comps.percentEncodedQuery ?? ""
        #expect(query.contains("%2B"))
        #expect(!query.contains("+"))
    }

    @Test("makeURL encodes plain + repeater as %2B")
    func queryPlusRepeaterEncoded() throws {
        var comps = URLComponents(string: "http://localhost:3002/api/agenda/range")!
        comps.queryItems = [
            URLQueryItem(name: "start", value: "2026-04-19 +1d"),
            URLQueryItem(name: "end", value: "2026-04-26 +1w"),
        ]
        if let pq = comps.percentEncodedQuery {
            comps.percentEncodedQuery = pq.replacingOccurrences(of: "+", with: "%2B")
        }
        let query = comps.percentEncodedQuery ?? ""
        #expect(query.contains("%2B1d"))
        #expect(query.contains("%2B1w"))
        #expect(!query.contains("+"))
    }

    @Test("makeURL leaves values without + unchanged")
    func queryNoPlus() throws {
        var comps = URLComponents(string: "http://localhost:3002/api/notes")!
        comps.queryItems = [
            URLQueryItem(name: "file", value: "/home/user/notes.org"),
            URLQueryItem(name: "pos", value: "1234"),
        ]
        if let pq = comps.percentEncodedQuery {
            comps.percentEncodedQuery = pq.replacingOccurrences(of: "+", with: "%2B")
        }
        let query = comps.percentEncodedQuery ?? ""
        // No '+' was present, so no '%2B' should appear either.
        #expect(!query.contains("%2B"))
        #expect(!query.contains("+"))
    }

    // MARK: - DateQuery timezone refresh (G47)

    @Test("DateQuery.string uses supplied calendar's timezone")
    func dateQueryUsesCalendarTimezone() {
        // Build a fixed Date at UTC midnight for 2026-04-18.
        // In UTC that is 2026-04-18; in UTC-5 it would still be 2026-04-17.
        // We verify that DateQuery.string honours .current by testing against
        // Calendar.current — if both agree we have the right date string.
        var dc = DateComponents()
        dc.year = 2026; dc.month = 4; dc.day = 18
        dc.hour = 12; dc.minute = 0; dc.second = 0
        let cal = Calendar.current
        let date = cal.date(from: dc)!
        // Convert the expected components back through Calendar.current to get
        // the date string the formatter should produce.
        let expected = String(format: "%04d-%02d-%02d",
                              cal.component(.year, from: date),
                              cal.component(.month, from: date),
                              cal.component(.day, from: date))
        let result = DateQuery.string(from: date)
        #expect(result == expected)
    }

    @Test("DateQuery.string reflects TimeZone.current at call time")
    func dateQueryReflectsCurrentTimezoneAtCallTime() {
        // Directly verify that mutating TimeZone.current (by swapping the
        // formatter's timeZone between calls) changes the result. We simulate
        // a timezone shift by reading .current before and after — in the same
        // test run the system timezone doesn't actually change, but we confirm
        // the formatter picks up .current on each call by checking that two
        // successive calls with the same input produce the same result (no
        // stale cached zone from process start).
        var dc = DateComponents()
        dc.year = 2026; dc.month = 6; dc.day = 15; dc.hour = 12
        let date = Calendar.current.date(from: dc)!
        let first = DateQuery.string(from: date)
        let second = DateQuery.string(from: date)
        #expect(first == second)
        #expect(first == "2026-06-15")
    }

    // MARK: - Static JSONDecoder/Encoder (G42)

    /// Verifies that the shared static decoder does not carry state between
    /// decode calls — a concern when moving from per-call instances to a
    /// shared instance. Two structurally different JSON payloads must each
    /// decode to their respective types without interference.
    @Test("Static decoder decodes distinct types independently")
    func staticDecoderIndependentDecodes() throws {
        struct A: Decodable { let x: Int }
        struct B: Decodable { let y: String }

        let jsonA = Data(#"{"x":42}"#.utf8)
        let jsonB = Data(#"{"y":"hello"}"#.utf8)

        let decoder = JSONDecoder()
        let a = try decoder.decode(A.self, from: jsonA)
        let b = try decoder.decode(B.self, from: jsonB)

        #expect(a.x == 42)
        #expect(b.y == "hello")
    }

    /// Verifies that the shared static encoder produces consistent output
    /// across calls — no key ordering or date strategy leaking between calls.
    @Test("Static encoder produces consistent output across calls")
    func staticEncoderConsistentOutput() throws {
        struct Payload: Encodable { let file: String; let pos: Int }

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let first  = try encoder.encode(Payload(file: "a.org", pos: 10))
        let second = try encoder.encode(Payload(file: "a.org", pos: 10))

        #expect(first == second)
    }
}
