// Pure Swift + Foundation — no UIKit/AppKit dependency.
// Parses one line of org inline markup and returns a typed run sequence.
// Platform wrappers (OrgInline on Mac, OrgInlineIOS on iOS) convert runs
// to platform AttributedStrings.
import Foundation

// MARK: - Run type

enum InlineRun: Equatable {
    case plain(String)
    case bold(String)
    case italic(String)
    case underline(String)
    case verbatim(String)
    case code(String)
    case strikethrough(String)
    /// Labeled or bare org link: [[url][label]] / [[url]].
    case link(text: String, url: String)
    /// Bare https?:// URL. suffix is trailing punctuation kept as plain.
    case bareURL(url: String, suffix: String)
    /// Formatted timestamp display string with activeness flag.
    case timestamp(display: String, isInactive: Bool)
}

// MARK: - Core parser

enum OrgInlineCore {
    /// Parse `raw` and return an ordered sequence of typed runs. The total
    /// visible text of all runs joined equals the rendered visible text.
    static func parse(_ raw: String) -> [InlineRun] {
        // The pipeline mirrors the NSMutableAttributedString mutation order in
        // the platform renderers: links → URL → timestamps → code/verbatim →
        // bold → italic → underline → strikethrough. Unmatched text becomes
        // .plain. Ranges are consumed so a later pass cannot re-match them.

        // Work in terms of NSRange / NSString because the regex infra uses
        // NSTextCheckingResult, which gives NSRange.
        let ns = raw as NSString
        let len = ns.length

        // Sentinel: each UTF-16 position is marked with which run index owns it,
        // or -1 for "unclaimed". We claim ranges as we find them.
        var owner = [Int](repeating: -1, count: len)
        // Accumulator: (NSRange, InlineRun) pairs added in pattern-match order.
        var found: [(NSRange, InlineRun)] = []

        func claim(_ range: NSRange, _ run: InlineRun) {
            for i in range.location..<(range.location + range.length) {
                owner[i] = found.count
            }
            found.append((range, run))
        }

        func isFree(_ range: NSRange) -> Bool {
            for i in range.location..<(range.location + range.length) {
                if owner[i] != -1 { return false }
            }
            return true
        }

        func matches(pattern: String) -> [NSTextCheckingResult] {
            guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
            return re.matches(in: raw, range: NSRange(location: 0, length: len))
        }

        // 1. Labeled link: [[url][label]]
        for m in matches(pattern: #"\[\[([^\]\[]+)\]\[([^\]\[]+)\]\]"#) {
            guard isFree(m.range) else { continue }
            let url   = ns.substring(with: m.range(at: 1))
            let label = ns.substring(with: m.range(at: 2))
            claim(m.range, .link(text: label, url: url))
        }

        // 2. Bare org link: [[url]]
        for m in matches(pattern: #"\[\[([^\]\[]+)\]\]"#) {
            guard isFree(m.range) else { continue }
            let url = ns.substring(with: m.range(at: 1))
            claim(m.range, .link(text: url, url: url))
        }

        // 3. Bare URL (http/https) with G19 trailing-punctuation trim.
        // Slashes excluded from the trim set so trailing "/" is preserved.
        for m in matches(pattern: #"(?<![\w/])(https?://[^\s<>\])]+)"#) {
            guard isFree(m.range) else { continue }
            var url = ns.substring(with: m.range(at: 1))
            let trailingPunct = CharacterSet(charactersIn: ".,;:!?\")}]>")
            let trimmed = url.reversed().prefix(while: {
                $0.unicodeScalars.first.map { trailingPunct.contains($0) } ?? false
            })
            let suffix = String(trimmed.reversed())
            if !suffix.isEmpty { url = String(url.dropLast(suffix.count)) }
            claim(m.range, .bareURL(url: url, suffix: suffix))
        }

        // 4. Timestamps: <YYYY-MM-DD ...> and [YYYY-MM-DD ...]
        let tsPattern = #"[<\[](\d{4}-\d{2}-\d{2}(?:\s+[A-Za-z]{3})?(?:\s+\d{1,2}:\d{2}(?:-\d{1,2}:\d{2})?)?(?:\s+[+.]\d+[hdwmy])?)[>\]]"#
        for m in matches(pattern: tsPattern) {
            guard isFree(m.range) else { continue }
            let inner = ns.substring(with: m.range(at: 1))
            let open = ns.substring(with: NSRange(location: m.range.location, length: 1))
            let isInactive = (open == "[")
            let display = formatTimestamp(inner)
            claim(m.range, .timestamp(display: display, isInactive: isInactive))
        }

        // 5. Verbatim =…= and code ~…~ (no skipProcessed guard needed — plain
        // text can't have been claimed yet at this point).
        for m in matches(pattern: emphasisPattern("=", excluding: "=")) {
            guard isFree(m.range) else { continue }
            claim(m.range, .verbatim(ns.substring(with: m.range(at: 1))))
        }
        for m in matches(pattern: emphasisPattern("~", excluding: "~")) {
            guard isFree(m.range) else { continue }
            claim(m.range, .code(ns.substring(with: m.range(at: 1))))
        }

        // 6–9. Emphasis markers. Each skips ranges already claimed (= skipProcessed).
        for m in matches(pattern: emphasisPattern("\\*", excluding: "*")) {
            guard isFree(m.range) else { continue }
            claim(m.range, .bold(ns.substring(with: m.range(at: 1))))
        }
        for m in matches(pattern: emphasisPattern("/", excluding: "/")) {
            guard isFree(m.range) else { continue }
            claim(m.range, .italic(ns.substring(with: m.range(at: 1))))
        }
        for m in matches(pattern: emphasisPattern("_", excluding: "_")) {
            guard isFree(m.range) else { continue }
            claim(m.range, .underline(ns.substring(with: m.range(at: 1))))
        }
        for m in matches(pattern: emphasisPattern("\\+", excluding: "+")) {
            guard isFree(m.range) else { continue }
            claim(m.range, .strikethrough(ns.substring(with: m.range(at: 1))))
        }

        // Build output: walk the string left-to-right, emitting .plain for
        // unclaimed regions and the typed run for claimed ones.
        var result: [InlineRun] = []
        let sorted = found.sorted { $0.0.location < $1.0.location }
        var plainStart = 0
        for (range, run) in sorted {
            if range.location > plainStart {
                let plainRange = NSRange(location: plainStart, length: range.location - plainStart)
                let plainText = ns.substring(with: plainRange)
                if !plainText.isEmpty { result.append(.plain(plainText)) }
            }
            result.append(run)
            plainStart = range.location + range.length
        }
        // Tail plain text (also handles the all-plain case when found is empty).
        if plainStart < len {
            let tail = ns.substring(with: NSRange(location: plainStart, length: len - plainStart))
            if !tail.isEmpty { result.append(.plain(tail)) }
        }
        return result
    }

