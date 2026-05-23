import SwiftUI

/// Three-up chip strip used in Today and Habits hero areas.
/// Mirrors the design system's `.summary-strip` block: rounded surface chips
/// with a big tabular-nums number above a small uppercase letter-spaced label.
struct SummaryChip: Identifiable {
    let id = UUID()
    let label: String
    let number: String
    /// Optional SF Symbol rendered next to the number (e.g. "flame.fill").
    var trailingSymbol: String? = nil
    var trailingSymbolColor: Color? = nil
}

struct SummaryChipStrip: View {
    let chips: [SummaryChip]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(chips) { chip in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(chip.number)
                            .font(.system(size: 22, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        if let sym = chip.trailingSymbol {
                            Image(systemName: sym)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(chip.trailingSymbolColor ?? Theme.priorityB)
                                .accessibilityHidden(true)
                        }
                    }
                    Text(chip.label)
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.8)
                        .textCase(.uppercase)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(chip.number) \(chip.label)")
            }
        }
    }
}
