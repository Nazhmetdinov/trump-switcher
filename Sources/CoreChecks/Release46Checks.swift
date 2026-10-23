import Foundation
import SwitcherCore

func release46Checks(dictionary: LocalDictionary) -> Int {
    var count = 0
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fputs("Release 46: \(message)\n", stderr); exit(1) }
        count += 1
    }
    var retry = RetryBudget()
    expect(retry.begin(at: 100), "first browser preparation")
    expect(!retry.begin(at: 100.1), "no busy loop on focus hints")
    expect(retry.begin(at: 101) && retry.begin(at: 102), "three-attempt startup burst")
    expect(!retry.shouldRetrySoon && !retry.begin(at: 110), "cooldown after burst")
    expect(retry.begin(at: 117) && retry.shouldRetrySoon, "foreground preparation recovers after cooldown")
    expect(!retry.begin(at: 116) && !retry.begin(at: .infinity) && !retry.begin(at: .nan), "invalid clocks cannot create a retry storm")

    let receipt = ReplacementObservation(start: 12, replacement: "привет", boundary: " ")!
    expect(receipt.range == NSRange(location: 12, length: 7), "read exactly the replacement span")
    for tail in 0...128 {
        let caret = NSRange(location: 19 + tail, length: 0)
        expect(receipt.confirms("привет ", caret: caret), "continued typing does not cancel confirmation")
        expect(!receipt.confirms("приве ", caret: caret), "lost character cannot be confirmed")
    }
    for caret in [NSRange(location: 18, length: 0), NSRange(location: 19, length: 1),
                  NSRange(location: 148, length: 0), NSRange(location: NSNotFound, length: 0)] {
        expect(!receipt.permits(caret: caret), "selection/navigation/unbounded tail refused")
    }
    expect(ReplacementObservation(start: Int.max - 2, replacement: "hello", boundary: " ") == nil,
           "readback range cannot overflow")
    expect(ReplacementObservation(start: -1, replacement: "x", boundary: "") == nil, "negative observation offset refused")
    let compiled = CompiledExclusions((0..<4998).map { "fixture-\($0)" } + ["Нейроагентам", "что-то"])
    expect(compiled.contains("нейроагентам") && compiled.contains("ЧТО‑ТО"), "large compiled exclusion list retains case/hyphen semantics")
    expect(!compiled.contains("нейроагентами"), "exclusions remain exact words, not prefix rules")
    expect(AutoCorrection.detect("ytqhjfutynfv", recognizes: dictionary.recognizes,
        exclusions: compiled) == nil, "compiled target exclusion reaches the complete detector")

    // Pauses belong to the user, not to a timeout-based word splitter.
    for pause: TimeInterval in [0.03, 0.5, 2, 15, 120] {
        var buffer = TypingBuffer()
        for (index, char) in "ytqhjfutynfv".enumerated() {
            buffer.noteKey(at: Double(index) * pause); buffer.append(String(char))
        }
        expect(buffer.finishWord() == "ytqhjfutynfv", "pause of \(pause) seconds preserves the complete token")
    }

    let english = KeyboardLayoutTable(id: "com.apple.keylayout.ABC")!
    for id in ["com.apple.keylayout.Russian", "com.apple.keylayout.RussianWin"] {
        let russian = KeyboardLayoutTable(id: id)!
        let convert: (String, Layout) -> String = { value, target in
            target == .russian ? english.convert(value, to: russian) : russian.convert(value, to: english)
        }
        func detect(_ input: String, _ settings: CorrectionSettings = CorrectionSettings()) -> String? {
            AutoCorrection.detect(input, recognizes: dictionary.recognizes,
                recognizesFragment: dictionary.recognizesCommon, recognizesBackoff: dictionary.recognizesBackoff, settings: settings, convert: convert)?.text
        }
        for (target, words) in [(Layout.russian, ["видеосозвон", "видеосозвонами", "нейроагентам", "промптах", "пулреквестами"]),
                                (.english, ["timezones", "worktree's", "DevOps", "PowerShell", "eBPF"])] {
            for word in words {
                let input = target == .russian ? russian.convert(word, to: english) : english.convert(word, to: russian)
                expect(dictionary.recognizes(word, target), "reviewed complete spelling \(word)")
                expect(detect(input) == word, "complete conversion \(word) on \(id)")
                expect(detect(word) == nil, "correct spelling is preserved \(word)")
                var excluded = CorrectionSettings(); excluded.excludedWords = [word]
                expect(detect(input, excluded) == nil, "new vocabulary still respects target exclusions")
            }
        }
        for hyphen in ["-", "‐", "‑"] {
            expect(dictionary.recognizes("что" + hyphen + "то", .russian), "compound normalization")
            expect(detect("что" + hyphen + "то") == nil, "correct typographic hyphen is untouched")
            expect(detect("xnj" + hyphen + "nj") == "что-то", "typeable corrected compound")
            expect(detect("rfr" + hyphen + "то") == "как-то", "whole mixed-script compound")
            var excluded = CorrectionSettings(); excluded.excludedWords = ["что-то"]
            expect(detect("xnj" + hyphen + "nj", excluded) == nil, "normalized compound exclusion")
            var buffer = TypingBuffer()
            for char in "xnj" + hyphen + "nj" { buffer.append(String(char)) }
            expect(buffer.finishWord() == "xnj" + hyphen + "nj", "hyphen does not split the typing buffer")
        }
        for protected in ["fooBar", "user_name", "GPT-4o", "https://example.com", "hello-мир"] {
            expect(detect(protected) == nil, "identifiers, addresses and intentional mixed text stay unchanged")
        }
        var established: Layout?
        func contextual(_ input: String) -> String? {
            AutoCorrection.detect(input, recognizes: dictionary.recognizes,
                recognizesFragment: dictionary.recognizesCommon, recognizesBackoff: dictionary.recognizesBackoff, establishedLanguage: established,
                convert: convert, onKnownSource: { established = $0 })?.text
        }
        expect(contextual("hello") == nil && established == .english, "known English word establishes language without retaining its text")
        for abbreviation in ["vs", "dj", "kb", "jr", "bp", "ye", "ds"] {
            expect(contextual(abbreviation) == nil, "short English token protected in established English context")
        }
        // Models the same reset performed on focus/manual-source/foreign-input
        // changes; no context from another field may suppress its first word.
        established = nil
        expect(contextual("bp") == "из", "new field restores isolated Russian preposition")
        established = .russian
        expect(contextual("ds") == "вы", "Russian language context retains short-word corrections")
        expect(contextual("lkz") == "для", "English context protection never blocks unrelated Russian words")
        for ambiguous in ["levf.", "fhf,", ",fy."] {
            expect(detect(ambiguous) == nil, "inherently ambiguous punctuation is not guessed")
        }
        var calls: [String: Int] = [:]
        _ = AutoCorrection.detect("(ghbdtn)...", recognizes: { word, layout in
            let key = (layout == .russian ? "r:" : "e:") + word
            calls[key, default: 0] += 1
            return dictionary.recognizes(word, layout)
        }, recognizesFragment: dictionary.recognizesCommon, recognizesBackoff: dictionary.recognizesBackoff, convert: convert)
        expect(!calls.isEmpty && calls.values.allSatisfy { $0 == 1 }, "one expensive full-word lookup per spelling/direction in a decision")
    }
    let samples = ["ghbdtn", "lkz", "b[", "(ghbdtn)...", "ytqhjfutynfv", "цщклекууэы", "руддщ", "levf."]
    var elapsed: [Double] = []
    for _ in 0..<40 {
        for input in samples {
            let start = ProcessInfo.processInfo.systemUptime
            _ = AutoCorrection.detect(input, recognizes: dictionary.recognizes, recognizesFragment: dictionary.recognizesCommon, recognizesBackoff: dictionary.recognizesBackoff)
            elapsed.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        }
    }
    elapsed.sort()
    print(String(format: "Recognition latency, offline warm corpus: p50 %.3f ms, p95 %.3f ms, max %.3f ms (not editor latency)",
                 elapsed[elapsed.count / 2], elapsed[elapsed.count * 95 / 100], elapsed.last!))
    print("Passed \(count) release 46 recovery, observation, pause and vocabulary checks")
    return count
}
