import SwiftUI

struct TagChips: View {
    let tags: [String]
    let inheritedTags: [String]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(tags, id: \.self) { tag in
                chip(tag, inherited: false)
            }
            ForEach(inheritedTags.filter { !tags.contains($0) }, id: \.self) { tag in
                chip(tag, inherited: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let all = tags + inheritedTags.filter { !tags.contains($0) }
        guard !all.isEmpty else { return "" }
        return "Tags: \(all.joined(separator: ", "))"
    }

    private func chip(_ tag: String, inherited: Bool) -> some View {
        Text(tag)
            .font(.caption2)
            .foregroundStyle(inherited ? Theme.textTertiary : Theme.textSecondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                Capsule(style: .continuous)
                    .fill(Theme.surfaceElevated.opacity(inherited ? 0.4 : 0.8))
            )
    }
}
