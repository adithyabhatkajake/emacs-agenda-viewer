import Testing
import Foundation
@testable import EAVCore

// MARK: - Helpers

private func text(_ attr: AttributedString) -> String {
    String(attr.characters)
}

private func blockTypes(_ blocks: [NoteBlock]) -> [String] {
    blocks.map {
        switch $0 {
        case .checklist: return "checklist"
        case .bullet: return "bullet"
        case .paragraph: return "paragraph"
        case .blank: return "blank"
        }
    }
}

private func checklistState(_ block: NoteBlock) -> ChecklistState? {
    if case .checklist(_, let state, _, _) = block { return state }
    return nil
}

private func indent(_ block: NoteBlock) -> Int {
    switch block {
    case .checklist(_, _, let indent, _): return indent
    case .bullet(_, let indent, _): return indent
    default: return 0
    }
}

private func lineIndex(_ block: NoteBlock) -> Int? {
    // After v0.4.1 each block's `id` *is* the source-line index, so the
    // public accessor works for every variant. Kept on `checklist` only
    // here because the test suite only calls this on checklist blocks.
    if case .checklist = block { return block.id }
    return nil
}

private func inlineText(_ block: NoteBlock) -> String? {
    switch block {
    case .checklist(_, _, _, let attr): return text(attr)
    case .bullet(_, _, let attr): return text(attr)
    case .paragraph(_, let attr): return text(attr)
    case .blank: return nil
    }
}

// ============================================================================
// MARK: - Block-level parsing (NotesParser)
// ============================================================================

@Suite("NotesParser — Plain Lists (org spec §5.3)")
struct NotesParserListTests {

    // MARK: Unordered bullets

    @Test("Dash bullet: '- item'")
    func dashBullet() {
        let blocks = NotesParser.parse("- Buy milk")
        #expect(blocks.count == 1)
        #expect(blockTypes(blocks) == ["bullet"])
        #expect(inlineText(blocks[0]) == "Buy milk")
    }

    @Test("Plus bullet: '+ item'")
    func plusBullet() {
        let blocks = NotesParser.parse("+ Buy milk")
        #expect(blockTypes(blocks) == ["bullet"])
    }

    @Test("Star bullet: '* item'")
    func starBullet() {
        let blocks = NotesParser.parse("  * nested item")
        #expect(blockTypes(blocks) == ["bullet"])
        #expect(indent(blocks[0]) == 1)
    }

    // MARK: Ordered bullets

    @Test("Numeric dot: '1. item'")
    func numericDot() {
        let blocks = NotesParser.parse("1. First item")
        #expect(blockTypes(blocks) == ["bullet"])
        #expect(inlineText(blocks[0]) == "First item")
    }

    @Test("Numeric paren: '1) item'")
    func numericParen() {
        let blocks = NotesParser.parse("1) First item")
        #expect(blockTypes(blocks) == ["bullet"])
    }

    @Test("Alpha dot: 'a. item'")
    func alphaDot() {
        let blocks = NotesParser.parse("a. Alpha item")
        #expect(blockTypes(blocks) == ["bullet"])
    }

    @Test("Alpha paren: 'a) item'")
    func alphaParen() {
        let blocks = NotesParser.parse("a) Alpha item")
        #expect(blockTypes(blocks) == ["bullet"])
    }

    @Test("Uppercase alpha: 'A) item'")
    func upperAlpha() {
        let blocks = NotesParser.parse("A) Alpha item")
        #expect(blockTypes(blocks) == ["bullet"])
    }

    @Test("Multi-digit number: '10. item'")
    func multiDigit() {
        let blocks = NotesParser.parse("10. Tenth item")
        #expect(blockTypes(blocks) == ["bullet"])
    }

    // MARK: Checklists

    @Test("Unchecked checkbox: '- [ ] item'")
    func unchecked() {
        let blocks = NotesParser.parse("- [ ] Pending")
        #expect(blockTypes(blocks) == ["checklist"])
        #expect(checklistState(blocks[0]) == .notStarted)
        #expect(inlineText(blocks[0]) == "Pending")
    }

