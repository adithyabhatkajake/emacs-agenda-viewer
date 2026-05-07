import SwiftUI
import AppKit

enum ChecklistState {
    case notStarted, ongoing, done
}

enum NoteBlock: Identifiable {
    case checklist(id: UUID, lineIndex: Int, state: ChecklistState, indent: Int, inline: AttributedString)
    case bullet(id: UUID, indent: Int, inline: AttributedString)
    case paragraph(id: UUID, inline: AttributedString)
    case blank(id: UUID)

    var id: UUID {
        switch self {
        case .checklist(let id, _, _, _, _): return id
        case .bullet(let id, _, _): return id
        case .paragraph(let id, _): return id
        case .blank(let id): return id
        }
    }
}

enum NotesParser {
    /// Parse notes into blocks. Org bookkeeping lines (CLOCK:, SCHEDULED:,
    /// DEADLINE:, CLOSED:, :PROPERTIES:/:LOGBOOK: drawers) are skipped so they
    /// don't appear in the rendered view — but line indices stay aligned to
    /// the original text, so a checklist toggle rewrites the correct line.
    static func parse(_ text: String) -> [NoteBlock] {
        let lines = text.components(separatedBy: "\n")
        var blocks: [NoteBlock] = []
        var inDrawer = false
        for (idx, rawLine) in lines.enumerated() {
            let line = rawLine
            let trimmedUpper = line.trimmingCharacters(in: .whitespaces).uppercased()

            if trimmedUpper.hasPrefix(":PROPERTIES:") || trimmedUpper.hasPrefix(":LOGBOOK:") {
                inDrawer = true
                continue
            }
            if trimmedUpper == ":END:" {
                inDrawer = false
                continue
            }
            if inDrawer { continue }
            if trimmedUpper.hasPrefix("CLOCK:") { continue }
            if trimmedUpper.hasPrefix("SCHEDULED:") || trimmedUpper.hasPrefix("DEADLINE:") || trimmedUpper.hasPrefix("CLOSED:") {
                continue
            }

            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                blocks.append(.blank(id: UUID()))
                continue
            }

            let leading = line.prefix(while: { $0 == " " }).count
            let indent = leading / 2

            // Checklist: "- [ ] ..." / "1. [ ] ..." / "a) [ ] ..." etc.
            if let match = line.range(
                of: #"^(\s*)(?:[-+*]|(?:\d+|[a-zA-Z])[.)])\s+\[( |X|x|-)\]\s?"#,
                options: .regularExpression
            ) {
                let after = String(line[match.upperBound...])
                let state: ChecklistState = {
                    if line.contains("[X]") || line.contains("[x]") { return .done }
                    if line.contains("[-]") { return .ongoing }
                    return .notStarted
                }()
                blocks.append(.checklist(
                    id: UUID(),
                    lineIndex: idx,
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
                blocks.append(.bullet(id: UUID(), indent: indent, inline: renderInline(after)))
                continue
            }

            blocks.append(.paragraph(id: UUID(), inline: renderInline(line)))
        }
        return blocks
    }
}

// MARK: - Inline renderer

private enum OrgInline {
    /// Apply org-markup styling. Patterns are applied in priority order; each pass
    /// replaces matched ranges in the `NSMutableAttributedString`.
    static func render(_ raw: String) -> AttributedString {
        let base = NSMutableAttributedString(string: raw, attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor(Theme.textPrimary)
        ])

        // 1. Links with label: [[url][label]]
        replace(in: base,
                pattern: #"\[\[([^\]\[]+)\]\[([^\]\[]+)\]\]"#) { m, str in
            let url = str.substring(with: m.range(at: 1))
            let label = str.substring(with: m.range(at: 2))
            var attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor(Theme.accent),
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ]
            if let u = URL(string: url) { attrs[.link] = u }
            return NSAttributedString(string: label, attributes: attrs)
        }

