import Foundation

// Adapted from RuSwitcher ShortWords.swift (MIT), revision
// 436061c7fe7839ea52b1a5b4776c13611a868ddb.
// Copyright (c) 2025 Rashns. Full notice: Dictionaries/Licenses/RuSwitcher/LICENSE.
// Protect uppercase abbreviations, or lowercase tokens inside an established
// English context. Unconditional lowercase protection blocked ordinary Russian
// function words: bp = из, ds = вы, vs = мы. No previous text is retained.
enum ShortSourceProtection {
    private static let english: Set<String> = ["vs", "dj", "kb", "jr", "bp", "ye", "ds"]

    static func recognizes(_ word: String, _ layout: Layout, establishedLanguage: Layout?) -> Bool {
        layout == .english && (word == word.uppercased() || establishedLanguage == .english) &&
            english.contains(word.lowercased())
    }
}