    @Test("Checked checkbox: '- [X] item'")
    func checked() {
        let blocks = NotesParser.parse("- [X] Done")
        #expect(checklistState(blocks[0]) == .done)
    }

    @Test("Lowercase checked: '- [x] item'")
    func lowercaseChecked() {
        let blocks = NotesParser.parse("- [x] Done")
        #expect(checklistState(blocks[0]) == .done)
    }

    @Test("In-progress checkbox: '- [-] item'")
    func inProgress() {
        let blocks = NotesParser.parse("- [-] In progress")
        #expect(checklistState(blocks[0]) == .ongoing)
    }

    @Test("Checkbox with plus bullet: '+ [ ] item'")
    func plusCheckbox() {
        let blocks = NotesParser.parse("+ [ ] Pending")
        #expect(blockTypes(blocks) == ["checklist"])
    }

    @Test("Checkbox with star bullet: '* [ ] item'")
    func starCheckbox() {
        let blocks = NotesParser.parse("  * [ ] Pending")
        #expect(blockTypes(blocks) == ["checklist"])
    }

    @Test("Checkbox with ordered numeric: '1. [ ] item'")
    func orderedCheckbox() {
        let blocks = NotesParser.parse("1. [ ] First")
        #expect(blockTypes(blocks) == ["checklist"])
    }

    @Test("Checkbox with ordered paren: '1) [ ] item'")
    func orderedParenCheckbox() {
        let blocks = NotesParser.parse("1) [ ] First")
        #expect(blockTypes(blocks) == ["checklist"])
    }

    @Test("Checkbox with alpha bullet: 'a) [ ] item'")
    func alphaCheckbox() {
        let blocks = NotesParser.parse("a) [ ] First")
        #expect(blockTypes(blocks) == ["checklist"])
    }

    // MARK: Indentation

    @Test("Indentation: 2 spaces = indent 1")
    func indent2() {
        let blocks = NotesParser.parse("  - Nested")
        #expect(indent(blocks[0]) == 1)
    }

    @Test("Indentation: 4 spaces = indent 2")
    func indent4() {
        let blocks = NotesParser.parse("    - Deep nested")
        #expect(indent(blocks[0]) == 2)
    }

    @Test("Indentation: 6 spaces = indent 3")
    func indent6() {
        let blocks = NotesParser.parse("      - Very deep")
        #expect(indent(blocks[0]) == 3)
    }

    @Test("Nested list preserves structure")
    func nestedList() {
        let input = """
        - Parent
          - Child 1
          - Child 2
            - Grandchild
        """
        let blocks = NotesParser.parse(input)
        let bullets = blocks.filter { if case .bullet = $0 { return true }; return false }
        #expect(bullets.count == 4)
        #expect(indent(bullets[0]) == 0)
        #expect(indent(bullets[1]) == 1)
        #expect(indent(bullets[2]) == 1)
        #expect(indent(bullets[3]) == 2)
    }

    // MARK: Paragraphs and blanks

    @Test("Plain text becomes paragraph")
    func paragraph() {
        let blocks = NotesParser.parse("Hello, world!")
        #expect(blockTypes(blocks) == ["paragraph"])
    }

    @Test("Empty line becomes blank")
    func blankLine() {
        let blocks = NotesParser.parse("Line one\n\nLine two")
        #expect(blockTypes(blocks) == ["paragraph", "blank", "paragraph"])
    }

    @Test("Whitespace-only line becomes blank")
    func whitespaceOnly() {
        let blocks = NotesParser.parse("Line one\n   \nLine two")
        #expect(blockTypes(blocks) == ["paragraph", "blank", "paragraph"])
    }

    // MARK: Mixed content

