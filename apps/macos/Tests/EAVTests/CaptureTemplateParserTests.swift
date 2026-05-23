import Testing
import Foundation
@testable import EAVCore

@Suite("CaptureTemplateExpander")
struct CaptureTemplateParserTests {

    // A fixed timestamp stub so tests are deterministic.
    private func stubTimestamp(active: Bool, includeTime: Bool) -> String {
        active ? "<2000-01-01 Sat>" : "[2000-01-01 Sat]"
    }

    // MARK: - Case 1: only %^{ask}

    @Test("Single named prompt substituted with answer")
    func singleNamedPrompt() {
        let result = expandCaptureDirectives(
            in: "Hello %^{ask}",
            promptAnswers: ["Bob"],
            orgTimestampActive: stubTimestamp
        )
        #expect(result == "Hello Bob")
    }

    // MARK: - Case 2: %^p then %^{ask}

    @Test("%^p passthrough does not consume prompt slot")
    func passthroughBeforePrompt() {
        let result = expandCaptureDirectives(
            in: "%^p %^{ask}",
            promptAnswers: ["Bob"],
            orgTimestampActive: stubTimestamp
        )
        // %^p → empty; %^{ask} → "Bob" (index 0)
        #expect(result == " Bob")
    }

    // MARK: - Case 3: %^p %^p %^{ask}

    @Test("Two %^p passthroughs do not consume prompt slots")
    func twoPassthroughsBeforePrompt() {
        let result = expandCaptureDirectives(
            in: "%^p %^p %^{ask}",
            promptAnswers: ["Bob"],
            orgTimestampActive: stubTimestamp
        )
        // both %^p → empty; %^{ask} → "Bob" (index 0)
        #expect(result == "  Bob")
    }

    // MARK: - Case 4: %^{a} %^p %^{b}

    @Test("Named prompts each consume their own slot, passthrough in between skipped")
    func namedPromptPassthroughNamedPrompt() {
        let result = expandCaptureDirectives(
            in: "%^{a} %^p %^{b}",
            promptAnswers: ["A1", "B1"],
            orgTimestampActive: stubTimestamp
        )
        // %^{a} → "A1" (idx 0); %^p → ""; %^{b} → "B1" (idx 1)
        #expect(result == "A1  B1")
    }

    // MARK: - Case 5: only %^p, no named prompts

    @Test("Only passthrough directives, zero prompts consumed")
    func onlyPassthrough() {
        let result = expandCaptureDirectives(
            in: "%^p %^p",
            promptAnswers: [],
            orgTimestampActive: stubTimestamp
        )
        #expect(result == " ")
    }
}