        // 2. Bare links: [[url]]
        replace(in: base,
                pattern: #"\[\[([^\]\[]+)\]\]"#) { m, str in
            let url = str.substring(with: m.range(at: 1))
            var attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor(Theme.accent),
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ]
            if let u = URL(string: url) { attrs[.link] = u }
            return NSAttributedString(string: url, attributes: attrs)
        }

        // 3. Bare URLs (http/https)
        replace(in: base,
                pattern: #"(?<![\w/])(https?://[^\s<>\])]+)"#) { m, str in
            let url = str.substring(with: m.range(at: 1))
            var attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor(Theme.accent),
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ]
            if let u = URL(string: url) { attrs[.link] = u }
            return NSAttributedString(string: url, attributes: attrs)
        }

        // 4. Timestamps: <YYYY-MM-DD [day] [HH:MM[-HH:MM]]> and [YYYY-MM-DD ...]
        replace(in: base,
                pattern: #"[<\[](\d{4}-\d{2}-\d{2}(?:\s+[A-Za-z]{3})?(?:\s+\d{1,2}:\d{2}(?:-\d{1,2}:\d{2})?)?(?:\s+[+.]\d+[hdwmy])?)[>\]]"#) { m, str in
            let inner = str.substring(with: m.range(at: 1))
            let open = str.substring(with: NSRange(location: m.range.location, length: 1))
            let isInactive = (open == "[")
            let display = formatTimestamp(inner)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor(isInactive ? Theme.textTertiary : Theme.textSecondary)
            ]
            return NSAttributedString(string: display, attributes: attrs)
        }

        // 5. Inline code: =verbatim= and ~code~
        replace(in: base,
                pattern: #"(?<![A-Za-z0-9])[=~]([^=~\n]+?)[=~](?![A-Za-z0-9])"#) { m, str in
            let inner = str.substring(with: m.range(at: 1))
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor(Theme.textPrimary),
                .backgroundColor: NSColor(Theme.surfaceElevated)
            ]
            return NSAttributedString(string: inner, attributes: attrs)
        }

        // 6. Bold: *text*
        replace(in: base, skipProcessed: true,
                pattern: #"(?<![A-Za-z0-9*])\*([^\*\n]+?)\*(?![A-Za-z0-9*])"#) { m, str in
            let inner = str.substring(with: m.range(at: 1))
            return NSAttributedString(string: inner, attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor(Theme.textPrimary)
            ])
        }

        // 7. Italic: /text/
        replace(in: base, skipProcessed: true,
                pattern: #"(?<![A-Za-z0-9/])/([^/\n]+?)/(?![A-Za-z0-9/])"#) { m, str in
            let inner = str.substring(with: m.range(at: 1))
            let italic = NSFontManager.shared.convert(
                NSFont.systemFont(ofSize: 13),
                toHaveTrait: .italicFontMask
            )
            return NSAttributedString(string: inner, attributes: [
                .font: italic,
                .foregroundColor: NSColor(Theme.textPrimary)
            ])
        }

        // 8. Underline: _text_
        replace(in: base, skipProcessed: true,
                pattern: #"(?<![A-Za-z0-9_])_([^_\n]+?)_(?![A-Za-z0-9_])"#) { m, str in
            let inner = str.substring(with: m.range(at: 1))
            return NSAttributedString(string: inner, attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor(Theme.textPrimary),
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ])
        }

        return AttributedString(base)
    }

    private static func replace(
        in attr: NSMutableAttributedString,
        skipProcessed: Bool = false,
        pattern: String,
        build: (NSTextCheckingResult, NSString) -> NSAttributedString
    ) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let str = attr.string as NSString
        let matches = regex.matches(in: attr.string, range: NSRange(location: 0, length: str.length))
        // Apply in reverse so earlier ranges aren't invalidated.
        for m in matches.reversed() {
            if skipProcessed {
                var alreadyStyled = false
                attr.enumerateAttribute(.backgroundColor, in: m.range) { val, _, stop in
                    if val != nil { alreadyStyled = true; stop.pointee = true }
                }
                if alreadyStyled { continue }
            }
            let replacement = build(m, str)
            attr.replaceCharacters(in: m.range, with: replacement)
        }
    }

    private static func formatTimestamp(_ inner: String) -> String {
        // inner like "2026-04-19 Sun" or "2026-04-19 Sun 13:00" or "2026-04-19 13:00-14:00"
        let parts = inner.split(separator: " ").map(String.init)
        guard let datePart = parts.first else { return inner }

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        guard let date = df.date(from: datePart) else { return inner }

        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let target = cal.startOfDay(for: date)
        let days = cal.dateComponents([.day], from: today, to: target).day ?? 0

        let dayLabel: String
        switch days {
        case 0: dayLabel = "Today"
        case 1: dayLabel = "Tomorrow"
        case -1: dayLabel = "Yesterday"
        case 2...6:
            let fmt = DateFormatter(); fmt.dateFormat = "EEEE"
            dayLabel = fmt.string(from: date)
        default:
            let fmt = DateFormatter(); fmt.dateFormat = "MMM d"
            dayLabel = fmt.string(from: date)
        }

        // Find a time fragment: HH:MM or HH:MM-HH:MM
        let timeFragment = parts.dropFirst().first(where: { $0.contains(":") })
        if let t = timeFragment {
            return "\(dayLabel) \(t)"
        }
        return dayLabel
    }
}

