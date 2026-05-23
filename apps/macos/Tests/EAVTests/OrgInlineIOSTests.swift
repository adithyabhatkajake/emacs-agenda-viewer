// Unit tests for OrgInlineIOS.render — the iOS inline org-emphasis renderer.
// Gated #if !os(macOS): the EAVCore SPM target is macOS-only so this file
// compiles to nothing under `swift test`. On an iOS simulator / Xcode iOS
// destination the suite runs normally.
#if !os(macOS)
import XCTest
import UIKit
@testable import EAVCore

// MARK: - Helpers

/// Plain visible string of an AttributedString.
private func txt(_ a: AttributedString) -> String { String(a.characters) }

/// Substring of an AttributedString slice.
private func txt(_ a: AttributedString, _ range: Range<AttributedString.Index>) -> String {
    String(a[range].characters)
}

/// Return the UIFont from a run's UIKit attribute scope, if set.
private func font(of run: AttributedString.Runs.Run) -> UIFont? {
    run[AttributeScopes.UIKitAttributes.FontAttribute.self]
}

/// Find the first run whose visible characters equal `content`.
private func firstRun(
    withText content: String,
    in attr: AttributedString
) -> AttributedString.Runs.Run? {
    attr.runs.first(where: { txt(attr, $0.range) == content })
}

final class OrgInlineIOSTests: XCTestCase {

    // MARK: 1. Bold at start of string

    func testBoldAtStart() {
        let attr = OrgInlineIOS.render("*bold*")
        XCTAssertEqual(txt(attr), "bold")
        guard let run = attr.runs.first else { return XCTFail("No runs") }
        guard let f = font(of: run) else { return XCTFail("No font on run") }
        XCTAssertTrue(
            f.fontDescriptor.symbolicTraits.contains(.traitBold),
            "Expected bold font for *bold*; got \(f)"
        )
    }

    // MARK: 2. Bold after space

    func testBoldAfterSpace() {
        let attr = OrgInlineIOS.render("word *bold*")
        XCTAssertEqual(txt(attr), "word bold")
        guard let run = firstRun(withText: "bold", in: attr) else {
            return XCTFail("No run for 'bold'")
        }
        guard let f = font(of: run) else { return XCTFail("No font on bold run") }
        XCTAssertTrue(f.fontDescriptor.symbolicTraits.contains(.traitBold))
    }

    // MARK: 3. Pathological — *foo*bar* must not match fully

    func testPathologicalBold() {
        // Org boundary rules: the closing marker must be followed by
        // whitespace, punctuation, or end of string. In "*foo*bar*" the char
        // after the first closing `*` is `b`, so no full match fires and the
        // entire string is literal.
        let attr = OrgInlineIOS.render("*foo*bar*")
        XCTAssertEqual(txt(attr), "*foo*bar*",
                       "Pathological *foo*bar* should remain literal")
    }

    // MARK: 4. Underline _…_

    func testUnderline() {
        let attr = OrgInlineIOS.render("_underline_")
        XCTAssertEqual(txt(attr), "underline")
        guard let run = attr.runs.first else { return XCTFail("No runs") }
        let underlineVal = run[AttributeScopes.UIKitAttributes.UnderlineStyleAttribute.self]
        XCTAssertNotNil(underlineVal,
                        "Expected underline attribute on '_underline_'")
    }

    // MARK: 5. Verbatim =…=

    func testVerbatim() {
        let attr = OrgInlineIOS.render("=verbatim=")
        XCTAssertEqual(txt(attr), "verbatim")
        guard let run = attr.runs.first else { return XCTFail("No runs") }
        guard let f = font(of: run) else { return XCTFail("No font on verbatim run") }
        XCTAssertTrue(
            f.fontDescriptor.symbolicTraits.contains(.traitMonoSpace) || f.isFixedPitch,
            "Expected monospaced font for =verbatim=; got \(f)"
        )
    }

    // MARK: 6. Code ~…~

    func testCode() {
        let attr = OrgInlineIOS.render("~code~")
        XCTAssertEqual(txt(attr), "code")
        guard let run = attr.runs.first else { return XCTFail("No runs") }
        guard let f = font(of: run) else { return XCTFail("No font on code run") }
        XCTAssertTrue(
            f.fontDescriptor.symbolicTraits.contains(.traitMonoSpace) || f.isFixedPitch,
            "Expected monospaced font for ~code~; got \(f)"
        )
    }

