import Foundation
import SwitcherCore

/// Exercise curated spelling additions through the same physical-layout
/// conversion and recognizer path used for regular words. No editor or user
/// input is touched by these checks.
func supplementalVocabularyChecks(dictionary: LocalDictionary) -> Int {
    let russianWords = [
        "автозаменами", "фронтендов", "патчем", "нейронкой",
        "промптинг", "промптинга", "промптинге",
        "тапать", "тапнул", "тапнула", "тапнули",
        "дизлайка", "гуглил", "гуглила", "гуглили", "загуглил",
        "телеграмов", "суперапп", "супераппа", "супераппы", "супераппов",
        "нейроагент", "нейроагента", "нейроагенты", "нейроагентов",
        "мультиагент", "мультиагента", "мультиагенты",
        "скроллит", "скроллил", "скроллила", "скроллили", "заскринить"
    ]
    let englishWords = [
        "autocorrection", "autocorrections", "autocompletions",
        "sidepanel", "sidepanels", "worktree", "worktrees",
        "agentic", "codegen", "codemod", "codemods", "devtools",
        "cloudflare", "vercel", "dockerize", "dockerized", "dockerizing"
    ]
    var checks = 0
    func expect(_ condition: @autoclosure () -> Bool, _ description: String) {
        guard condition() else {
            fputs("Supplemental dictionary regression: \(description)\n", stderr)
            exit(1)
        }
        checks += 1
    }
    guard let abc = KeyboardLayoutTable(id: "com.apple.keylayout.ABC") else {
        fputs("Supplemental dictionary regression: ABC layout unavailable\n", stderr)
        exit(1)
    }
    for russianID in ["com.apple.keylayout.Russian", "com.apple.keylayout.RussianWin"] {
        guard let russian = KeyboardLayoutTable(id: russianID) else {
            fputs("Supplemental dictionary regression: \(russianID) unavailable\n", stderr)
            exit(1)
        }
        let convert: (String, Layout) -> String = { text, target in
            target == .russian ? abc.convert(text, to: russian) : russian.convert(text, to: abc)
        }
        func detected(_ token: String) -> String? {
            AutoCorrection.detect(token, recognizes: dictionary.recognizes,
                recognizesFragment: dictionary.recognizesCommon, convert: convert)?.text
        }
        for (words, target, correct, wrong) in [
            (russianWords, Layout.russian, russian, abc),
            (englishWords, Layout.english, abc, russian)
        ] {
            for word in words {
                expect(dictionary.recognizes(word, target), "recognizes \(word) on \(russianID)")
                let mistyped = correct.convert(word, to: wrong)
                expect(mistyped != word && mistyped.allSatisfy(\.isLetter),
                       "\(word) has a complete letter-only wrong-layout form on \(russianID)")
                expect(detected(mistyped) == word, "converts \(mistyped) to \(word) on \(russianID)")
                expect(detected(word) == nil, "preserves correctly typed \(word) on \(russianID)")
                // An unambiguous sentence-ending marker must remain literal.
                expect(detected(mistyped + "!") == word + "!",
                       "preserves exclamation after \(word) on \(russianID)")
            }
        }
    }
    print("Passed \(checks) curated dictionary and physical-layout regressions")
    return checks
}