    @Test("Mixed bullets, checklists, paragraphs, blanks")
    func mixedContent() {
        let input = """
        Some intro text

        - [ ] Task one
        - [X] Task two
        - Plain bullet

        Conclusion
        """
        let blocks = NotesParser.parse(input)
        #expect(blockTypes(blocks) == [
            "paragraph", "blank",
            "checklist", "checklist", "bullet",
            "blank", "paragraph",
        ])
    }
}

// ============================================================================

@Suite("NotesParser — Drawer & Planning Filtering")
struct NotesParserFilterTests {

    @Test("PROPERTIES drawer is hidden")
    func propertiesDrawer() {
        let input = """
        :PROPERTIES:
        :STYLE: habit
        :END:
        Visible text
        """
        let blocks = NotesParser.parse(input)
        let types = blockTypes(blocks)
        #expect(!types.contains("paragraph") || blocks.allSatisfy {
            if case .paragraph(_, let attr) = $0 {
                return !text(attr).contains("PROPERTIES") && !text(attr).contains("STYLE")
            }
            return true
        })
        #expect(blocks.contains { inlineText($0)?.contains("Visible") == true })
    }

    @Test("LOGBOOK drawer is hidden")
    func logbookDrawer() {
        let input = """
        :LOGBOOK:
        CLOCK: [2026-04-18 Sat 09:00]--[2026-04-18 Sat 10:00] =>  1:00
        :END:
        Visible text
        """
        let blocks = NotesParser.parse(input)
        #expect(blocks.contains { inlineText($0)?.contains("Visible") == true })
        #expect(!blocks.contains { inlineText($0)?.contains("LOGBOOK") == true })
    }

    @Test("Drawer filtering is case-insensitive")
    func drawerCaseInsensitive() {
        let input = """
        :properties:
        :CUSTOM_ID: test
        :end:
        Visible
        """
        let blocks = NotesParser.parse(input)
        #expect(blocks.contains { inlineText($0)?.contains("Visible") == true })
        #expect(!blocks.contains { inlineText($0)?.contains("CUSTOM_ID") == true })
    }

    @Test("CLOCK: lines are hidden")
    func clockLines() {
        let input = "CLOCK: [2026-04-18 Sat 09:00]--[2026-04-18 Sat 10:00] =>  1:00\nVisible"
        let blocks = NotesParser.parse(input)
        #expect(!blocks.contains { inlineText($0)?.contains("CLOCK") == true })
        #expect(blocks.contains { inlineText($0)?.contains("Visible") == true })
    }

    @Test("SCHEDULED: line is hidden")
    func scheduledLine() {
        let blocks = NotesParser.parse("SCHEDULED: <2026-04-18 Sat>\nVisible")
        #expect(!blocks.contains { inlineText($0)?.contains("SCHEDULED") == true })
    }

    @Test("DEADLINE: line is hidden")
    func deadlineLine() {
        let blocks = NotesParser.parse("DEADLINE: <2026-04-18 Sat>\nVisible")
        #expect(!blocks.contains { inlineText($0)?.contains("DEADLINE") == true })
    }

    @Test("CLOSED: line is hidden")
    func closedLine() {
        let blocks = NotesParser.parse("CLOSED: [2026-04-18 Sat 09:00]\nVisible")
        #expect(!blocks.contains { inlineText($0)?.contains("CLOSED") == true })
    }

    @Test("Content between two drawers is visible")
    func betweenDrawers() {
        let input = """
        :PROPERTIES:
        :END:
        Visible middle
        :LOGBOOK:
        :END:
        Visible end
        """
        let blocks = NotesParser.parse(input)
        let texts = blocks.compactMap { inlineText($0) }
        #expect(texts.contains("Visible middle"))
        #expect(texts.contains("Visible end"))
    }
}

// ============================================================================

@Suite("NotesParser — Line Index Alignment")
struct NotesParserLineIndexTests {

    @Test("Checklist lineIndex matches original text line number")
    func lineIndexBasic() {
        let input = "- [ ] First\n- [ ] Second\n- [ ] Third"
        let blocks = NotesParser.parse(input)
        let indices = blocks.compactMap { lineIndex($0) }
        #expect(indices == [0, 1, 2])
    }

