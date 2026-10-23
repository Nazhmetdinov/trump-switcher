import Foundation

/// Filter for supplementary dictionary entries, learned solely from packaged
/// common words. It never invents a word and never learns from user input.
/// Huge spelling dictionaries also contain acronyms and rare proper names;
/// treating every one as ordinary lowercase text blocks real corrections.
public struct LexicalShape {
    private var pairs = Set<UInt64>()
    private var triples = Set<UInt64>()
    private var pairSupport: [UInt64: Int] = [:]
    private var tripleSupport: [UInt64: Int] = [:]
    private var starts: [UInt64: Int] = [:]
    private var ends: [UInt64: Int] = [:]
    private static func pair(_ a: UInt32, _ b: UInt32) -> UInt64 { UInt64(a) << 32 | UInt64(b) }
    private static func triple(_ a: UInt32, _ b: UInt32, _ c: UInt32) -> UInt64 { UInt64(a) << 42 | UInt64(b) << 21 | UInt64(c) }
    public init(words: Set<String>) {
        for word in words {
            let letters = word.unicodeScalars.map(\.value)
            guard letters.count >= 3 else { continue }
            starts[Self.pair(letters[0], letters[1]), default: 0] += 1
            ends[Self.pair(letters[letters.count - 2], letters[letters.count - 1]), default: 0] += 1
            for i in 1..<letters.count { pairs.insert(Self.pair(letters[i - 1], letters[i])) }
            for i in 2..<letters.count { triples.insert(Self.triple(letters[i - 2], letters[i - 1], letters[i])) }
            // Count independent spellings, not repeated syllables in one word.
            for key in Set((1..<letters.count).map { Self.pair(letters[$0 - 1], letters[$0]) }) {
                pairSupport[key, default: 0] += 1
            }
            for key in Set((2..<letters.count).map { Self.triple(letters[$0 - 2], letters[$0 - 1], letters[$0]) }) {
                tripleSupport[key, default: 0] += 1
            }
        }
    }
    public func permits(_ word: String) -> Bool {
        let letters = word.unicodeScalars.map(\.value)
        guard letters.count >= 3,
              starts[Self.pair(letters[0], letters[1]), default: 0] >= 2,
              ends[Self.pair(letters[letters.count - 2], letters[letters.count - 1]), default: 0] >= 2 else { return false }
        return (1..<letters.count).allSatisfy { pairs.contains(Self.pair(letters[$0 - 1], letters[$0])) } &&
            (2..<letters.count).allSatisfy { triples.contains(Self.triple(letters[$0 - 2], letters[$0 - 1], letters[$0])) }
    }

    /// Back off from one unseen trigram to well-supported adjacent bigrams.
    /// This is evidence for a supplementary *dictionary lookup*, never a word
    /// recognizer on its own. Short tokens, punctuation, multiple unsupported
    /// combinations and weak beginnings/endings cannot use this path.
    public func permitsBackoff(_ word: String) -> Bool {
        let letters = word.unicodeScalars.map(\.value)
        guard (8...48).contains(letters.count), word.allSatisfy(\.isLetter),
              starts[Self.pair(letters[0], letters[1]), default: 0] >= 3,
              ends[Self.pair(letters[letters.count - 2], letters[letters.count - 1]), default: 0] >= 3,
              (1..<letters.count).allSatisfy({ pairSupport[Self.pair(letters[$0 - 1], letters[$0]), default: 0] >= 5 }) else { return false }
        var unseen = 0
        for i in 2..<letters.count {
            let support = tripleSupport[Self.triple(letters[i - 2], letters[i - 1], letters[i]), default: 0]
            if support == 0 { unseen += 1; if unseen > 1 { return false } }
            else if support < 3 { return false }
        }
        return unseen == 1
    }
}
