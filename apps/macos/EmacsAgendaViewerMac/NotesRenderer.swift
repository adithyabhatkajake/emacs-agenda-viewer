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

            // Checklist: "- [ ] ..." / "- [-] ..." / "- [X] ..." (also "+" and "*")
            if let match = line.range(
                of: #"^(\s*)([-+*])\s+\[( |X|x|-)\]\s?"#,
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

            // Bullet: "- ...", "+ ...", "* ..." (but avoid treating heading-style * text)
            if let match = line.range(
                of: #"^(\s*)([-+])\s+"#,
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
        replace(in: base,
                pattern: #"(?<![A-Za-z0-9*])\*([^\*\n]+?)\*(?![A-Za-z0-9*])"#) { m, str in
            let inner = str.substring(with: m.range(at: 1))
            return NSAttributedString(string: inner, attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor(Theme.textPrimary)
            ])
        }

        // 7. Italic: /text/
        replace(in: base,
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
        replace(in: base,
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
        pattern: String,
        build: (NSTextCheckingResult, NSString) -> NSAttributedString
    ) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let str = attr.string as NSString
        let matches = regex.matches(in: attr.string, range: NSRange(location: 0, length: str.length))
        // Apply in reverse so earlier ranges aren't invalidated.
        for m in matches.reversed() {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(blocks) { block in
                row(for: block)
            }
        }
    }

    @ViewBuilder
    private func row(for block: NoteBlock) -> some View {
        switch block {
        case .checklist(_, let lineIndex, let state, let indent, let inline):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if indent > 0 {
                    Spacer().frame(width: CGFloat(indent) * 16)
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
