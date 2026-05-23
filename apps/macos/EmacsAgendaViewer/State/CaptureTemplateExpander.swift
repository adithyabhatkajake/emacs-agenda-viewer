import Foundation

// Regex matching any %^ directive in org-capture templates.
// Group 1 (optional) captures the {label} portion; its presence
// is the sole criterion for whether this directive is a user prompt.
private let captureDirectivePattern = #"%\^(?:\{[^}]*\})?[gGtTuUpCL]?"#

// MARK: - Public surface (internal)

/// Returns the substituted form of `line` using the supplied prompt answers.
/// Only `%^{label}` directives consume a slot from `promptAnswers`;
/// bare passthrough directives (`%^p`, `%^g`, `%^G`, `%^t`, `%^T`,
/// `%^u`, `%^U`, `%^C`, `%^L`) leave the `promptIdx` unchanged.
func expandCaptureDirectives(
    in line: String,
    promptAnswers: [String],
    orgTimestampActive: (Bool, Bool) -> String
) -> String {
    var result = line
    var promptIdx = 0

    while let range = result.range(of: captureDirectivePattern, options: .regularExpression) {
        let match = String(result[range])
        let isBracedPrompt = match.contains("{")

        if isBracedPrompt {
            let answer = promptIdx < promptAnswers.count ? promptAnswers[promptIdx] : ""
            promptIdx += 1
            result = result.replacingCharacters(in: range, with: answer)
        } else if match.hasSuffix("t") || match.hasSuffix("T") {
            let ts = orgTimestampActive(true, false)
            result = result.replacingCharacters(in: range, with: ts)
        } else if match.hasSuffix("u") || match.hasSuffix("U") {
            let ts = orgTimestampActive(false, false)
            result = result.replacingCharacters(in: range, with: ts)
        } else {
            // %^p, %^g, %^G, %^C, %^L — passthrough, replace with empty
            result = result.replacingCharacters(in: range, with: "")
        }
    }

    return result
}
