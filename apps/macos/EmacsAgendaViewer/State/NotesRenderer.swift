import Foundation

// Cross-platform shared types for org-notes block parsing + checklist
// mutation. Lives in the iOS app's `State/` so both Mac and iOS pick it up
// via their existing sources entries in `apps/macos/project.yml`. The Mac
// app's `EmacsAgendaViewerMac/NotesRenderer.swift` continues to host the
// platform-specific AppKit renderer and `ChecklistProgress` math.

enum ChecklistState {
    case notStarted, ongoing, done
}

enum NoteBlock: Identifiable {
    /// Each variant carries the source-line index of the block in the
    /// original notes text. We use it as the SwiftUI identity, which lets
    /// state (collapse, hover, etc.) survive re-parses triggered by a
    /// checkbox toggle. Generating a fresh `UUID()` per parse would re-key
    /// every block on every write, so for example a collapsed section
    /// would silently expand the next time the user toggled an unrelated
    /// checkbox elsewhere in the same notes body.
    case checklist(id: Int, state: ChecklistState, indent: Int, inline: AttributedString)
    case bullet(id: Int, indent: Int, inline: AttributedString)
    case paragraph(id: Int, inline: AttributedString)
    case blank(id: Int)

    var id: Int {
        switch self {
        case .checklist(let id, _, _, _): return id
        case .bullet(let id, _, _): return id
        case .paragraph(let id, _): return id
        case .blank(let id): return id
        }
    }

    /// Source-line index in the original notes text. Equal to `id`; kept
    /// as a separate accessor so call sites that use it for the rewrite
    /// path (toggling the right line in the file) read clearly.
    var lineIndex: Int { id }
}

enum NotesParser {
    /// Parse notes into blocks. Org bookkeeping lines (CLOCK:, SCHEDULED:,
    /// DEADLINE:, CLOSED:) and any drawer (`:NAME:` … `:END:`, including
    /// custom names and nested drawers) are skipped so they don't appear in
    /// the rendered view — but line indices stay aligned to the original
    /// text, so a checklist toggle rewrites the correct line.
    ///
    /// `renderInline` resolves per platform: iOS uses `InlineRendererStub`
    /// (UIKit-backed); Mac uses the AppKit `OrgInline.render` in
    /// `EmacsAgendaViewerMac/NotesRenderer.swift`.
    // Org drawer-start: colon, one or more uppercase letters, then optional
    // uppercase letters/digits/hyphens/underscores, closing colon — the entire
    // trimmed line. Matches :PROPERTIES:, :LOGBOOK:, :NOTES:, :FOO_BAR-2:, etc.
    // Anchored so :PROPERTIES_FOO: does not match :PROPERTIES: via hasPrefix.
    private static let drawerStartPattern = #"^:[A-Z][A-Z0-9_-]*:$"#

    // Anchored checklist prefix regex. Group 1 = leading whitespace,
    // group 2 = the single checkbox marker char (space, X, x, or -).
    // Anchored to ^ so it only matches the bullet's own checkbox, not any
    // `[ ]` / `[X]` / `[-]` that appears later in the line's text body.
    static let checklistPrefixRegex: NSRegularExpression? =
        try? NSRegularExpression(
            pattern: #"^(\s*)(?:[-+*]|(?:\d+|[a-zA-Z])[.)]) \s*\[([ Xx-])\]\s?"#
        )

    static func isDrawerStart(_ trimmedUpper: String) -> Bool {
        // Use range(of:options:) with .regularExpression — no separate
        // NSRegularExpression object, no failable initializer needed.
        trimmedUpper.range(of: drawerStartPattern, options: .regularExpression) != nil
    }

    static func isDrawerEnd(_ trimmedUpper: String) -> Bool {
        trimmedUpper == ":END:"
    }

