import Foundation

/// Character-for-character normalization only; no invented letters or word
/// segmentation. A correction uses a typeable ASCII hyphen. Untouched source
/// text, including correctly spelled typographic compounds, is never rewritten.
public enum LexicalNormalization {
    public static let hyphenCharacters = Set<Character>("-‐‑")
    public static func hyphens(_ word: String) -> String {
        guard word.contains("‐") || word.contains("‑") else { return word }
        return String(word.map { hyphenCharacters.contains($0) ? "-" : $0 })
    }
    public static func exclusionKey(_ word: String) -> String {
        hyphens(word).precomposedStringWithCanonicalMapping.folding(options: .caseInsensitive,
            locale: Locale(identifier: "en_US_POSIX"))
    }
}

/// Compiled user settings, not an input cache. Built on settings changes so a
/// long exclusion list is never linearly scanned for each punctuation variant.
public struct CompiledExclusions {
    private let words: Set<String>
    public init(_ words: [String]) { self.words = Set(words.map(LexicalNormalization.exclusionKey)) }
    public func contains(_ word: String) -> Bool {
        !words.isEmpty && words.contains(LexicalNormalization.exclusionKey(word))
    }
}
