import Foundation

/// A parsed checklist item from an org-style notes string.
/// Matches lines of the form: `^\s*- \[[ xX-]\] (.*)$`
struct ChecklistItem: Equatable, Sendable {
    /// 0-based index of the line in the notes string split by newlines.
    let lineIndex: Int
    /// Whether the item is checked (`[X]` or `[x]`).
    let checked: Bool
    /// The label text after the checkbox marker.
    let label: String
}

enum OrgChecklist {
    // Matches `- [ ]`, `- [X]`, `- [x]`, `- [-]` at any leading indent.
    // nonisolated(unsafe): regex literal is immutable after initialization; safe to share.
    nonisolated(unsafe) private static let pattern = /^\s*- \[(?<mark>[ xX\-])\] (?<label>.*)$/

    /// Parse a notes string into checklist items. Lines that do not match
    /// the checklist pattern are ignored; only matched lines are returned.
    static func parse(_ notes: String) -> [ChecklistItem] {
        let lines = notes.components(separatedBy: "\n")
        var items: [ChecklistItem] = []
        for (index, line) in lines.enumerated() {
            guard let match = try? pattern.wholeMatch(in: line) else { continue }
            let mark = String(match.mark)
            let checked = mark == "X" || mark == "x"
            items.append(ChecklistItem(lineIndex: index, checked: checked, label: String(match.label)))
        }
        return items
    }

    /// Uncheck every checklist item in `notes`, turning `[X]`, `[x]`, and
    /// `[-]` into `[ ]`. Non-checklist lines are preserved exactly.
    ///
    /// Returns the mutated string. If there are no checklist items the
    /// original string is returned unchanged.
    static func resetAll(_ notes: String) -> String {
        let lines = notes.components(separatedBy: "\n")
        let reset = lines.map { line -> String in
            guard let match = try? pattern.wholeMatch(in: line) else { return line }
            let mark = String(match.mark)
            guard mark != " " else { return line }
            return line.replacingOccurrences(of: "[\(mark)]", with: "[ ]",
                                             range: line.range(of: "[\(mark)]"))
        }
        return reset.joined(separator: "\n")
    }

    /// Toggle the checklist item at `lineIndex` in `notes`, flipping `[ ]`
    /// to `[X]` or `[X]`/`[x]`/`[-]` to `[ ]`. All other lines are
    /// preserved exactly, including indentation and blank lines.
    ///
    /// Returns `nil` if `lineIndex` is out of bounds or does not point to a
    /// checklist line.
    static func toggle(_ notes: String, lineIndex: Int) -> String? {
        var lines = notes.components(separatedBy: "\n")
        guard lineIndex >= 0, lineIndex < lines.count else { return nil }
        let line = lines[lineIndex]
        guard let match = try? pattern.wholeMatch(in: line) else { return nil }
        let mark = String(match.mark)
        let isChecked = mark == "X" || mark == "x"
        let newMark = isChecked ? " " : "X"
        // Replace only the first occurrence of `[<mark>]` so we don't disturb
        // any bracket content in the label itself.
        let oldMarker = "[\(mark)]"
        let newMarker = "[\(newMark)]"
        lines[lineIndex] = line.replacingOccurrences(of: oldMarker, with: newMarker, range: line.range(of: oldMarker))
        return lines.joined(separator: "\n")
    }
}