// MARK: - Rendered view

struct NotesRenderedView: View {
    let blocks: [NoteBlock]
    let onToggleChecklist: (Int) -> Void
    @State private var collapsed: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(blocks.enumerated()), id: \.element.id) { idx, block in
                if !isHidden(idx) {
                    row(for: block, index: idx)
                }
            }
        }
    }

    private func indentOf(_ block: NoteBlock) -> Int {
        switch block {
        case .checklist(_, _, _, let indent, _): return indent
        case .bullet(_, let indent, _): return indent
        default: return 0
        }
    }

    private func hasChildren(_ index: Int) -> Bool {
        guard index + 1 < blocks.count else { return false }
        let myIndent = indentOf(blocks[index])
        let nextIndent = indentOf(blocks[index + 1])
        let isListItem: Bool = {
            switch blocks[index] {
            case .checklist, .bullet: return true
            default: return false
            }
        }()
        return isListItem && nextIndent > myIndent
    }

    private func isHidden(_ index: Int) -> Bool {
        for i in stride(from: index - 1, through: 0, by: -1) {
            let parentIndent = indentOf(blocks[i])
            let myIndent = indentOf(blocks[index])
            if parentIndent < myIndent {
                if collapsed.contains(blocks[i].id) { return true }
            }
            if parentIndent == 0 { break }
        }
        return false
    }

    @ViewBuilder
    private func row(for block: NoteBlock, index: Int) -> some View {
        switch block {
        case .checklist(_, let lineIndex, let state, let indent, let inline):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if indent > 0 {
                    Spacer().frame(width: CGFloat(indent) * 16)
                }
                if hasChildren(index) {
                    Button {
                        if collapsed.contains(block.id) {
                            collapsed.remove(block.id)
                        } else {
                            collapsed.insert(block.id)
                        }
                    } label: {
                        Image(systemName: collapsed.contains(block.id) ? "chevron.right" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                            .frame(width: 10)
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    onToggleChecklist(lineIndex)
                } label: {
                    checklistIcon(for: state)
                }
                .buttonStyle(.plain)
                Text(inline)
                    .strikethrough(state == .done, color: Theme.textTertiary)
                    .foregroundStyle(foregroundColor(for: state))
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 1)

        case .bullet(_, let indent, let inline):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if indent > 0 {
                    Spacer().frame(width: CGFloat(indent) * 16)
                }
                if hasChildren(index) {
                    Button {
                        if collapsed.contains(block.id) {
                            collapsed.remove(block.id)
                        } else {
                            collapsed.insert(block.id)
                        }
                    } label: {
                        Image(systemName: collapsed.contains(block.id) ? "chevron.right" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                            .frame(width: 10)
                    }
                    .buttonStyle(.plain)
                }
                Text("•")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textTertiary)
                Text(inline)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 1)

        case .paragraph(_, let inline):
            Text(inline)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 1)

        case .blank:
            Spacer().frame(height: 6)
        }
    }

    @ViewBuilder
    private func checklistIcon(for state: ChecklistState) -> some View {
        switch state {
        case .notStarted:
            Image(systemName: "circle")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textTertiary)
        case .ongoing:
            ZStack {
                Image(systemName: "circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.priorityB)
                Image(systemName: "minus")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
            }
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(Theme.doneGreen)
        }
    }

    private func foregroundColor(for state: ChecklistState) -> Color {
        switch state {
        case .notStarted: return Theme.textPrimary
        case .ongoing: return Theme.textPrimary
        case .done: return Theme.textTertiary
        }
    }
}

// MARK: - Toggle helper

enum NotesMutation {
    /// Cycle `[ ]` → `[-]` → `[X]` → `[ ]` on the specified line (0-indexed).
    /// Returns the new string; returns nil if the line has no checkbox.
    static func toggleChecklist(in text: String, lineIndex: Int) -> String? {
        var lines = text.components(separatedBy: "\n")
        guard lineIndex >= 0, lineIndex < lines.count else { return nil }
        let line = lines[lineIndex]
        if let r = line.range(of: "[ ]") {
            lines[lineIndex] = line.replacingCharacters(in: r, with: "[-]")
        } else if let r = line.range(of: "[-]") {
            lines[lineIndex] = line.replacingCharacters(in: r, with: "[X]")
        } else if let r = line.range(of: "[X]") ?? line.range(of: "[x]") {
            lines[lineIndex] = line.replacingCharacters(in: r, with: "[ ]")
        } else {
            return nil
        }
        return lines.joined(separator: "\n")
    }
}

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
                if case .checklist(_, _, let state, let indent, _) = block {
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
