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
    private struct Node {
        var edges: [UInt32: Int] = [:]
        var failure = 0
        var contains = false
        var prefix = false
    }
    private var nodes = [Node()]
    public init(_ words: [String], rules: [WordExclusionRule] = []) {
        let rules = rules.filter(\.valid)
        self.words = Set((words + rules.filter { $0.match == .exact }.map(\.text)).map(LexicalNormalization.exclusionKey))
        for rule in rules where rule.match != .exact {
            var state = 0
            for scalar in LexicalNormalization.exclusionKey(rule.text).unicodeScalars {
                if let next = nodes[state].edges[scalar.value] { state = next }
                else {
                    let next = nodes.count
                    nodes[state].edges[scalar.value] = next
                    nodes.append(Node()); state = next
                }
            }
            if rule.match == .prefix { nodes[state].prefix = true }
            else { nodes[state].contains = true }
        }
        // Aho–Corasick failure links: substring search is linear in token length,
        // instead of scanning every user pattern on every punctuation variant.
        var queue = Array(nodes[0].edges.values), head = 0
        while head < queue.count {
            let parent = queue[head]; head += 1
            for (scalar, child) in nodes[parent].edges {
                var fallback = nodes[parent].failure
                while fallback != 0 && nodes[fallback].edges[scalar] == nil { fallback = nodes[fallback].failure }
                let failure = nodes[fallback].edges[scalar] ?? 0
                nodes[child].failure = failure
                nodes[child].contains = nodes[child].contains || nodes[failure].contains
                queue.append(child)
            }
        }
    }
    public func contains(_ word: String) -> Bool {
        guard !words.isEmpty || nodes.count > 1 else { return false }
        let normalized = LexicalNormalization.exclusionKey(word)
        if words.contains(normalized) { return true }
        guard nodes.count > 1 else { return false }
        var state = 0, prefixState: Int? = 0
        for scalar in normalized.unicodeScalars {
            if let prefix = prefixState {
                prefixState = nodes[prefix].edges[scalar.value]
                if let prefix = prefixState, nodes[prefix].prefix { return true }
            }
            while state != 0 && nodes[state].edges[scalar.value] == nil { state = nodes[state].failure }
            state = nodes[state].edges[scalar.value] ?? 0
            if nodes[state].contains { return true }
        }
        return false
    }
}
