import Testing
import Foundation
@testable import EAVCore

@Suite("DaemonHost pid parsing")
struct DaemonHostPidParseTests {

    @Test("Int literal from JSONSerialization parses correctly")
    func intPid() throws {
        let data = try #require(#"{"pid": 12345}"#.data(using: .utf8))
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(parsePid(from: obj["pid"]) == 12345)
    }

    @Test("Floating-point literal (NSNumber wrapping Double) parses correctly")
    func floatPid() throws {
        let data = try #require(#"{"pid": 12345.0}"#.data(using: .utf8))
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(parsePid(from: obj["pid"]) == 12345)
    }

    @Test("String-encoded pid fails gracefully")
    func stringPid() throws {
        let data = try #require(#"{"pid": "12345"}"#.data(using: .utf8))
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(parsePid(from: obj["pid"]) == nil)
    }

    @Test("Missing pid field fails gracefully")
    func missingPid() throws {
        let data = try #require(#"{}"#.data(using: .utf8))
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(parsePid(from: obj["pid"]) == nil)
    }

    @Test("Zero pid is rejected")
    func zeroPid() throws {
        let data = try #require(#"{"pid": 0}"#.data(using: .utf8))
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(parsePid(from: obj["pid"]) == nil)
    }

    @Test("Negative pid is rejected")
    func negativePid() throws {
        let data = try #require(#"{"pid": -1}"#.data(using: .utf8))
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(parsePid(from: obj["pid"]) == nil)
    }
}
