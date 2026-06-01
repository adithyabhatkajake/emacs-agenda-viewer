import Testing
import Foundation
@testable import EAVCore

@Suite("OrgChecklist")
struct ChecklistTests {

    // MARK: - parse

    @Test("parse: empty string returns no items")
    func parseEmpty() {
        #expect(OrgChecklist.parse("").isEmpty)
    }

    @Test("parse: non-checklist text returns no items")
    func parseNonChecklist() {
        let notes = "Some random note\nAnother line\n  indented line"
        #expect(OrgChecklist.parse(notes).isEmpty)
    }

    @Test("parse: unchecked item")
    func parseUnchecked() {
        let items = OrgChecklist.parse("- [ ] Brush teeth")
        #expect(items.count == 1)
        #expect(items[0].lineIndex == 0)
        #expect(items[0].checked == false)
        #expect(items[0].label == "Brush teeth")
    }

    @Test("parse: checked item uppercase X")
    func parseCheckedUpperX() {
        let items = OrgChecklist.parse("- [X] Make coffee")
        #expect(items.count == 1)
        #expect(items[0].checked == true)
        #expect(items[0].label == "Make coffee")
    }

    @Test("parse: checked item lowercase x")
    func parseCheckedLowerX() {
        let items = OrgChecklist.parse("- [x] Do thing")
        #expect(items.count == 1)
        #expect(items[0].checked == true)
    }

    @Test("parse: partial marker (dash) is unchecked")
    func parsePartialMarker() {
        let items = OrgChecklist.parse("- [-] In progress")
        #expect(items.count == 1)
        #expect(items[0].checked == false)
    }

    @Test("parse: indented checklist line matches")
    func parseIndented() {
        let items = OrgChecklist.parse("  - [ ] Indented item")
        #expect(items.count == 1)
        #expect(items[0].checked == false)
        #expect(items[0].label == "Indented item")
    }

    @Test("parse: mixed notes string, correct line indices")
    func parseMixed() {
        let notes = """
        Some preamble text here.
        - [ ] Brush (3 min.)
        Another note line.
        - [X] Make coffee
        """
        let items = OrgChecklist.parse(notes)
        #expect(items.count == 2)
        #expect(items[0].lineIndex == 1)
        #expect(items[0].checked == false)
        #expect(items[0].label == "Brush (3 min.)")
        #expect(items[1].lineIndex == 3)
        #expect(items[1].checked == true)
        #expect(items[1].label == "Make coffee")
    }

    @Test("parse: label with brackets is preserved")
    func parseLabelWithBrackets()  {
        let items = OrgChecklist.parse("- [ ] Read [important] doc")
        #expect(items.count == 1)
        #expect(items[0].label == "Read [important] doc")
    }

    // MARK: - toggle

    @Test("toggle: unchecked becomes checked")
    func toggleUncheckedToChecked() {
        let notes = "- [ ] Brush teeth"
        let result = OrgChecklist.toggle(notes, lineIndex: 0)
        #expect(result == "- [X] Brush teeth")
    }

    @Test("toggle: checked becomes unchecked")
    func toggleCheckedToUnchecked() {
        let notes = "- [X] Make coffee"
        let result = OrgChecklist.toggle(notes, lineIndex: 0)
        #expect(result == "- [ ] Make coffee")
    }

    @Test("toggle: lowercase x becomes unchecked")
    func toggleLowercaseX() {
        let notes = "- [x] Do thing"
        let result = OrgChecklist.toggle(notes, lineIndex: 0)
        #expect(result == "- [ ] Do thing")
    }

    @Test("toggle: dash marker becomes checked")
    func toggleDashToChecked() {
        let notes = "- [-] In progress"
        let result = OrgChecklist.toggle(notes, lineIndex: 0)
        #expect(result == "- [X] In progress")
    }

    @Test("toggle: flips only the targeted line, preserves others")
    func toggleTargetedLineOnly() {
        let notes = """
        Some preamble text here.
        - [ ] Brush (3 min.)
        Another note line.
        - [X] Make coffee
        """
        // Toggle line 1 (first checklist item — unchecked -> checked)
        let result1 = OrgChecklist.toggle(notes, lineIndex: 1)
        let lines1 = result1!.components(separatedBy: "\n")
        #expect(lines1[0] == "Some preamble text here.")
        #expect(lines1[1] == "- [X] Brush (3 min.)")
        #expect(lines1[2] == "Another note line.")
        #expect(lines1[3] == "- [X] Make coffee")

        // Toggle line 3 (second checklist item — checked -> unchecked)
        let result3 = OrgChecklist.toggle(notes, lineIndex: 3)
        let lines3 = result3!.components(separatedBy: "\n")
        #expect(lines3[0] == "Some preamble text here.")
        #expect(lines3[1] == "- [ ] Brush (3 min.)")
        #expect(lines3[2] == "Another note line.")
        #expect(lines3[3] == "- [ ] Make coffee")
    }

    @Test("toggle: preserves leading indentation")
    func togglePreservesIndentation() {
        let notes = "  - [ ] Indented item"
        let result = OrgChecklist.toggle(notes, lineIndex: 0)
        #expect(result == "  - [X] Indented item")
    }

    @Test("toggle: out-of-bounds lineIndex returns nil")
    func toggleOutOfBounds() {
        let notes = "- [ ] Single line"
        #expect(OrgChecklist.toggle(notes, lineIndex: 5) == nil)
        #expect(OrgChecklist.toggle(notes, lineIndex: -1) == nil)
    }

    @Test("toggle: non-checklist lineIndex returns nil")
    func toggleNonChecklistLine() {
        let notes = "Just some plain text\n- [ ] Item"
        // Line 0 is not a checklist line
        #expect(OrgChecklist.toggle(notes, lineIndex: 0) == nil)
    }

    @Test("toggle: label containing brackets only flips the marker")
    func toggleLabelWithBracketsPreserved() {
        let notes = "- [ ] Read [important] doc"
        let result = OrgChecklist.toggle(notes, lineIndex: 0)
        #expect(result == "- [X] Read [important] doc")
    }

    @Test("toggle: blank lines are preserved")
    func toggleBlankLinesPreserved() {
        let notes = "\n- [ ] Task\n\nMore notes"
        let result = OrgChecklist.toggle(notes, lineIndex: 1)
        let lines = result!.components(separatedBy: "\n")
        #expect(lines[0] == "")
        #expect(lines[1] == "- [X] Task")
        #expect(lines[2] == "")
        #expect(lines[3] == "More notes")
    }
}