    @Test("Filtered lines don't shift checklist lineIndex")
    func lineIndexWithFiltering() {
        let input = """
        :PROPERTIES:
        :STYLE: habit
        :END:
        - [ ] Task A
        CLOCK: [2026-04-18 Sat 09:00]
        - [ ] Task B
        """
        let blocks = NotesParser.parse(input)
        let indices = blocks.compactMap { lineIndex($0) }
        #expect(indices == [3, 5])
    }

    @Test("Blank lines don't affect checklist lineIndex")
    func lineIndexWithBlanks() {
        let input = "Some text\n\n- [ ] After blank"
        let blocks = NotesParser.parse(input)
        let indices = blocks.compactMap { lineIndex($0) }
        #expect(indices == [2])
    }

    /// Regression: prior to v0.4.1 each block carried a freshly-generated
    /// UUID so re-parsing the same text returned different ids every time.
    /// `NotesRenderedView`'s collapse set was keyed on those ids, so a
    /// checkbox toggle (which writes to org → reloads notes → re-parses)
    /// silently expanded every previously-collapsed sibling. Pin block ids
    /// to the source-line index so they survive a re-parse.
    @Test("Block IDs are stable across re-parses")
    func blockIdsStable() {
        let input = """
        - [ ] Personal Laptop
          - [X] Clear Safari Tabs
          - [ ] Clear Safari Reading List
        - [ ] Phone
          - [X] Clear Safari Tabs
          - [X] Clear Messages
        """
        let first = NotesParser.parse(input)
        let again = NotesParser.parse(input)
        #expect(first.map(\.id) == again.map(\.id))
        // After a single-line edit the surrounding blocks should keep the
        // same ids — only the modified line's ID still happens to be the
        // same (its line number didn't change), but specifically the
        // *Phone* parent and its children must keep the same identity.
        let edited = input.replacingOccurrences(
            of: "- [ ] Clear Safari Reading List",
            with: "- [-] Clear Safari Reading List"
        )
        let third = NotesParser.parse(edited)
        #expect(first.map(\.id) == third.map(\.id),
                "checkbox toggle should not re-key block IDs")
    }
}

// ============================================================================
// MARK: - Inline Markup (OrgInline / renderInline)
// Ref: Org Manual §11.7 Emphasis and Monospace
// ============================================================================

@Suite("Inline Markup — Emphasis (org spec §11.7)")
struct InlineEmphasisTests {

    @Test("Bold: *text*")
    func bold() {
        let result = renderInline("This is *bold* text")
        #expect(text(result) == "This is bold text")
    }

    @Test("Italic: /text/")
    func italic() {
        let result = renderInline("This is /italic/ text")
        #expect(text(result) == "This is italic text")
    }

    @Test("Underline: _text_")
    func underline() {
        let result = renderInline("This is _underlined_ text")
        #expect(text(result) == "This is underlined text")
    }

    @Test("Verbatim: =text=")
    func verbatim() {
        let result = renderInline("Use =org-mode= here")
        #expect(text(result) == "Use org-mode here")
    }

    @Test("Code: ~text~")
    func code() {
        let result = renderInline("Run ~git status~")
        #expect(text(result) == "Run git status")
    }

    @Test("Multi-word bold: *multiple words*")
    func multiWordBold() {
        let result = renderInline("This is *bold and long* text")
        #expect(text(result) == "This is bold and long text")
    }

    @Test("Multiple markup types in one line")
    func multipleTypes() {
        let result = renderInline("*Bold* and /italic/ and =code=")
        #expect(text(result) == "Bold and italic and code")
    }

    // MARK: Boundary rules (org spec pre/post constraints)

    @Test("Markup not triggered inside words: ab*cd*ef")
    func notInsideWordBold() {
        let result = renderInline("ab*cd*ef")
        #expect(text(result) == "ab*cd*ef")
    }

    @Test("Markup not triggered inside words: ab/cd/ef")
    func notInsideWordItalic() {
        let result = renderInline("ab/cd/ef")
        #expect(text(result) == "ab/cd/ef")
    }

