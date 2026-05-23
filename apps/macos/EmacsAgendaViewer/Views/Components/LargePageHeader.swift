import SwiftUI

/// Inline page header that mirrors the design system's `.ph-nav` block:
/// optional uppercase pretitle eyebrow, then a 32pt bold tracking-tight title,
/// then an optional secondary subtitle. Lives inside the scroll content so the
/// underlying `navigationTitle` can stay empty/inline and leave the nav bar to
/// toolbar items (sort, filter, etc).
struct LargePageHeader: View {
    let pretitle: String?
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let pretitle, !pretitle.isEmpty {
                Text(pretitle.uppercased())
                    .font(.system(size: 13, weight: .semibold))
                    .tracking(0.52)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.bottom, 2)
            }
            Text(title)
                .font(.system(size: 32, weight: .bold))
                .tracking(-0.7)
                .lineSpacing(-2)
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }
}