    // MARK: 7. Strikethrough +…+

    func testStrikethrough() {
        let attr = OrgInlineIOS.render("+strike+")
        XCTAssertEqual(txt(attr), "strike")
        guard let run = attr.runs.first else { return XCTFail("No runs") }
        let strikeVal = run[AttributeScopes.UIKitAttributes.StrikethroughStyleAttribute.self]
        XCTAssertNotNil(strikeVal,
                        "Expected strikethrough attribute on '+strike+'")
    }

    // MARK: 8. Labeled link [[url][Label]]

    func testLabeledLink() {
        let attr = OrgInlineIOS.render("[[https://example.com][Label]]")
        XCTAssertEqual(txt(attr), "Label")
        guard let run = attr.runs.first else { return XCTFail("No runs") }
        let linkVal = run[AttributeScopes.FoundationAttributes.LinkAttribute.self]
        XCTAssertEqual(linkVal, URL(string: "https://example.com"),
                       "Expected .link pointing to example.com")
    }

    // MARK: 9. Bare org link [[url]]

    func testBareOrgLink() {
        let attr = OrgInlineIOS.render("[[https://example.com]]")
        XCTAssertEqual(txt(attr), "https://example.com")
        guard let run = attr.runs.first else { return XCTFail("No runs") }
        let linkVal = run[AttributeScopes.FoundationAttributes.LinkAttribute.self]
        XCTAssertEqual(linkVal, URL(string: "https://example.com"))
    }

    // MARK: 10. Bare URL detection

    func testBareURL() {
        let attr = OrgInlineIOS.render("Visit https://example.com for info")
        XCTAssertEqual(txt(attr), "Visit https://example.com for info")
        let linkRun = attr.runs.first(where: {
            $0[AttributeScopes.FoundationAttributes.LinkAttribute.self] != nil
        })
        XCTAssertNotNil(linkRun, "Expected a run with .link for a bare URL")
        XCTAssertEqual(
            linkRun?[AttributeScopes.FoundationAttributes.LinkAttribute.self],
            URL(string: "https://example.com")
        )
    }

    // MARK: 11. Bare URL: trailing period stripped (G19)

    func testBareURLTrailingPeriod() {
        let attr = OrgInlineIOS.render("see https://example.com.")
        XCTAssertEqual(txt(attr), "see https://example.com.")
        let linkRun = attr.runs.first(where: {
            $0[AttributeScopes.FoundationAttributes.LinkAttribute.self] != nil
        })
        XCTAssertEqual(
            linkRun?[AttributeScopes.FoundationAttributes.LinkAttribute.self],
            URL(string: "https://example.com"),
            "Trailing period must not be part of the link"
        )
    }

    // MARK: 12. Bare URL: trailing paren stripped when URL is inside parens (G19)

    func testBareURLInsideParens() {
        let attr = OrgInlineIOS.render("(see https://example.com)")
        XCTAssertEqual(txt(attr), "(see https://example.com)")
        let linkRun = attr.runs.first(where: {
            $0[AttributeScopes.FoundationAttributes.LinkAttribute.self] != nil
        })
        XCTAssertEqual(
            linkRun?[AttributeScopes.FoundationAttributes.LinkAttribute.self],
            URL(string: "https://example.com"),
            "Trailing close-paren must not be part of the link"
        )
    }

    // MARK: 13. Bare URL: query string preserved, only trailing period stripped (G19)

    func testBareURLQueryStringPreserved() {
        let attr = OrgInlineIOS.render("https://example.com/path?x=1&y=2.")
        let linkRun = attr.runs.first(where: {
            $0[AttributeScopes.FoundationAttributes.LinkAttribute.self] != nil
        })
        XCTAssertEqual(
            linkRun?[AttributeScopes.FoundationAttributes.LinkAttribute.self],
            URL(string: "https://example.com/path?x=1&y=2"),
            "Query string must be preserved; only trailing punctuation stripped"
        )
    }

    // MARK: 14. Bare URL: trailing semicolon stripped (G19)