    @Test("Markup not triggered inside words: ab_cd_ef")
    func notInsideWordUnderline() {
        let result = renderInline("ab_cd_ef")
        #expect(text(result) == "ab_cd_ef")
    }

    @Test("Markup not triggered inside words: ab=cd=ef")
    func notInsideWordVerbatim() {
        let result = renderInline("ab=cd=ef")
        #expect(text(result) == "ab=cd=ef")
    }

    @Test("Markup at start of line: *bold* rest")
    func markupAtStart() {
        let result = renderInline("*bold* rest")
        #expect(text(result) == "bold rest")
    }

    @Test("Markup at end of line: text *bold*")
    func markupAtEnd() {
        let result = renderInline("text *bold*")
        #expect(text(result) == "text bold")
    }

    @Test("Markup after punctuation: (*bold*)")
    func markupAfterPunctuation() {
        let result = renderInline("(*bold*)")
        #expect(text(result) == "(bold)")
    }

    @Test("Markup preceded by hyphen: -*bold* — hyphen is NOT in the pre-set")
    func markupAfterHyphen() {
        // Per org-emphasis-regexp-components, the pre-set is " \t('\"{"
        // — a hyphen is allowed *after* (post-set) but not before. Org-mode
        // itself does not render `-*bold*` as bold; the literal text wins.
        // The previous Mac regex used `(?<![A-Za-z0-9])` and matched here,
        // but that diverged from spec.
        let result = renderInline("-*bold*")
        #expect(text(result) == "-*bold*")
    }

    @Test("Unmatched single marker is literal: *unclosed")
    func unmatchedBold() {
        let result = renderInline("*unclosed text")
        #expect(text(result) == "*unclosed text")
    }

    @Test("Empty emphasis is not matched: ** nothing")
    func emptyEmphasis() {
        let result = renderInline("** nothing")
        #expect(text(result) == "** nothing")
    }
}

// ============================================================================

@Suite("Inline Markup — Links (org spec §4.2)")
struct InlineLinkTests {

    @Test("Labeled link: [[url][label]]")
    func labeledLink() {
        let result = renderInline("Visit [[https://example.com][Example]]")
        #expect(text(result) == "Visit Example")
    }

    @Test("Bare link: [[url]]")
    func bareLink() {
        let result = renderInline("See [[https://example.com]]")
        #expect(text(result) == "See https://example.com")
    }

    @Test("Bare URL without brackets")
    func bareURL() {
        let result = renderInline("Visit https://example.com for info")
        #expect(text(result) == "Visit https://example.com for info")
    }

    @Test("HTTP URL (not HTTPS)")
    func httpURL() {
        let result = renderInline("At http://localhost:3001/api/tasks")
        #expect(text(result) == "At http://localhost:3001/api/tasks")
    }

    @Test("Multiple links in one line")
    func multipleLinks() {
        let result = renderInline("[[https://a.com][A]] and [[https://b.com][B]]")
        #expect(text(result) == "A and B")
    }

    @Test("Link with special chars in URL")
    func linkSpecialChars() {
        let result = renderInline("[[https://example.com/path?q=1&r=2][Search]]")
        #expect(text(result) == "Search")
    }

    @Test("Bare URL stops at closing paren/bracket")
    func urlStopsAtBracket() {
        let result = renderInline("(see https://example.com)")
        let t = text(result)
        #expect(t == "(see https://example.com)")
    }
}

// ============================================================================

@Suite("Inline Markup — Timestamps (org spec §8.1)")
struct InlineTimestampTests {

    @Test("Active timestamp: <2026-04-18 Sat>")
    func activeTimestamp() {
        let result = renderInline("Due: <2026-04-18 Sat>")
        let t = text(result)
        #expect(!t.contains("<"))
        #expect(!t.contains(">"))
    }

