import Foundation

// Parses a CaptureTemplate's raw text to pre-fill the capture form UI.
// Submission uses the daemon path (client.captureTask) — org-capture in Emacs.

struct ParsedTemplate {
    var todoState: String?
    var priority: String?
    var titlePattern: String = "%?"
    var tags: [String] = []
    var scheduledInBody: Bool = false
    var deadlineInBody: Bool = false
}

enum TemplateParser {
    static func parse(_ tpl: CaptureTemplate, keywords: TodoKeywords?) -> ParsedTemplate {
        var result = ParsedTemplate()

        guard let raw = tpl.template,
              let heading = raw.components(separatedBy: "\n").first else { return result }

        let entryType = tpl.type ?? "entry"
        if entryType == "entry" {
            parseHeadingLine(heading, into: &result, keywords: keywords)
        } else {
            result.titlePattern = heading
        }

        for line in raw.components(separatedBy: "\n").dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("SCHEDULED:") { result.scheduledInBody = true }
            else if trimmed.hasPrefix("DEADLINE:") { result.deadlineInBody = true }
        }

        return result
    }

    private static func parseHeadingLine(_ line: String, into result: inout ParsedTemplate, keywords: TodoKeywords?) {
        var remaining = line[line.startIndex...]

        // Stars
        let stars = remaining.prefix(while: { $0 == "*" })
        if !stars.isEmpty {
            remaining = remaining.dropFirst(stars.count)
            remaining = remaining.drop(while: { $0 == " " })
        }

        // Tags at end: :tag1:tag2:
        if let tagRange = remaining.range(of: #"\s+(:[a-zA-Z0-9_@#%:]+:)\s*$"#, options: .regularExpression) {
            let tagStr = String(remaining[tagRange]).trimmingCharacters(in: .whitespaces)
            result.tags = tagStr.split(separator: ":").map(String.init).filter { !$0.isEmpty }
            remaining = remaining[remaining.startIndex..<tagRange.lowerBound]
        }

        let rest = String(remaining)
        let allKeywords = (keywords?.allActive ?? ["TODO"]) + (keywords?.allDone ?? ["DONE"])

        // TODO state
        for kw in allKeywords {
            if rest.hasPrefix(kw + " ") || rest.hasPrefix(kw + "\t") || rest == kw {
                result.todoState = kw
                remaining = remaining.dropFirst(kw.count)
                remaining = remaining.drop(while: { $0 == " " })
                break
            }
        }

        // Priority [#X]
        let priStr = String(remaining)
        if let match = priStr.range(of: #"^\[#([A-Z])\]\s*"#, options: .regularExpression) {
            let inner = priStr[priStr.index(priStr.startIndex, offsetBy: 2)..<priStr.index(priStr.startIndex, offsetBy: 3)]
            result.priority = String(inner)
            remaining = remaining.dropFirst(priStr.distance(from: priStr.startIndex, to: match.upperBound))
        }

        result.titlePattern = String(remaining)
    }
}
