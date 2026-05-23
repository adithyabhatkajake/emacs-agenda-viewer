import SwiftUI
import AppKit

// NotesParser / NoteBlock / ChecklistState / NotesMutation moved to the
// shared `EmacsAgendaViewer/State/NotesRenderer.swift` so the iOS app can
// reuse the same parser. The Mac-specific OrgInline renderer and
// NotesRenderedView still live here.

// MARK: - Inline renderer

enum OrgInline {
    /// Apply org-markup styling. Delegates parsing to `OrgInlineCore.parse`
    /// and converts each `InlineRun` to an `NSAttributedString` with
    /// AppKit (NSFont / NSColor) attributes.
    ///
    /// Six markers per `org-emphasis-alist`:
    ///   *…* bold · /…/ italic · _…_ underline
    ///   =…= verbatim · ~…~ code · +…+ strikethrough
    /// Plus: [[url][label]] / [[url]] / bare URL / <timestamp>.
    static func render(_ raw: String) -> AttributedString {
        let base = NSMutableAttributedString()
        let runs = OrgInlineCore.parse(raw)
        for run in runs {
            base.append(nsAttributed(run))
        }
        return AttributedString(base)
    }

    // MARK: - Run-to-NSAttributedString conversion

    private static func nsAttributed(_ run: InlineRun) -> NSAttributedString {
        switch run {
        case .plain(let text):
            return NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor(Theme.textPrimary)
            ])

        case .bold(let text):
            return NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor(Theme.textPrimary)
            ])

        case .italic(let text):
            let italic = NSFontManager.shared.convert(
                NSFont.systemFont(ofSize: 13),
                toHaveTrait: .italicFontMask
            )
            return NSAttributedString(string: text, attributes: [
                .font: italic,
                .foregroundColor: NSColor(Theme.textPrimary)
            ])

        case .underline(let text):
            return NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor(Theme.textPrimary),
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ])

        case .verbatim(let text), .code(let text):
            return NSAttributedString(string: text, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor(Theme.textPrimary),
                .backgroundColor: NSColor(Theme.surfaceElevated)
            ])

        case .strikethrough(let text):
            return NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor(Theme.textSecondary),
                .strikethroughStyle: NSUnderlineStyle.single.rawValue
            ])

        case .link(let text, let url):
            var attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor(Theme.accent),
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ]
            if let u = URL(string: url) { attrs[.link] = u }
            return NSAttributedString(string: text, attributes: attrs)

        case .bareURL(let url, let suffix):
            let plainAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor(Theme.textPrimary)
            ]
            var linkAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor(Theme.accent),
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ]
            if let u = URL(string: url) { linkAttrs[.link] = u }
            let result = NSMutableAttributedString(string: url, attributes: linkAttrs)
            if !suffix.isEmpty {
                result.append(NSAttributedString(string: suffix, attributes: plainAttrs))
            }
            return result

        case .timestamp(let display, let isInactive):
            return NSAttributedString(string: display, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor(isInactive ? Theme.textTertiary : Theme.textSecondary)
            ])
        }
    }
}

// MARK: - Rendered view

/// Renders notes as a SINGLE `Text(AttributedString)` view. Previous
/// implementation built one HStack per NoteBlock; for a heavy task (~100
/// blocks) that produced ~700 layout nodes and the StackLayout solver would
/// cascade through all of them on every layout transaction, saturating the
/// main thread (see sample taken 2026-05-18). Folding the entire body into
/// one attributed string collapses the per-block layout cost to ~O(text length)
/// and routes checkbox/collapse interactions through `OpenURLAction` rather
/// than per-row Buttons.
struct NotesRenderedView: View {
    let blocks: [NoteBlock]
    let onToggleChecklist: (Int) -> Void
    /// Collapse state keyed by source-line index. Stable across re-parses,
    /// so toggling a checkbox elsewhere in the body doesn't silently
    /// expand a previously-collapsed sibling.
    @State private var collapsed: Set<Int> = []

