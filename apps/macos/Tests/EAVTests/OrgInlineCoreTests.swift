// Tests for OrgInlineCore.parse — asserts on the structured [InlineRun]
// sequence, not on Font/Color. Platform wrappers keep their own attribute
// tests; these tests cover the shared parsing contract once.
import Testing
import Foundation
@testable import EAVCore

// MARK: - Helpers

/// Visible text of all runs concatenated. Mirrors the rendered visible text.
private func visibleText(_ runs: [InlineRun]) -> String {
    runs.map { run -> String in
        switch run {
        case .plain(let t):              return t
        case .bold(let t):              return t
        case .italic(let t):            return t
        case .underline(let t):         return t
        case .verbatim(let t):          return t
        case .code(let t):              return t
        case .strikethrough(let t):     return t
        case .link(let text, _):        return text
        case .bareURL(let url, let sfx): return url + sfx
        case .timestamp(let d, _):      return d
        }
    }.joined()
}

// MARK: - Emphasis

@Suite("OrgInlineCore — Emphasis Runs")
struct OrgInlineCoreEmphasisTests {

    @Test("Plain string produces single .plain run")
    func plainString() {
        let runs = OrgInlineCore.parse("hello world")
        #expect(runs == [.plain("hello world")])
    }

    @Test("Empty string produces no runs")
    func emptyString() {
        let runs = OrgInlineCore.parse("")
        #expect(runs.isEmpty)
    }

    @Test("Bold: *text* → .bold")
    func bold() {
        let runs = OrgInlineCore.parse("*bold*")
        #expect(runs == [.bold("bold")])
    }

    @Test("Bold after space: word *bold*")
    func boldAfterSpace() {
        let runs = OrgInlineCore.parse("word *bold*")
        #expect(runs == [.plain("word "), .bold("bold")])
    }

    @Test("Italic: /italic/")
    func italic() {
        let runs = OrgInlineCore.parse("/italic/")
        #expect(runs == [.italic("italic")])
    }

    @Test("Underline: _text_")
    func underline() {
        let runs = OrgInlineCore.parse("_underline_")
        #expect(runs == [.underline("underline")])
    }

    @Test("Verbatim: =text=")
    func verbatim() {
        let runs = OrgInlineCore.parse("=verbatim=")
        #expect(runs == [.verbatim("verbatim")])
    }

    @Test("Code: ~text~")
    func code() {
        let runs = OrgInlineCore.parse("~code~")
        #expect(runs == [.code("code")])
    }

    @Test("Strikethrough: +text+")
    func strikethrough() {
        let runs = OrgInlineCore.parse("+strike+")
        #expect(runs == [.strikethrough("strike")])
    }

    @Test("Pathological *foo*bar* — no match, stays plain")
    func pathologicalBold() {
        let runs = OrgInlineCore.parse("*foo*bar*")
        #expect(runs == [.plain("*foo*bar*")])
    }

    @Test("Bold not triggered inside word: ab*cd*ef")
    func notInsideWord() {
        let runs = OrgInlineCore.parse("ab*cd*ef")
        #expect(runs == [.plain("ab*cd*ef")])
    }

    @Test("Bold not triggered after hyphen: -*bold*")
    func notAfterHyphen() {
        let runs = OrgInlineCore.parse("-*bold*")
        #expect(runs == [.plain("-*bold*")])
    }

    @Test("Multiple emphasis types in one string")
    func multipleTypes() {
        let runs = OrgInlineCore.parse("*Bold* and /italic/ and =code=")
        #expect(runs.contains(.bold("Bold")))
        #expect(runs.contains(.italic("italic")))
        #expect(runs.contains(.verbatim("code")))
        #expect(visibleText(runs) == "Bold and italic and code")
    }

    @Test("Bold then period: *bold*. — period is plain")
    func boldThenPeriod() {
        let runs = OrgInlineCore.parse("*bold*.")
        #expect(runs == [.bold("bold"), .plain(".")])
        #expect(visibleText(runs) == "bold.")
    }

    @Test("Italic after opening paren: (/italic/)")
    func italicAfterParen() {
        let runs = OrgInlineCore.parse("(/italic/)")
        #expect(runs == [.plain("("), .italic("italic"), .plain(")")])
        #expect(visibleText(runs) == "(italic)")
    }

