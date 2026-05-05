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
}
