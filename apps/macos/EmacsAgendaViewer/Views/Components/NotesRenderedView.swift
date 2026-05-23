#if !os(macOS)
import SwiftUI

/// iOS-only block renderer for parsed org notes. Mirrors the Mac
/// `NotesRenderedView` in spirit (same block taxonomy from
/// `NotesParser`) but uses direct SwiftUI `Button` taps on checkbox icons
/// instead of the Mac's `eav-check://` URL-scheme indirection — buttons
/// route taps cleanly when this view is nested inside a Form row or a
/// row-expansion VStack.
struct NotesRenderedView: View {
    let blocks: [NoteBlock]
    let onToggleChecklist: (Int) -> Void

    private static let indentPx: CGFloat = 18

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
        case .checklist(let id, let state, let indent, let inline):
            checklistRow(id: id, state: state, indent: indent, inline: inline)
        case .bullet(_, let indent, let inline):
            bulletRow(indent: indent, inline: inline)
        case .paragraph(_, let inline):
            Text(inline)
                .font(.body)
                .foregroundStyle(Theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        case .blank:
            // Compact blank lines a touch — full-height blanks would dwarf
            // the surrounding rows when the user uses double-newlines to
            // visually separate paragraphs.
            Color.clear.frame(height: 4)
        }
    }

    @ViewBuilder
    private func checklistRow(id: Int, state: ChecklistState, indent: Int, inline: AttributedString) -> some View {
        Button {
            onToggleChecklist(id)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: glyph(for: state))
                    .font(.body)
                    .foregroundStyle(color(for: state))
                    .frame(width: 18)
                    .accessibilityHidden(true)
                Text(inline)
                    .font(.body)
                    .strikethrough(state == .done, color: Theme.textTertiary)
                    .foregroundStyle(state == .done ? Theme.textTertiary : Theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, CGFloat(indent) * Self.indentPx)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(checklistAccessibilityLabel(state: state, inline: inline))
    }

    private func checklistAccessibilityLabel(state: ChecklistState, inline: AttributedString) -> String {
        let text = String(inline.characters)
        let stateDescription: String
        switch state {
        case .notStarted: stateDescription = "not started"
        case .ongoing:    stateDescription = "in progress"
        case .done:       stateDescription = "done"
        }
        return "Toggle \(text), currently \(stateDescription)"
    }

    @ViewBuilder
    private func bulletRow(indent: Int, inline: AttributedString) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\u{2022}")
                .font(.body)
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 18, alignment: .center)
            Text(inline)
                .font(.body)
                .foregroundStyle(Theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(.leading, CGFloat(indent) * Self.indentPx)
    }

    private func glyph(for state: ChecklistState) -> String {
        switch state {
        case .notStarted: return "square"
        case .ongoing:    return "square.dashed"
        case .done:       return "checkmark.square.fill"
        }
    }

    private func color(for state: ChecklistState) -> Color {
        switch state {
        case .notStarted: return Theme.textTertiary
        case .ongoing:    return Theme.priorityB
        case .done:       return Theme.doneGreen
        }
    }
}
#endif