    @Test("Markup inside verbatim is not parsed: =*not bold*=")
    func markupInsideVerbatim() {
        let runs = OrgInlineCore.parse("=*not bold*=")
        #expect(runs == [.verbatim("*not bold*")])
    }

    @Test("Markup inside code is not parsed: ~_not underlined_~")
    func markupInsideCode() {
        let runs = OrgInlineCore.parse("~_not underlined_~")
        #expect(runs == [.code("_not underlined_")])
    }
}

// MARK: - Links

@Suite("OrgInlineCore — Link Runs")
struct OrgInlineCoreLinksTests {

    @Test("Labeled link: [[url][label]]")
    func labeledLink() {
        let runs = OrgInlineCore.parse("[[https://example.com][Label]]")
        #expect(runs == [.link(text: "Label", url: "https://example.com")])
        #expect(visibleText(runs) == "Label")
    }

    @Test("Bare org link: [[url]]")
    func bareOrgLink() {
        let runs = OrgInlineCore.parse("[[https://example.com]]")
        #expect(runs == [.link(text: "https://example.com", url: "https://example.com")])
        #expect(visibleText(runs) == "https://example.com")
    }

    @Test("Labeled link with surrounding text")
    func labeledLinkSurrounded() {
        let runs = OrgInlineCore.parse("Visit [[https://example.com][Example]] now")
        #expect(runs.contains(.link(text: "Example", url: "https://example.com")))
        #expect(visibleText(runs) == "Visit Example now")
    }

    @Test("Multiple labeled links")
    func multipleLinks() {
        let runs = OrgInlineCore.parse("[[https://a.com][A]] and [[https://b.com][B]]")
        #expect(runs.contains(.link(text: "A", url: "https://a.com")))
        #expect(runs.contains(.link(text: "B", url: "https://b.com")))
        #expect(visibleText(runs) == "A and B")
    }
}

// MARK: - Bare URLs (G19)

@Suite("OrgInlineCore — Bare URL Runs (G19)")
struct OrgInlineCoreBareURLTests {

    private func firstBareURL(_ runs: [InlineRun]) -> (url: String, suffix: String)? {
        for run in runs {
            if case .bareURL(let u, let s) = run { return (u, s) }
        }
        return nil
    }

    @Test("Plain bare URL")
    func plainBareURL() {
        let runs = OrgInlineCore.parse("Visit https://example.com for info")
        let bu = firstBareURL(runs)
        #expect(bu?.url == "https://example.com")
        #expect(bu?.suffix == "")
        #expect(visibleText(runs) == "Visit https://example.com for info")
    }

    @Test("HTTP URL")
    func httpURL() {
        let runs = OrgInlineCore.parse("http://localhost:3001/api/tasks")
        let bu = firstBareURL(runs)
        #expect(bu?.url == "http://localhost:3001/api/tasks")
    }

    @Test("Trailing period stripped (G19)")
    func trailingPeriod() {
        let runs = OrgInlineCore.parse("see https://example.com.")
        let bu = firstBareURL(runs)
        #expect(bu?.url == "https://example.com")
        #expect(bu?.suffix == ".")
        #expect(visibleText(runs) == "see https://example.com.")
    }

    @Test("URL inside parens: paren excluded by regex, suffix is empty (G19)")
    func trailingParen() {
        // The bare-URL regex character class [^\s<>\])]+ already excludes ')'.
        // The paren is never captured into the URL, so suffix is "". The link
        // URL is still correct; the paren remains in the surrounding plain text.
        let runs = OrgInlineCore.parse("(see https://example.com)")
        let bu = firstBareURL(runs)
        #expect(bu?.url == "https://example.com")
        #expect(bu?.suffix == "")
        #expect(visibleText(runs) == "(see https://example.com)")
    }

    @Test("Query string preserved, only trailing period stripped (G19)")
    func queryPreserved() {
        let runs = OrgInlineCore.parse("https://example.com/path?x=1&y=2.")
        let bu = firstBareURL(runs)
        #expect(bu?.url == "https://example.com/path?x=1&y=2")
        #expect(bu?.suffix == ".")
    }

