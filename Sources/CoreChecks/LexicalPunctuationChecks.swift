import Foundation
import SwitcherCore

/// Focused public-text regressions, using packaged dictionaries and immutable
/// Apple keyboard tables only. No events, AX, source selection or user text.
func lexicalPunctuationChecks(dictionary: LocalDictionary) -> Int {
    var checks = 0, failures = 0
    func expect(_ actual: String?, _ expected: String?, _ reason: String) {
        checks += 1
        if actual != expected {
            failures += 1
            print("Lexical punctuation regression: \(reason): actual=\(actual.debugDescription), expected=\(expected.debugDescription)")
        }
    }
    let english = KeyboardLayoutTable(id: "com.apple.keylayout.ABC")!
    for id in ["com.apple.keylayout.Russian", "com.apple.keylayout.RussianWin"] {
        let russian = KeyboardLayoutTable(id: id)!
        let convert: (String, Layout) -> String = { text, target in
            target == .russian ? english.convert(text, to: russian) : russian.convert(text, to: english)
        }
        func detect(_ text: String, settings: CorrectionSettings = CorrectionSettings()) -> String? {
            AutoCorrection.detect(text, recognizes: dictionary.recognizes,
                recognizesFragment: dictionary.recognizesCommon, settings: settings, convert: convert)?.text
        }
        // A real inflection (конечною) must not consume one literal ellipsis dot.
        for (input, expected) in [("rjytxyj...", "конечно..."), ("(rjytxyj)...", "(конечно)..."),
                                  ("кjytxyj...", "конечно..."), ("нt...", "не..."),
                                  ("приdtт?", "привет?"), ("приdtт?!", "привет?!"),
                                  ("'nj...", "это..."), ("'nj?!", "это?!")] {
            expect(detect(input), expected, id + " literal punctuation " + input)
        }
        // These physical words contain no alphabetic glyph in the wrong layout.
        for word in ["эх", "ёж"] {
            for (prefix, suffix) in [("", ""), ("", "!"), ("", "."), ("(", ")"), ("«", "»"), ("", "—")] {
                let expected = prefix + word + suffix
                expect(detect(russian.convert(expected, to: english)), expected,
                       id + " punctuation-key word " + expected)
            }
        }
        for original in ["конечно...", "конечною...", "[не]", "как-то", "hello-мир", "Google-Яндекс",
                         "hello_world", "приdtт123", "янdex.ru", "https://example.com/rjytxyj...", "[]", "?!"] {
            expect(detect(original), nil, id + " preserve complete text " + original)
        }
        // One side of a real compound may be typed after a manual layout switch.
        // The complete spelling, rather than independently known pieces, is evidence.
        for (input, expected) in [("rfr-то", "как-то"), ("как-nj", "как-то"), ("(rfr-то)", "(как-то)"),
                                  ("из-pf", "из-за"), ("bp-за", "из-за"), ("всё-nfrb", "всё-таки"),
                                  ("цудд-known", "well-known"), ("well-лтщцт", "well-known"),
                                  ("зфке-time", "part-time")] {
            expect(detect(input), expected, id + " exact mixed compound " + input)
        }
        for original in ["rfr--то", "-rfr-то", "rfr-то-", "rfr-то123", "rfr_то", "rfr/то", "rfr-то.com",
                         "ghbdtn-мир", "hello-цщкдв", "ghbdtn-мир-друг", "как-то-кто-то", "rfr-\nто"] {
            expect(detect(original), nil, id + " compound syntax/unknown combinations kept " + original)
        }
        // A competing complete word still blocks the punctuation preference.
        expect(detect("levf."), nil, id + " дума./думаю remains ambiguous")
        for input in ["dfkthb.!", "(dfkthb.)", "«dfkthb.»", "dfkthb.?", "dfkthb..!"] {
            expect(detect(input), nil, id + " punctuation must not truncate Валерию: " + input)
        }
        var disabled = CorrectionSettings(); disabled.punctuation = false
        expect(detect("('[)", settings: disabled), nil, id + " punctuation setting remains effective")
        expect(detect("rfr-то", settings: disabled), nil, id + " compound punctuation setting remains effective")
        disabled = CorrectionSettings(); disabled.shortWords = false
        expect(detect("'[!", settings: disabled), nil, id + " short-word setting remains effective")
        disabled = CorrectionSettings(); disabled.toRussian = false
        expect(detect("'[!", settings: disabled), nil, id + " direction setting remains effective")
        disabled = CorrectionSettings(); disabled.excludedWords = ["rjytxyj"]
        expect(detect("rjytxyj...", settings: disabled), nil, id + " exclusion remains effective")
        // Capitals are policy-controlled independently of punctuation recovery.
        let capitals = russian.convert("ЭХ!", to: english)
        expect(detect(capitals), nil, id + " all-caps off")
        var enabled = CorrectionSettings(); enabled.allowAllCaps = true
        expect(detect(capitals, settings: enabled), "ЭХ!", id + " all-caps on")
    }
    guard failures == 0 else { fputs("\(failures)/\(checks) lexical punctuation checks failed\n", stderr); exit(1) }
    print("Passed \(checks) lexical punctuation regressions")
    return checks
}
