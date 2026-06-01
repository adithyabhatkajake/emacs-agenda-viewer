#if !os(macOS)
import SwiftUI

/// A checkbox circle that renders checklist progress as a pie fill.
///
/// States:
///  - `isDone == true`         → filled green circle with checkmark (done overrides everything)
///  - `progress == nil || items == 0` → plain empty circle (no checklist, current behavior)
///  - `0 < progress < 1`       → yellow pie sector from 12 o'clock, proportional to progress
///  - `progress == 1`          → full green pie (all checklist items done, task may still be open)
///
/// The outer ring is always drawn so the control reads as a circle at any fill level.
struct ProgressCheckbox: View {
    /// 0…1 checklist fraction; nil means no checklist (render plain circle).
    let progress: Double?
    let isDone: Bool
    let onTap: () -> Void

    private static let glyphSize: CGFloat = 18
    // 44pt meets the HIG minimum tap target; the glyph stays at 18pt centered.
    private static let hitSize: CGFloat = 44
    private static let lineWidth: CGFloat = 1.5

    var body: some View {
        Button(action: onTap) {
            ZStack {
                if isDone {
                    // Existing done appearance — matches the SF Symbol checkmark.circle.fill
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: Self.glyphSize, weight: .regular))
                        .foregroundStyle(Theme.doneGreen)
                } else if let p = progress, p > 0 {
                    pieFill(progress: p)
                } else {
                    // No checklist or 0% — plain ring
                    Image(systemName: "circle")
                        .font(.system(size: Self.glyphSize, weight: .regular))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .frame(width: Self.hitSize, height: Self.hitSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isDone ? "Mark not done" : "Mark done")
    }

    @ViewBuilder
    private func pieFill(progress: Double) -> some View {
        // Clamp so floating-point noise at 1.0 doesn't produce a gap.
        let clamped = min(max(progress, 0), 1)
        // accentTeal for in-progress (avoids collision with priorityB deadline-soon semantics).
        let fillColor: Color = clamped >= 1 ? Theme.doneGreen : Theme.accentTeal

        Canvas { ctx, size in
            let diameter = min(size.width, size.height)
            let radius = diameter / 2
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let stroke = Self.lineWidth

            // Outer ring — always drawn in the fill color so the border
            // matches the fill (yellow ring for in-progress, green for done).
            let ringRect = CGRect(
                x: center.x - radius + stroke / 2,
                y: center.y - radius + stroke / 2,
                width: diameter - stroke,
                height: diameter - stroke
            )
            var ringPath = Path(ellipseIn: ringRect)
            ctx.stroke(ringPath, with: .color(fillColor.opacity(0.55)), lineWidth: stroke)

            // Pie sector — starts at 12 o'clock (−π/2), sweeps clockwise.
            // Inner radius slightly smaller than the ring so there's a gap
            // between sector edge and outer ring (reads clearly at small sizes).
            let innerRadius = radius - stroke * 1.5
            let startAngle = Angle(degrees: -90)
            let endAngle   = Angle(degrees: -90 + 360 * clamped)

            var piePath = Path()
            piePath.move(to: center)
            piePath.addArc(
                center: center,
                radius: innerRadius,
                startAngle: startAngle,
                endAngle: endAngle,
                clockwise: false
            )
            piePath.closeSubpath()
            ctx.fill(piePath, with: .color(fillColor))
        }
        .frame(width: Self.glyphSize, height: Self.glyphSize)
    }
}

// MARK: - Progress helpers

/// Compute checklist progress from a parsed `[NoteBlock]` array.
/// Returns nil when there are no checklist blocks (no indicator should show).
func checklistProgress(from blocks: [NoteBlock]) -> Double? {
    let items = blocks.compactMap { block -> ChecklistState? in
        if case .checklist(_, let state, _, _) = block { return state }
        return nil
    }
    guard !items.isEmpty else { return nil }
    let done = items.filter { $0 == .done }.count
    return Double(done) / Double(items.count)
}

/// Compute checklist progress directly from a notes string using `OrgChecklist`.
/// Returns nil when the notes contain no checklist items.
func checklistProgress(from notes: String) -> Double? {
    let items = OrgChecklist.parse(notes)
    guard !items.isEmpty else { return nil }
    let done = items.filter { $0.checked }.count
    return Double(done) / Double(items.count)
}
#endif