    @Test("Trailing semicolon stripped (G19)")
    func trailingSemicolon() {
        let runs = OrgInlineCore.parse("https://example.com;")
        let bu = firstBareURL(runs)
        #expect(bu?.url == "https://example.com")
        #expect(bu?.suffix == ";")
    }

    @Test("No trailing punctuation — URL unchanged (G19)")
    func noTrailingPunct() {
        let runs = OrgInlineCore.parse("https://example.com")
        let bu = firstBareURL(runs)
        #expect(bu?.url == "https://example.com")
        #expect(bu?.suffix == "")
    }

    @Test("Trailing slash preserved — not in trim set (G19)")
    func trailingSlash() {
        let runs = OrgInlineCore.parse("https://example.com/path/")
        let bu = firstBareURL(runs)
        #expect(bu?.url == "https://example.com/path/")
        #expect(bu?.suffix == "")
    }
}

// MARK: - Timestamps

@Suite("OrgInlineCore — Timestamp Runs")
struct OrgInlineCoreTimestampTests {

    private func firstTS(_ runs: [InlineRun]) -> (display: String, isInactive: Bool)? {
        for run in runs {
            if case .timestamp(let d, let inactive) = run { return (d, inactive) }
        }
        return nil
    }

    @Test("Active timestamp brackets stripped, display non-empty")
    func activeTimestamp() {
        let runs = OrgInlineCore.parse("<2026-04-18 Sat>")
        let ts = firstTS(runs)
        #expect(ts != nil)
        #expect(ts?.isInactive == false)
        let v = visibleText(runs)
        #expect(!v.contains("<"))
        #expect(!v.contains(">"))
        #expect(!v.isEmpty)
    }

    @Test("Inactive timestamp: isInactive = true")
    func inactiveTimestamp() {
        let runs = OrgInlineCore.parse("[2026-04-18 Sat]")
        let ts = firstTS(runs)
        #expect(ts?.isInactive == true)
    }

    @Test("Timestamp with time preserves time fragment")
    func timestampWithTime() {
        let runs = OrgInlineCore.parse("<2026-04-18 Sat 14:30>")
        let ts = firstTS(runs)
        #expect(ts?.display.contains("14:30") == true)
    }

    @Test("Timestamp with time range preserves time range")
    func timestampWithTimeRange() {
        let runs = OrgInlineCore.parse("<2026-04-18 Sat 14:30-16:00>")
        let ts = firstTS(runs)
        #expect(ts?.display.contains("14:30-16:00") == true)
    }

    @Test("Timestamp with repeater: no angle brackets in output")
    func timestampWithRepeater() {
        let runs = OrgInlineCore.parse("<2026-04-18 Sat +1w>")
        let ts = firstTS(runs)
        #expect(ts != nil)
        #expect(!visibleText(runs).contains("<"))
    }

    @Test("Active timestamp surrounded by text")
    func timestampSurrounded() {
        let runs = OrgInlineCore.parse("Due: <2026-04-18 Sat>")
        #expect(runs.first == .plain("Due: "))
        let ts = firstTS(runs)
        #expect(ts?.isInactive == false)
    }
}

// MARK: - formatTimestamp (unit-tested independently)

@Suite("OrgInlineCore — formatTimestamp")
struct OrgInlineCoreFormatTimestampTests {

    @Test("Invalid date string returns input unchanged")
    func invalidDate() {
        #expect(OrgInlineCore.formatTimestamp("not-a-date") == "not-a-date")
    }

    @Test("Date with day-name abbreviation: only date part parsed")
    func dateWithDayName() {
        // "2026-04-18 Sat" — the day abbreviation is not the date; parser
        // uses only the YYYY-MM-DD prefix and the time fragment.
        let result = OrgInlineCore.formatTimestamp("2026-04-18 Sat")
        #expect(!result.isEmpty)
        #expect(!result.contains("2026"))  // rendered, not raw
    }

    @Test("Time fragment appended when present")
    func timeFragment() {
        let result = OrgInlineCore.formatTimestamp("2026-04-18 Sat 13:00")
        #expect(result.contains("13:00"))
    }

    @Test("Time range appended when present")
    func timeRange() {
        let result = OrgInlineCore.formatTimestamp("2026-04-18 14:30-16:00")
        #expect(result.contains("14:30-16:00"))
    }
}
