import Foundation
import SwitcherCore

func editorCapitalizationChecks() -> Int {
    var count = 0
    func check(_ value: Bool, _ name: String) {
        guard value else { fatalError("FAILED: editor capitalization: \(name)") }
        count += 1
    }
    func adjust(_ original: String, _ replacement: String, _ before: String,
                after: String? = nil, selection: Int = 0) -> EditorCapitalizationAdjustment? {
        EditorCapitalizationAdjustment.verified(original: original, replacement: replacement,
            beforeCaret: before, afterCaret: after, selectionLength: selection)
    }
    for (original, replacement, observed, expected) in [
        ("ghbdtn", "привет", "Ghbdtn", "Привет"),
        ("lkz", "для", "Lkz", "Для"),
        ("b[", "их", "B[", "Их"),
        ("b", "и", "B", "И"),
        ("d", "в", "D", "В"),
        ("руддщ", "hello", "Руддщ", "Hello"),
        ("ёж", "test", "Ёж", "Test"),
        ("ghbdtn", "Привет", "Ghbdtn", "Привет"),
        ("ghbdtn", "ПРИВЕТ", "Ghbdtn", "ПРИВЕТ")
    ] {
        let result = adjust(original, replacement, observed)
        check(result?.actualOriginal == observed && result?.replacement == expected,
              "preserve one verified uppercase letter: \(original)")
        check(result?.actualOriginal.utf16.count == original.utf16.count &&
              result?.replacement.utf16.count == replacement.utf16.count,
              "UTF-16 lengths stay exact: \(original)")
    }
    check(adjust("lkz", "для", "prefix Lkz", after: " ")?.replacement == "Для", "existing document prefix")
    check(adjust("lkz", "для", "(Lkz", after: ")")?.replacement == "Для", "punctuation boundaries")
    check(adjust("ghbdtn!", "привет!", "Ghbdtn!", after: "\n")?.replacement == "Привет!", "literal punctuation retained")
    check(adjust("lkz", "для", "Lkz", after: nil)?.replacement == "Для", "no suffix attribute retains existing preflight contract")
    check(adjust("lkz", "для", "Lkz", after: "_") == nil, "identifier suffix rejected")
    check(adjust("lkz", "для", "Lkz", after: "x") == nil, "word suffix rejected")
    check(adjust("lkz", "для", "Lkz", after: "2") == nil, "numeric suffix rejected")
    check(adjust("lkz", "для", "xLkz") == nil, "word prefix rejected")
    check(adjust("lkz", "для", "_Lkz") == nil, "identifier prefix rejected")
    check(adjust("lkz", "для", "Lkz", selection: 1) == nil, "noncollapsed selection rejected")
    check(adjust("lkz", "для", "Lkz", selection: -1) == nil, "invalid selection rejected")
    check(adjust("lkz", "для", "Lxy") == nil, "different word rejected")
    check(adjust("lkz", "для", "LKZ") == nil, "all-caps editor change rejected")
    check(adjust("lkz", "для", "LkZ") == nil, "second case change rejected")
    check(adjust("Lkz", "Для", "Lkz") == nil, "already title-case physical input is not an adjustment")
    check(adjust("LKZ", "ДЛЯ", "LKZ") == nil, "already all-caps physical input rejected")
    check(adjust("lkz", "для", "lkz") == nil, "unchanged source uses normal exact preflight")
    check(adjust("lkz", "для", "Lkzz") == nil, "different source length rejected")
    check(adjust("lkz", "для", "Lk") == nil, "partial source is not permission to replace")
    check(adjust("ßeta", "слово", "SSeta") == nil, "case-fold expansion rejected")
    check(adjust("éclair", "слово", "Éclair") == nil, "non-EN/RU initial rejected")
    check(adjust("a\u{301}bc", "слово", "A\u{301}bc") == nil, "combining initial rejected")
    check(adjust("🙂lkz", "для", "🙂Lkz") == nil, "non-BMP initial rejected")
    check(adjust("1lkz", "для", "1Lkz") == nil, "later letter is not an initial adjustment")
    check(adjust("lkz", "", "Lkz") == nil, "empty output rejected")
    check(adjust("", "для", "") == nil, "empty source rejected")
    check(adjust("lkz", "ßeta", "Lkz") == nil, "expanding output case mapping rejected")
    check(adjust("lkz", "🙂", "Lkz") == nil, "nonletter output rejected")
    let tooLong = String(repeating: "a", count: 129)
    check(adjust(tooLong, "слово", "A" + tooLong.dropFirst()) == nil, "bounded source read")
    check(adjust("lkz", tooLong, "Lkz") == nil, "bounded output")
    check(EditorCapitalizationAdjustment.verifiedOriginal(original: "b[", beforeCaret: "B[",
        afterCaret: nil, selectionLength: 0) == "B[", "source-only preflight interface")
    return count
}
