import Foundation

/// A read-only receipt for the replaced span. Following typing is allowed, but
/// neither a moved-back caret nor a selection can authorize an observation.
/// This plan never grants permission to write or to repair a mismatch.
public struct ReplacementObservation {
    public let range: NSRange
    public let expected: String
    public init?(start: Int, replacement: String, boundary: String) {
        let expected = replacement + boundary
        guard start >= 0, start != NSNotFound, (1...129).contains(expected.utf16.count),
              start <= Int.max - expected.utf16.count else { return nil }
        range = NSRange(location: start, length: expected.utf16.count)
        self.expected = expected
    }
    public func permits(caret: NSRange) -> Bool {
        guard caret.location != NSNotFound, caret.length == 0 else { return false }
        let end = NSMaxRange(range)
        return caret.location >= end && caret.location - end <= 128
    }
    public func confirms(_ actual: String, caret: NSRange) -> Bool {
        permits(caret: caret) && actual == expected
    }
}