    var body: some View {
        Text(attributed)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.openURL, OpenURLAction(handler: handleURL))
    }

    // MARK: Building the attributed string

    private struct VisibleEntry {
        let block: NoteBlock
        let hasChildren: Bool
    }

    /// Single forward pass replaces the O(N²) per-row `isHidden` walk and
    /// per-row `hasChildren` lookup of the previous implementation.
    private var visibleBlocks: [VisibleEntry] {
        var out: [VisibleEntry] = []
        out.reserveCapacity(blocks.count)
        var hideUnderIndent: Int? = nil
        for i in 0..<blocks.count {
            let block = blocks[i]
            let myIndent = indentOf(block)
            if let h = hideUnderIndent {
                if myIndent > h { continue }
                hideUnderIndent = nil
            }
            let isListItem: Bool
            switch block {
            case .checklist, .bullet: isListItem = true
            default: isListItem = false
            }
            let hasKids = isListItem
                && i + 1 < blocks.count
                && indentOf(blocks[i + 1]) > myIndent
            out.append(VisibleEntry(block: block, hasChildren: hasKids))
            if isListItem && collapsed.contains(block.id) {
                hideUnderIndent = myIndent
            }
        }
        return out
    }

    private var attributed: AttributedString {
        var out = AttributedString()
        let visible = visibleBlocks
        for (offset, entry) in visible.enumerated() {
            if offset > 0 {
                out.append(AttributedString("\n"))
            }
            out.append(line(for: entry))
        }
        return out
    }

    private func line(for entry: VisibleEntry) -> AttributedString {
        switch entry.block {
        case .checklist(let id, let state, let indent, let inline):
            var result = indentString(indent)
            if entry.hasChildren {
                result.append(chevronRun(for: id))
            }
            result.append(checklistRun(state: state, lineIndex: id))
            result.append(bodyWithState(inline, state: state))
            return result

        case .bullet(let id, let indent, let inline):
            var result = indentString(indent)
            if entry.hasChildren {
                result.append(chevronRun(for: id))
            }
            var bullet = AttributedString("• ")
            bullet.foregroundColor = Theme.textTertiary
            result.append(bullet)
            result.append(inline)
            return result

        case .paragraph(_, let inline):
            return inline

        case .blank:
            // Single space keeps the line break we already insert between
            // entries; a zero-length line would collapse visually.
            return AttributedString(" ")
        }
    }

    private func indentString(_ level: Int) -> AttributedString {
        guard level > 0 else { return AttributedString() }
        return AttributedString(String(repeating: "    ", count: level))
    }

    private func chevronRun(for id: Int) -> AttributedString {
        let isCollapsed = collapsed.contains(id)
        var chev = AttributedString(isCollapsed ? "▸ " : "▾ ")
        chev.foregroundColor = Theme.textTertiary
        if let url = URL(string: "eav-collapse://\(id)") {
            chev.link = url
        }
        return chev
    }

    private func checklistRun(state: ChecklistState, lineIndex: Int) -> AttributedString {
        let glyph: String
        let color: Color
        switch state {
        case .notStarted: glyph = "☐ "; color = Theme.textTertiary
        case .ongoing:    glyph = "◐ "; color = Theme.priorityB
        case .done:       glyph = "☑ "; color = Theme.doneGreen
        }
        var run = AttributedString(glyph)
        run.foregroundColor = color
        if let url = URL(string: "eav-check://\(lineIndex)") {
            run.link = url
        }
        return run
    }

    private func bodyWithState(_ inline: AttributedString, state: ChecklistState) -> AttributedString {
        guard state == .done else { return inline }
        var body = inline
        let range = body.startIndex..<body.endIndex
        body[range].strikethroughStyle = .single
        body[range].foregroundColor = Theme.textTertiary
        return body
    }

    private func indentOf(_ block: NoteBlock) -> Int {
        switch block {
        case .checklist(_, _, let indent, _): return indent
        case .bullet(_, let indent, _): return indent
        default: return 0
        }
    }

    // MARK: URL dispatch

    private func handleURL(_ url: URL) -> OpenURLAction.Result {
        switch url.scheme {
        case "eav-check":
            if let host = url.host, let line = Int(host) {
                onToggleChecklist(line)
                return .handled
            }
            return .discarded
        case "eav-collapse":
            if let host = url.host, let id = Int(host) {
                if collapsed.contains(id) {
                    collapsed.remove(id)
                } else {
                    collapsed.insert(id)
                }
                return .handled
            }
            return .discarded
        default:
            return .systemAction
        }
    }
}