    @Test("Active timestamp with time: <2026-04-18 Sat 14:30>")
    func activeWithTime() {
        let result = renderInline("At <2026-04-18 Sat 14:30>")
        let t = text(result)
        #expect(t.contains("14:30"))
    }

    @Test("Active timestamp with time range: <2026-04-18 Sat 14:30-16:00>")
    func activeWithTimeRange() {
        let result = renderInline("Meeting <2026-04-18 Sat 14:30-16:00>")
        let t = text(result)
        #expect(t.contains("14:30-16:00"))
    }

    @Test("Inactive timestamp: [2026-04-18 Sat]")
    func inactiveTimestamp() {
        let result = renderInline("Created [2026-04-18 Sat]")
        let t = text(result)
        #expect(!t.contains("["))
        #expect(!t.contains("]"))
    }

    @Test("Timestamp with repeater: <2026-04-18 Sat +1w>")
    func timestampWithRepeater() {
        let result = renderInline("Repeat <2026-04-18 Sat +1w>")
        let t = text(result)
        #expect(!t.contains("<"))
    }

    @Test("Timestamp brackets are stripped, date is rendered")
    func bracketsStripped() {
        let result = renderInline("<2026-04-18 Sat>")
        let t = text(result)
        #expect(!t.contains("<"))
        #expect(!t.contains(">"))
        #expect(!t.isEmpty)
    }
}

// ============================================================================

@Suite("Inline Markup — Code/Verbatim Precedence")
struct InlineCodeTests {

    @Test("Markup inside verbatim is literal: =*not bold*=")
    func markupInsideVerbatim() {
        let result = renderInline("=*not bold*=")
        #expect(text(result) == "*not bold*")
    }

    @Test("Markup inside code is literal: ~_not underlined_~")
    func markupInsideCode() {
        let result = renderInline("~_not underlined_~")
        #expect(text(result) == "_not underlined_")
    }

    @Test("Verbatim with spaces: =multi word code=")
    func verbatimMultiWord() {
        let result = renderInline("Run =git commit -m 'fix'= now")
        #expect(text(result) == "Run git commit -m 'fix' now")
    }
}

// ============================================================================
// MARK: - Checkbox Toggle (NotesMutation)
// ============================================================================

@Suite("NotesMutation — Checkbox Toggle")
struct NotesMutationTests {

    @Test("Cycle: [ ] → [-]")
    func uncheckedToOngoing() {
        let result = NotesMutation.toggleChecklist(in: "- [ ] Task", lineIndex: 0)
        #expect(result == "- [-] Task")
    }

    @Test("Cycle: [-] → [X]")
    func ongoingToDone() {
        let result = NotesMutation.toggleChecklist(in: "- [-] Task", lineIndex: 0)
        #expect(result == "- [X] Task")
    }

    @Test("Cycle: [X] → [ ]")
    func doneToUnchecked() {
        let result = NotesMutation.toggleChecklist(in: "- [X] Task", lineIndex: 0)
        #expect(result == "- [ ] Task")
    }

    @Test("Cycle: [x] → [ ] (lowercase)")
    func lowercaseDoneToUnchecked() {
        let result = NotesMutation.toggleChecklist(in: "- [x] Task", lineIndex: 0)
        #expect(result == "- [ ] Task")
    }

    @Test("No checkbox returns nil")
    func noCheckbox() {
        let result = NotesMutation.toggleChecklist(in: "- Plain bullet", lineIndex: 0)
        #expect(result == nil)
    }

    @Test("Correct line targeted in multi-line text")
    func multiLineTarget() {
        let input = "- [ ] First\n- [ ] Second\n- [ ] Third"
        let result = NotesMutation.toggleChecklist(in: input, lineIndex: 1)
        #expect(result == "- [ ] First\n- [-] Second\n- [ ] Third")
    }

    @Test("Out of bounds returns nil")
    func outOfBounds() {
        #expect(NotesMutation.toggleChecklist(in: "- [ ] A", lineIndex: 5) == nil)
        #expect(NotesMutation.toggleChecklist(in: "- [ ] A", lineIndex: -1) == nil)
    }