    func testBareURLTrailingSemicolon() {
        let attr = OrgInlineIOS.render("https://example.com;")
        let linkRun = attr.runs.first(where: {
            $0[AttributeScopes.FoundationAttributes.LinkAttribute.self] != nil
        })
        XCTAssertEqual(
            linkRun?[AttributeScopes.FoundationAttributes.LinkAttribute.self],
            URL(string: "https://example.com"),
            "Trailing semicolon must not be part of the link"
        )
    }

    // MARK: 15. Bare URL: plain URL unchanged (G19)

    func testBareURLNoTrailingPunct() {
        let attr = OrgInlineIOS.render("https://example.com")
        let linkRun = attr.runs.first(where: {
            $0[AttributeScopes.FoundationAttributes.LinkAttribute.self] != nil
        })
        XCTAssertEqual(
            linkRun?[AttributeScopes.FoundationAttributes.LinkAttribute.self],
            URL(string: "https://example.com"),
            "URL with no trailing punctuation must be linked as-is"
        )
    }

    // MARK: 16. Bare URL: trailing slash preserved (G19)

    func testBareURLTrailingSlashPreserved() {
        let attr = OrgInlineIOS.render("https://example.com/path/")
        let linkRun = attr.runs.first(where: {
            $0[AttributeScopes.FoundationAttributes.LinkAttribute.self] != nil
        })
        XCTAssertEqual(
            linkRun?[AttributeScopes.FoundationAttributes.LinkAttribute.self],
            URL(string: "https://example.com/path/"),
            "Trailing slash is not punctuation and must be kept in the link"
        )
    }

    // MARK: 17. Mixed bold + italic — neither bleeds

    func testMixedBoldAndItalic() {
        let attr = OrgInlineIOS.render("*bold* and /italic/ together")
        XCTAssertEqual(txt(attr), "bold and italic together")

        guard let boldRun = firstRun(withText: "bold", in: attr) else {
            return XCTFail("No bold run")
        }
        guard let italicRun = firstRun(withText: "italic", in: attr) else {
            return XCTFail("No italic run")
        }

        if let f = font(of: boldRun) {
            XCTAssertTrue(f.fontDescriptor.symbolicTraits.contains(.traitBold),
                          "Bold run must be bold")
            XCTAssertFalse(f.fontDescriptor.symbolicTraits.contains(.traitItalic),
                           "Bold run must not bleed italic")
        }
        if let f = font(of: italicRun) {
            XCTAssertTrue(f.fontDescriptor.symbolicTraits.contains(.traitItalic),
                          "Italic run must be italic")
            XCTAssertFalse(f.fontDescriptor.symbolicTraits.contains(.traitBold),
                           "Italic run must not bleed bold")
        }
    }

    // MARK: 18. Trailing punctuation — *bold*. leaves . in a non-bold run

    func testTrailingPunctuation() {
        let attr = OrgInlineIOS.render("*bold*.")
        XCTAssertEqual(txt(attr), "bold.")

        guard let boldRun = firstRun(withText: "bold", in: attr) else {
            return XCTFail("No bold run")
        }
        guard let f = font(of: boldRun) else { return XCTFail("No font on bold run") }
        XCTAssertTrue(f.fontDescriptor.symbolicTraits.contains(.traitBold))

        // The trailing dot must be in a distinct, non-bold run.
        if let dotRun = firstRun(withText: ".", in: attr) {
            let dotFont = font(of: dotRun)
            XCTAssertFalse(dotFont?.fontDescriptor.symbolicTraits.contains(.traitBold) == true,
                           "Trailing dot must not be bold")
        }
        // (If the dot is merged into the bold run the XCTAssertEqual above
        // already catches the mismatch via the visible-text check.)
    }

    // MARK: 19. Italic after opening paren: (/italic/)

    func testItalicAfterParen() {
        let attr = OrgInlineIOS.render("(/italic/)")
        XCTAssertEqual(txt(attr), "(italic)")

        guard let italicRun = firstRun(withText: "italic", in: attr) else {
            return XCTFail("No italic run inside parens")
        }
        guard let f = font(of: italicRun) else { return XCTFail("No font on italic run") }
        XCTAssertTrue(f.fontDescriptor.symbolicTraits.contains(.traitItalic),
                      "Expected italic font inside (/italic/)")
    }
}
#endif
