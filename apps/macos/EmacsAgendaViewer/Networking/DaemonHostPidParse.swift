#if os(macOS)
import Foundation

/// Extracts an `Int32` pid from a JSON-deserialized value.
///
/// `JSONSerialization` always boxes numbers as `NSNumber`, so a plain
/// `as? Int32` or `as? Int` conditional cast succeeds only when the
/// Swift bridging happens to match the concrete NSNumber subtype.
/// This helper accepts any `NSNumber`-compatible numeric value and rejects
/// non-numeric types (e.g. a pid encoded as a string).
func parsePid(from value: Any?) -> Int32? {
    guard let n = value as? NSNumber else { return nil }
    let v = n.int64Value
    guard v > 0, v <= Int64(Int32.max) else { return nil }
    return Int32(v)
}
#endif
