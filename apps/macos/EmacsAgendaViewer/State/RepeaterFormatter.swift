import Foundation

/// Short human label for an `OrgTimestamp.Repeater` — e.g. "1w", "2mo".
/// Single-character org units (`d`, `w`, `m`, `y`) widen `m` to `mo` so
/// "1m" doesn't read as "1 minute". Returns nil for missing or zero values.
enum RepeaterFormatter {
    static func label(_ r: OrgTimestamp.Repeater?) -> String? {
        guard let r, r.value > 0 else { return nil }
        let unit = r.unit == "m" ? "mo" : r.unit
        return "\(r.value)\(unit)"
    }
}