// NotesMutation moved to shared `EmacsAgendaViewer/State/NotesRenderer.swift`.

// MARK: - Inline exposed for reuse

func renderInline(_ raw: String) -> AttributedString {
    OrgInline.render(raw)
}

// MARK: - Checklist progress

/// Hierarchically-weighted checklist completion.
///
/// Builds a tree from indent levels, then recursively computes done / ongoing
/// fractions in [0, 1] where each subtree contributes its weight × the average
/// of its children's fractions. Leaves contribute their own state directly:
/// `[X]` → 1.0 done, `[-]` → 1.0 ongoing, `[ ]` → 0.0.
///
/// This avoids the double-counting that flat counting introduces for parent
/// items that org auto-aggregates to `[-]`. For
///
/// ```
/// - [X] A
/// - [ ] B
/// - [-] C
///   - [X] A
///   - [-] B
/// ```
///
/// the result is `done = 1/3 + (1/2)*(1/3) = 1/2`, `ongoing = (1/2)*(1/3) = 1/6`.
struct ChecklistProgress {
    /// Fraction of total work that is done, in [0, 1].
    let done: Double
    /// Fraction of total work that is in-progress, in [0, 1].
    /// `done + ongoing <= 1`.
    let ongoing: Double
    /// Total number of checklist items at every depth — for "%" text only.
    let itemCount: Int

    /// Walk the parsed blocks and weight by hierarchy. Returns nil when the
    /// notes contain no checklist items.
    static func compute(from text: String) -> ChecklistProgress? {
        let checklists: [(state: ChecklistState, indent: Int)] = NotesParser.parse(text)
            .compactMap { block in
                if case .checklist(_, let state, let indent, _) = block {
                    return (state, indent)
                }
                return nil
            }
        guard !checklists.isEmpty else { return nil }

        // Build the tree: each entry whose indent strictly exceeds the previous
        // becomes a child of the most recent shallower entry.
        struct Node { let state: ChecklistState; let indent: Int; var children: [Int] = [] }
        var nodes: [Node] = []
        var roots: [Int] = []
        var stack: [Int] = []  // indices into nodes, only ancestors of current

        for c in checklists {
            // Pop any ancestors whose indent is >= current indent — they aren't
            // ancestors of this node.
            while let top = stack.last, nodes[top].indent >= c.indent {
                stack.removeLast()
            }
            let idx = nodes.count
            nodes.append(Node(state: c.state, indent: c.indent))
            if let parent = stack.last {
                nodes[parent].children.append(idx)
            } else {
                roots.append(idx)
            }
            stack.append(idx)
        }

        func fractions(of idx: Int) -> (done: Double, ongoing: Double) {
            let n = nodes[idx]
            if n.children.isEmpty {
                switch n.state {
                case .done:       return (1, 0)
                case .ongoing:    return (0, 1)
                case .notStarted: return (0, 0)
                }
            }
            var d = 0.0, o = 0.0
            for c in n.children {
                let f = fractions(of: c)
                d += f.done
                o += f.ongoing
            }
            let count = Double(n.children.count)
            return (d / count, o / count)
        }

        var totalDone = 0.0, totalOngoing = 0.0
        for r in roots {
            let f = fractions(of: r)
            totalDone += f.done
            totalOngoing += f.ongoing
        }
        let denom = Double(roots.count)
        return ChecklistProgress(
            done: totalDone / denom,
            ongoing: totalOngoing / denom,
            itemCount: checklists.count
        )
    }
}