    @Test("Preserves indentation")
    func preservesIndentation() {
        let result = NotesMutation.toggleChecklist(in: "    - [ ] Deep", lineIndex: 0)
        #expect(result == "    - [-] Deep")
    }

    @Test("Preserves surrounding lines")
    func preservesSurrounding() {
        let input = "Header\n- [ ] Toggle me\nFooter"
        let result = NotesMutation.toggleChecklist(in: input, lineIndex: 1)
        #expect(result == "Header\n- [-] Toggle me\nFooter")
    }

    @Test("Ordered list checkbox toggle")
    func orderedToggle() {
        let result = NotesMutation.toggleChecklist(in: "1. [ ] Ordered", lineIndex: 0)
        #expect(result == "1. [-] Ordered")
    }

    @Test("Full cycle: [ ] → [-] → [X] → [ ]")
    func fullCycle() {
        let start = "- [ ] Task"
        let step1 = NotesMutation.toggleChecklist(in: start, lineIndex: 0)!
        #expect(step1 == "- [-] Task")
        let step2 = NotesMutation.toggleChecklist(in: step1, lineIndex: 0)!
        #expect(step2 == "- [X] Task")
        let step3 = NotesMutation.toggleChecklist(in: step2, lineIndex: 0)!
        #expect(step3 == "- [ ] Task")
    }

    @Test("Toggle with drawer-filtered content preserves correct line")
    func toggleWithDrawer() {
        let input = ":PROPERTIES:\n:END:\n- [ ] Real task"
        let result = NotesMutation.toggleChecklist(in: input, lineIndex: 2)
        #expect(result == ":PROPERTIES:\n:END:\n- [-] Real task")
    }
}

// ============================================================================
// MARK: - Edge cases & regression guards
// ============================================================================

@Suite("NotesParser — Edge Cases")
struct NotesParserEdgeCaseTests {

    @Test("Empty string produces no blocks")
    func emptyString() {
        let blocks = NotesParser.parse("")
        #expect(blocks.count == 1)  // single blank
    }

    @Test("Only whitespace produces blanks")
    func onlyWhitespace() {
        let blocks = NotesParser.parse("   \n   ")
        #expect(blocks.allSatisfy { if case .blank = $0 { return true }; return false })
    }

    @Test("Bullet without space after marker is paragraph, not bullet")
    func bulletNoSpace() {
        let blocks = NotesParser.parse("-no space")
        #expect(blockTypes(blocks) == ["paragraph"])
    }

    @Test("Nested drawer inside PROPERTIES is handled")
    func nestedDrawerMarker() {
        let input = """
        :PROPERTIES:
        :NESTED: value
        :END:
        Visible
        """
        let blocks = NotesParser.parse(input)
        #expect(blocks.contains { inlineText($0) == "Visible" })
    }

    @Test("Drawer without :END: hides rest of content")
    func unclosedDrawer() {
        let input = ":LOGBOOK:\nCLOCK: stuff\nShould be hidden"
        let blocks = NotesParser.parse(input)
        let texts = blocks.compactMap { inlineText($0) }
        #expect(!texts.contains("Should be hidden"))
    }

    @Test("CLOCK: with leading whitespace is filtered")
    func clockWithWhitespace() {
        let blocks = NotesParser.parse("  CLOCK: [2026-04-18]--[2026-04-18]\nVisible")
        #expect(blocks.contains { inlineText($0) == "Visible" })
        #expect(!blocks.contains { inlineText($0)?.contains("CLOCK") == true })
    }

    @Test("Line with only a dash is paragraph, not bullet")
    func dashAlone() {
        let blocks = NotesParser.parse("-")
        #expect(blockTypes(blocks) == ["paragraph"])
    }

    @Test("Line '- ' (dash + space, no text) is bullet with empty text")
    func dashSpaceOnly() {
        let blocks = NotesParser.parse("- ")
        #expect(blockTypes(blocks) == ["bullet"])
    }
}
