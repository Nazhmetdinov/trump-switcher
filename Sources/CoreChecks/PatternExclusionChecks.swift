import Foundation
import SwitcherCore

func patternExclusionChecks() -> Int {
    var count = 0
    func expect(_ condition: Bool, _ message: String) {
        guard condition else { fatalError("Pattern exclusion: \(message)") }
        count += 1
    }
    let ruleSets: [[WordExclusionRule]] = [
        [.init("ab", match: .prefix)], [.init("ab", match: .contains)], [.init("ab", match: .exact)],
        [.init("ab", match: .prefix), .init("bab", match: .contains), .init("cc", match: .exact)],
        [.init("abac", match: .contains), .init("bac", match: .prefix), .init("ca", match: .contains)],
        [.init("aaaaab", match: .contains), .init("aab", match: .contains), .init("baa", match: .prefix)]
    ]
    var words = [""], level = [""]
    for _ in 1...7 { level = level.flatMap { prefix in ["a", "b", "c"].map { prefix + $0 } }; words += level }
    for rules in ruleSets {
        let compiled = CompiledExclusions(["literal*"], rules: rules)
        for word in words {
            // Independent reference, without automaton states/failure links.
            let expected = rules.contains { rule in
                switch rule.match {
                case .exact: return word == rule.text
                case .prefix: return word.hasPrefix(rule.text)
                case .contains: return word.contains(rule.text)
                }
            }
            expect(compiled.contains(word) == expected, "overlapping and anchored matching: \(word)")
        }
    }
    let unicode = CompiledExclusions(["git*", "literal?"], rules: [
        .init("Нейро", match: .prefix), .init("Ёлк", match: .contains), .init("что-то", match: .prefix)])
    for word in ["НЕЙРОНКА", "нейросети", "съЁлкой", "елка-поёЛКам", "что‑тошнее", "что‐тошнее", "Е\u{308}лка", "git*", "literal?"] {
        expect(unicode.contains(word), "Unicode/case/literal compatibility: \(word)")
    }
    for word in ["антинейро", "ней", "gitlab", "literalx", "елка", "", "xчто-то"] {
        expect(!unicode.contains(word), "prefix is anchored; no glob or ё/е substitution: \(word)")
    }
    let overlapping = CompiledExclusions([], rules: [.init("hers", match: .contains), .init("she", match: .prefix), .init("he", match: .contains)])
    expect(overlapping.contains("ushers"), "failure link inherits suffix matches")
    expect(!CompiledExclusions([], rules: [.init("she", match: .prefix)]).contains("usher"), "prefix never leaks through a failure link")

    var settings = CorrectionSettings()
    let encoder = JSONEncoder()
    let legacyData = try! encoder.encode(settings)
    expect(!String(data: legacyData, encoding: .utf8)!.contains("wordExclusionRules"), "legacy format has no new key")
    expect(CorrectionSettings.decode(legacyData) == settings, "old settings load unchanged")
    settings.wordExclusionRules = [.init("нейро", match: .prefix), .init("cloud", match: .contains)]
    expect(CorrectionSettings.decode(try! encoder.encode(settings)) == settings, "typed rules survive export/import")
    let invalidMode = String(data: try! encoder.encode(settings), encoding: .utf8)!.replacingOccurrences(of: "\"prefix\"", with: "\"unknown-mode\"")
    expect(CorrectionSettings.decode(Data(invalidMode.utf8)) == nil, "unknown condition fails validation rather than changing its meaning")
    for rule in [WordExclusionRule("", match: .contains), .init("а", match: .prefix), .init("two words", match: .contains),
                 .init("abc\n", match: .prefix), .init(String(repeating: "x", count: 129), match: .exact)] {
        var bad = settings; bad.wordExclusionRules = [rule]
        expect(CorrectionSettings.decode(try! encoder.encode(bad)) == nil, "invalid pattern settings refused")
        expect(!CompiledExclusions([], rules: [rule]).contains("anything"), "invalid direct pattern never excludes everything")
    }
    var bad = settings; bad.wordExclusionRules = [.init("Нейро", match: .prefix), .init("нейро", match: .prefix)]
    expect(CorrectionSettings.decode(try! encoder.encode(bad)) == nil, "normalized duplicate refused")
    bad.wordExclusionRules = (0..<501).map { .init("pattern-\($0)-end", match: .contains) }
    expect(CorrectionSettings.decode(try! encoder.encode(bad)) == nil, "pattern count bounded")
    let maximum = Array(bad.wordExclusionRules!.prefix(500))
    bad.wordExclusionRules = maximum
    expect(CorrectionSettings.decode(try! encoder.encode(bad)) == bad, "maximum valid list survives storage")
    let large = CompiledExclusions([], rules: maximum)
    expect(large.contains("xxpattern-499-end-tail") && !large.contains(String(repeating: "a", count: 128)), "large list lookup reaches last rule")

    let known: (String, Layout) -> Bool = { word, layout in
        layout == .russian ? ["нейронка", "привет", "яндекс"].contains(word) : ["hello", "cloudflare"].contains(word)
    }
    func detect(_ text: String, _ config: CorrectionSettings) -> String? {
        AutoCorrection.detect(text, recognizes: known, settings: config)?.text
    }
    expect(detect("ytqhjyrf", CorrectionSettings()) == "нейронка", "fixture converts without exclusion")
    expect(detect("ytqhjyrf", settings) == nil, "intended prefix protects wrong-layout spelling")
    expect(detect("сдщгвадфку", settings) == nil, "intended substring protects RU to EN")
    expect(detect("(ytqhjyrf)", settings) == nil, "target wrapper excluded")
    expect(AutoCorrection.detect("ytqhjyrf", recognizes: known, settings: settings,
        exclusions: CompiledExclusions(settings.excludedWords, rules: settings.wordExclusionRules!)) == nil,
        "precompiled monitor settings enforce pattern rules")
    var ambiguous = CorrectionSettings(); ambiguous.wordExclusionRules = [.init("думаю", match: .prefix)]
    expect(AutoCorrection.detect("levf.", recognizes: { word, layout in layout == .russian && ["дума", "думаю"].contains(word) },
        settings: ambiguous) == nil, "excluding one competing candidate cannot authorize the other")
    settings.wordExclusionRules = [.init("ghb", match: .prefix)]
    settings.rules = [.init(input: "ghbdtn", output: "привет", russian: true)]
    expect(detect("ghbdtn", settings) == nil, "source pattern overrides explicit replacement")
    settings.wordExclusionRules = [.init("рив", match: .contains)]
    expect(detect("ghbdtn", settings) == nil, "target pattern overrides explicit replacement")
    settings.wordExclusionRules = nil
    expect(detect("ghbdtn", settings) == "привет", "removing pattern restores normal correction")
    print("Passed \(count) patterned exclusion checks")
    return count
}