    // MARK: - Shared helpers

    /// Org emphasis-regexp-components boundary rules.
    /// Pre:  start-of-string OR one of [\s('"{]
    /// Body: \S (?: [^marker\n]* \S)?
    /// Post: end-of-string OR one of [\s\-.,:;!?'")\}\[\\]
    static func emphasisPattern(_ escapedMarker: String, excluding bodyExcluded: String) -> String {
        let bodyChar = NSRegularExpression.escapedPattern(for: bodyExcluded)
        return #"(?:^|(?<=[\s('"{]))"# +
               escapedMarker +
               "(\\S(?:[^" + bodyChar + "\\n]*\\S)?)" +
               escapedMarker +
               #"(?=$|[\s\-.,:;!?'")}\[\\])"#
    }

    /// Format the inner content of an org timestamp for display.
    /// inner: "2026-04-19" / "2026-04-19 Sun" / "2026-04-19 Sun 13:00"
    static func formatTimestamp(_ inner: String) -> String {
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
        case 0:  dayLabel = "Today"
        case 1:  dayLabel = "Tomorrow"
        case -1: dayLabel = "Yesterday"
        case 2...6:
            let fmt = DateFormatter(); fmt.dateFormat = "EEEE"
            dayLabel = fmt.string(from: date)
        default:
            let fmt = DateFormatter(); fmt.dateFormat = "MMM d"
            dayLabel = fmt.string(from: date)
        }

        let timeFragment = parts.dropFirst().first(where: { $0.contains(":") })
        if let t = timeFragment { return "\(dayLabel) \(t)" }
        return dayLabel
    }
}
