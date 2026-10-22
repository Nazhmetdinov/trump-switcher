import Foundation

// Adapted from RuSwitcher ShortWords.swift (MIT), revision
// 436061c7fe7839ea52b1a5b4776c13611a868ddb.
// Copyright (c) 2025 Rashns. Full notice: Dictionaries/Licenses/RuSwitcher/LICENSE.
// These spellings protect the source only: they do not expand the set of
// short target words eligible for automatic correction.
enum ShortSourceProtection {
    private static let english: Set<String> = ["vs", "dj", "kb", "jr", "bp", "ye", "ds"]

    static func recognizes(_ word: String, _ layout: Layout) -> Bool {
        layout == .english && english.contains(word.lowercased())
    }
}
