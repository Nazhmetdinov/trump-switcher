import Foundation

/// Resolve a small range before a collapsed caret, without page-global offsets.
/// Every step must remain in the same editable container. No text is read here.
public enum MarkerSelection {
    /// Use only a field's already-selected endpoints for an explicit phrase.
    /// The platform adapter must additionally confirm the marker-range string
    /// and re-read this exact numeric selection immediately before mutation.
    public static func selectedRange<Marker>(start: Marker, end: Marker, selection: NSRange, target: NSRange,
                                             allowed: (Marker) -> Bool, same: (Marker, Marker) -> Bool,
                                             limit: Int = 4096) -> (Marker, Marker)? {
        guard selection == target, target.location != NSNotFound, target.location >= 0,
              target.length > 0, target.length <= limit, target.location <= Int.max - target.length,
              !same(start, end), allowed(start), allowed(end) else { return nil }
        return (start, end)
    }

    public static func range<Marker>(caret: Marker, cursor: Int, target: NSRange,
                                     previous: (Marker) -> Marker?, allowed: (Marker) -> Bool,
                                     same: (Marker, Marker) -> Bool, limit: Int = 128) -> (Marker, Marker)? {
        guard target.location >= 0, target.length > 0, cursor >= target.location,
              target.length <= cursor - target.location,
              cursor - target.location <= limit, allowed(caret) else { return nil }
        var current = caret
        let trailing = cursor - target.location - target.length
        var end = caret
        for offset in 0..<(cursor - target.location) {
            guard let next = previous(current), !same(current, next), allowed(next) else { return nil }
            current = next
            if offset + 1 == trailing { end = current }
        }
        return (current, end)
    }
}