    static func parse(_ text: String) -> [NoteBlock] {
        let lines = text.components(separatedBy: "\n")
        var blocks: [NoteBlock] = []
        // Depth counter rather than Bool: nested drawers (e.g. :PROPERTIES:
        // inside :LOGBOOK:) increment the counter and the first :END: only
        // closes the innermost drawer. Content is suppressed while depth > 0.
        var drawerDepth = 0
        for (idx, rawLine) in lines.enumerated() {
            let line = rawLine
            let trimmedUpper = line.trimmingCharacters(in: .whitespaces).uppercased()

            // Check end before start: :END: also matches the drawer-start
            // regex (^:[A-Z]+:$) so the order is load-bearing.
            if isDrawerEnd(trimmedUpper) {
                if drawerDepth > 0 { drawerDepth -= 1 }
                continue
            }
            if isDrawerStart(trimmedUpper) {
                drawerDepth += 1
                continue
            }
            if drawerDepth > 0 { continue }
            if trimmedUpper.hasPrefix("CLOCK:") { continue }
            if trimmedUpper.hasPrefix("SCHEDULED:") || trimmedUpper.hasPrefix("DEADLINE:") || trimmedUpper.hasPrefix("CLOSED:") {
                continue
            }

            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                blocks.append(.blank(id: idx))
                continue
            }

            let leading = line.prefix(while: { $0 == " " }).count
            let indent = leading / 2

            // Checklist: "- [ ] ..." / "1. [ ] ..." / "a) [ ] ..." etc.
            // Use the anchored regex so state is read from the bullet prefix
            // only — a body like "Replace [ ] with [X]" must not pollute the
            // state of a `- [ ]` bullet.
            if let regex = checklistPrefixRegex,
               let nsMatch = regex.firstMatch(
                   in: line,
                   range: NSRange(line.startIndex..<line.endIndex, in: line)
               ),
               let fullRange = Range(nsMatch.range, in: line) {
                let markerRange = Range(nsMatch.range(at: 2), in: line)
                let marker = markerRange.map { String(line[$0]) } ?? " "
                let after = String(line[fullRange.upperBound...])
                let state: ChecklistState = {
                    if marker == "X" || marker == "x" { return .done }
                    if marker == "-" { return .ongoing }
                    return .notStarted
                }()
                blocks.append(.checklist(
                    id: idx,
                    state: state,
                    indent: indent,
                    inline: renderInline(after)
                ))
                continue
            }

            // Bullet: "- ...", "+ ...", "* ...", "1. ...", "a) ..." etc.
            if let match = line.range(
                of: #"^(\s*)(?:[-+*]|(?:\d+|[a-zA-Z])[.)])\s+"#,
                options: .regularExpression
            ) {
                let after = String(line[match.upperBound...])
                blocks.append(.bullet(id: idx, indent: indent, inline: renderInline(after)))
                continue
            }

            blocks.append(.paragraph(id: idx, inline: renderInline(line)))
        }
        return blocks
    }
}

enum NotesMutation {
    /// Cycle `[ ]` → `[-]` → `[X]` → `[ ]` on the specified line (0-indexed).
    /// Returns the new string; returns nil if the line has no bullet checkbox.
    ///
    /// Only the checkbox in the bullet prefix is toggled. A line like
    /// `- [ ] Replace [ ] with [-]` toggles the bullet's `[ ]`, leaving the
    /// text body untouched. Anchoring is provided by `checklistPrefixRegex`.
    static func toggleChecklist(in text: String, lineIndex: Int) -> String? {
        var lines = text.components(separatedBy: "\n")
        guard lineIndex >= 0, lineIndex < lines.count else { return nil }
        let line = lines[lineIndex]

        guard let regex = NotesParser.checklistPrefixRegex,
              let nsMatch = regex.firstMatch(
                  in: line,
                  range: NSRange(line.startIndex..<line.endIndex, in: line)
              ),
              let markerRange = Range(nsMatch.range(at: 2), in: line) else {
            return nil
        }

        let marker = String(line[markerRange])
        let replacement: String
        switch marker {
        case " ":        replacement = "-"
        case "-":        replacement = "X"
        case "X", "x":  replacement = " "
        default:         return nil
        }

        var mutated = line
        mutated.replaceSubrange(markerRange, with: replacement)
        lines[lineIndex] = mutated
        return lines.joined(separator: "\n")
    }
}
