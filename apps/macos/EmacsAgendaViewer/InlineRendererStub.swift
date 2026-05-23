// iOS thin wrapper over OrgInlineCore. Converts [InlineRun] to an
// AttributedString using UIKit (UIFont / UIColor) attributes.
// Pattern parsing, boundary rules, G19 URL trim, and timestamp formatting
// all live in OrgInlineCore (shared, no UIKit dependency).
//
// Six org markers per `org-emphasis-alist`:
//   *…* bold · /…/ italic · _…_ underline
//   =…= verbatim · ~…~ code · +…+ strikethrough
// Plus: [[url][label]] / [[url]] / bare URL / <timestamp>.
#if !os(macOS)
import SwiftUI
import UIKit

func renderInline(_ raw: String) -> AttributedString {
    OrgInlineIOS.render(raw)
}

enum OrgInlineIOS {
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
                .font: UIFont.systemFont(ofSize: 14),
                .foregroundColor: UIColor(Theme.textPrimary)
            ])

        case .bold(let text):
            return NSAttributedString(string: text, attributes: [
                .font: UIFont.systemFont(ofSize: 14, weight: .semibold),
                .foregroundColor: UIColor(Theme.textPrimary)
            ])

        case .italic(let text):
            let baseFont = UIFont.systemFont(ofSize: 14)
            let italicFont: UIFont = {
                if let descriptor = baseFont.fontDescriptor.withSymbolicTraits(.traitItalic) {
                    return UIFont(descriptor: descriptor, size: 14)
                }
                return baseFont
            }()
            return NSAttributedString(string: text, attributes: [
                .font: italicFont,
                .foregroundColor: UIColor(Theme.textPrimary)
            ])

        case .underline(let text):
            return NSAttributedString(string: text, attributes: [
                .font: UIFont.systemFont(ofSize: 14),
                .foregroundColor: UIColor(Theme.textPrimary),
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ])

        case .verbatim(let text), .code(let text):
            return NSAttributedString(string: text, attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                .foregroundColor: UIColor(Theme.textPrimary),
                .backgroundColor: UIColor(Theme.surfaceElevated)
            ])

        case .strikethrough(let text):
            return NSAttributedString(string: text, attributes: [
                .font: UIFont.systemFont(ofSize: 14),
                .foregroundColor: UIColor(Theme.textSecondary),
                .strikethroughStyle: NSUnderlineStyle.single.rawValue
            ])

        case .link(let text, let url):
            var attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 14),
                .foregroundColor: UIColor(Theme.accent),
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ]
            if let u = URL(string: url) { attrs[.link] = u }
            return NSAttributedString(string: text, attributes: attrs)

        case .bareURL(let url, let suffix):
            let plainAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 14),
                .foregroundColor: UIColor(Theme.textPrimary)
            ]
            var linkAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 14),
                .foregroundColor: UIColor(Theme.accent),
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
                .font: UIFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: UIColor(isInactive ? Theme.textTertiary : Theme.textSecondary)
            ])
        }
    }
}

// Previously had `extension NSString { func substring(with range: NSRange) }`
// which shadowed Foundation's NSString.substring(with:) and recursed
// infinitely → SIGSEGV the first time the timestamp / link regex matched
// (e.g. notes containing "[2026-05-21 Thu]"). The Swift bridge of
// NSString.substring(with:) already returns String — the extension was
// redundant. Do NOT add it back.

#endif
