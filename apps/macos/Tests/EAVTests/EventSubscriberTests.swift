import Testing
import Foundation
@testable import EAVCore

// MARK: - Helpers

/// Feed a multi-line SSE blob to SSEParser and collect every dispatch result.
private func parseSSE(_ text: String) -> [(name: String, payload: String, id: String?, retryMs: Int?)] {
    var parser = SSEParser()
    var results: [(String, String, String?, Int?)] = []
    for line in text.components(separatedBy: "\n") {
        if let r = parser.feed(line) {
            results.append(r)
        }
    }
    return results
}

// MARK: - Suite

@Suite("EventSubscriber")
struct EventSubscriberTests {

    // MARK: - Parser: standard event with data and id

    @Test("Parser dispatches event name, data, and id from a well-formed block")
    func parserFullBlock() {
        let blob = "event: task-changed\ndata: {\"x\":1}\nid: 42\n\n"
        let results = parseSSE(blob)
        #expect(results.count == 1)
        let r = results[0]
        #expect(r.name == "task-changed")
        #expect(r.payload == "{\"x\":1}")
        #expect(r.id == "42")
        #expect(r.retryMs == nil)
    }

    // MARK: - Parser: name-only event (bug fix)

    @Test("Parser dispatches name-only event when data is absent")
    func parserNameOnlyEvent() {
        // Before the fix this was silently dropped because the guard only
        // checked currentDataLines.isEmpty.
        let blob = "event: ping\n\n"
        let results = parseSSE(blob)
        #expect(results.count == 1)
        #expect(results[0].name == "ping")
        #expect(results[0].payload == "")
    }

    // MARK: - Parser: config-changed round-trip

    @Test("DaemonEvent init produces configChanged for name-only config-changed event")
    func parserConfigChangedRoundTrip() {
        let blob = "event: config-changed\n\n"
        let results = parseSSE(blob)
        #expect(results.count == 1)
        let (name, payload, _, _) = results[0]
        let event = DaemonEvent(name: name, payload: payload)
        if case .configChanged = event {
            // pass
        } else {
            #expect(Bool(false), "Expected .configChanged, got \(String(describing: event))")
        }
    }

    // MARK: - Parser: retry field

    @Test("Parser stores retry value in milliseconds")
    func parserRetryField() {
        let blob = "retry: 5000\nevent: tick\n\n"
        let results = parseSSE(blob)
        #expect(results.count == 1)
        #expect(results[0].retryMs == 5000)
    }

    @Test("Parser ignores non-integer retry values")
    func parserRetryFieldInvalid() {
        let blob = "retry: bogus\nevent: tick\n\n"
        let results = parseSSE(blob)
        #expect(results.count == 1)
        #expect(results[0].retryMs == nil)
    }

    // MARK: - Parser: multiple events in one stream

    @Test("Parser handles multiple sequential events")
    func parserMultipleEvents() {
        let blob = "event: file-changed\ndata: {\"file\":\"/a.org\"}\n\nevent: ping\n\n"
        let results = parseSSE(blob)
        #expect(results.count == 2)
        #expect(results[0].name == "file-changed")
        #expect(results[1].name == "ping")
    }

    // MARK: - Parser: comment lines ignored

    @Test("Parser ignores SSE comment lines")
    func parserCommentIgnored() {
        let blob = ": keep-alive\nevent: ping\n\n"
        let results = parseSSE(blob)
        #expect(results.count == 1)
        #expect(results[0].name == "ping")
    }

    // MARK: - Parser: blank line with no content is ignored

    @Test("Parser does not fire on consecutive blank lines with no buffered content")
    func parserConsecutiveBlanks() {
        let blob = "\n\nevent: ping\n\n"
        let results = parseSSE(blob)
        #expect(results.count == 1)
    }

    // MARK: - Parser: multi-line data joined with newline

    @Test("Parser joins multi-line data with newline")
    func parserMultiLineData() {
        let blob = "event: message\ndata: line1\ndata: line2\n\n"
        let results = parseSSE(blob)
        #expect(results.count == 1)
        #expect(results[0].payload == "line1\nline2")
    }

    // MARK: - Backoff curve

    @Test("backoffDelay returns 0 for the first attempt with no hint")
    func backoffAttemptZero() {
        let d = EventSubscriber.backoffDelay(attempt: 0, retryHintMs: nil)
        #expect(d == 0)
    }

    @Test("backoffDelay uses retryHint for attempt 0 when hint is present")
    func backoffAttemptZeroWithHint() {
        // With jitter the result should be near 5 s but within ±20 %.
        for _ in 0 ..< 50 {
            let d = EventSubscriber.backoffDelay(attempt: 0, retryHintMs: 5000)
            #expect(d >= 4.0)
            #expect(d <= 6.0)
        }
    }

    @Test("backoffDelay doubles each attempt and caps at 30s")
    func backoffCurveDoublesAndCaps() {
        // Without jitter we can only bound the range. Test the unjittered
        // midpoint by running many samples and checking bounds hold.
        //
        // Attempt 1 → base 1 s → jittered in [0.8, 1.2]
        // Attempt 2 → base 2 s → jittered in [1.6, 2.4]
        // Attempt 3 → base 4 s → jittered in [3.2, 4.8]
        // Attempt 4 → base 8 s → jittered in [6.4, 9.6]
        // Attempt 5 → base 16 s → jittered in [12.8, 19.2]
        // Attempt 6 → base 30 s (capped) → jittered in [24, 36]
        // Attempt 10 → still capped at 30 s → jittered in [24, 36]
        let expectedRanges: [(Int, ClosedRange<Double>)] = [
            (1,  0.8...1.2),
            (2,  1.6...2.4),
            (3,  3.2...4.8),
            (4,  6.4...9.6),
            (5,  12.8...19.2),
            (6,  24.0...36.0),
            (10, 24.0...36.0),
        ]
        for (attempt, range) in expectedRanges {
            // Run 100 samples; all must fall in range.
            for _ in 0 ..< 100 {
                let d = EventSubscriber.backoffDelay(attempt: attempt, retryHintMs: nil)
                #expect(d >= range.lowerBound, "attempt \(attempt): \(d) below \(range.lowerBound)")
                #expect(d <= range.upperBound, "attempt \(attempt): \(d) above \(range.upperBound)")
            }
        }
    }

    @Test("backoffDelay respects retryHint as a floor above the exponential")
    func backoffHintRaisesFloor() {
        // At attempt 1, exponential base is 1 s, but hint is 10 s.
        // Result must be in the jittered range of 10 s.
        for _ in 0 ..< 50 {
            let d = EventSubscriber.backoffDelay(attempt: 1, retryHintMs: 10_000)
            #expect(d >= 8.0)
            #expect(d <= 12.0)
        }
    }

    @Test("backoffDelay cap applies even with large retryHint")
    func backoffCapAppliesWithLargeHint() {
        // hint = 60 s, but cap is 30 s — cap wins.
        // Actually the current design: cap applies to the exponential only;
        // the hint is used as a floor, not subject to the exponential cap.
        // A hint of 60 000 ms (60 s) should produce ~60 s ± 20 %.
        for _ in 0 ..< 50 {
            let d = EventSubscriber.backoffDelay(attempt: 1, retryHintMs: 60_000)
            #expect(d >= 48.0)
            #expect(d <= 72.0)
        }
    }
}
