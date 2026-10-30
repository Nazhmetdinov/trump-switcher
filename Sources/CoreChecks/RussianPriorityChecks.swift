import Foundation
import SwitcherCore

func russianPriorityChecks(dictionary: LocalDictionary) -> Int {
    var count = 0
    func expect(_ value: Bool, _ message: String) {
        guard value else { fputs("Russian priority: " + message + "\n", stderr); exit(1) }
        count += 1
    }
    var settings = CorrectionSettings(); settings.russianPriority = true
    let encoded = try! JSONEncoder().encode(settings)
    expect(CorrectionSettings.decode(encoded)?.prefersRussian == true, "mode survives save and reload")
    var old = try! JSONSerialization.jsonObject(with: encoded) as! [String: Any]
    old.removeValue(forKey: "russianPriority")
    expect(CorrectionSettings.decode(try! JSONSerialization.data(withJSONObject: old))?.prefersRussian == false, "old settings keep initials policy")
    old["russianPriority"] = "yes"
    expect(CorrectionSettings.decode(try! JSONSerialization.data(withJSONObject: old)) == nil, "malformed flag rejected")
    for englishID in InputSources.englishIDs {
        let english = KeyboardLayoutTable(id: englishID)!
        for russianID in ["com.apple.keylayout.Russian", "com.apple.keylayout.RussianWin"] {
            let russian = KeyboardLayoutTable(id: russianID)!
            let convert: (String, Layout) -> String = { text, target in
                target == .russian ? english.convert(text, to: russian) : russian.convert(text, to: english)
            }
            func detect(_ text: String, _ policy: CorrectionSettings = settings, _ language: Layout? = nil) -> AutoCorrection? {
                AutoCorrection.detect(text, recognizes: dictionary.recognizes,
                    recognizesFragment: dictionary.recognizesCommon, recognizesBackoff: dictionary.recognizesBackoff,
                    settings: policy, establishedLanguage: language, convert: convert)
            }
            for word in ["а", "и", "в", "к", "с", "у", "о", "я"] {
                for correct in [word, word.uppercased()] {
                    let input = russian.convert(correct, to: english)
                    for wrapper in [("", ""), ("(", ")"), ("«", "»"), ("", "!"), ("", "…")] {
                        expect(detect(wrapper.0 + input + wrapper.1)?.text == wrapper.0 + correct + wrapper.1, "function word " + correct)
                    }
                    var disabled = settings; disabled.shortWords = false
                    expect(detect(input, disabled) == nil, "short words can be disabled")
                    disabled = settings; disabled.toRussian = false
                    expect(detect(input, disabled) == nil, "direction can be disabled")
                    disabled = settings; disabled.excludedWords = [word]
                    expect(detect(input, disabled) == nil, "target exclusions outrank priority")
                    if correct == correct.uppercased() {
                        expect(detect(input, CorrectionSettings()) == nil, "legacy initials unchanged")
                        expect(detect(input, settings, .english) == nil, "established English protects initials")
                    }
                }
            }
            for source in ["a", "A", "I", "i", "in", "to", "by", "hello", "world", "Ford", "Apple", "OpenAI", "John", "user_name", "fooBar", "https://example.com", "person@example.com", "Q", "X", "ABC"] {
                expect(detect(source) == nil, "valid English or identifier unchanged: " + source)
            }
            // Every switch position, both directions, with physical characters
            // rather than editor input. The buffer must survive the source shortcut.
            for (word, target) in [("привет", Layout.russian), ("Айдар", .russian), ("нейронка", .russian), ("таймвеб", .russian), ("hello", .english), ("keyboard", .english)] {
                let wrong = target == .russian ? russian.convert(word, to: english) : english.convert(word, to: russian)
                let letters = Array(word), encodedLetters = Array(wrong)
                for split in 0...letters.count {
                    for inverse in [false, true] {
                        var buffer = TypingBuffer()
                        for index in letters.indices {
                            if index == split { TypingShortcut.inputSource.apply(to: &buffer) }
                            buffer.noteKey(at: Double(index) * 0.008)
                            buffer.append(String((index < split) != inverse ? encodedLetters[index] : letters[index]))
                        }
                        let token = buffer.finishWord()!
                        let result = detect(token)
                        expect(token == word ? result == nil : result?.text == word, "mixed source split " + word + " " + String(split))
                    }
                }
            }
        }
    }
    print("Passed \(count) Russian priority and rapid source-sequence checks")
    return count
}

func benchmarkRussianPriority() {
    let dictionary = LocalDictionary()
    let corpus = ["F", "B", "D", "R", "f", "lkz", "b[", "ghbdtn", "hello", "world", "fq lfh".replacingOccurrences(of: " ", with: ""), "ytqhjyrf", "nfqvdt,", "руддщ", "лунсщфкв", "unsupportedword"]
    for enabled in [false, true] {
        var settings = CorrectionSettings(); settings.russianPriority = enabled
        var samples: [Double] = []; var checksum = 0
        func run(_ token: String) -> AutoCorrection? {
            AutoCorrection.detect(token, recognizes: dictionary.recognizes,
                recognizesFragment: dictionary.recognizesCommon, recognizesBackoff: dictionary.recognizesBackoff,
                settings: settings)
        }
        for token in corpus { _ = run(token) }
        for i in 0..<1600 {
            let started = DispatchTime.now().uptimeNanoseconds
            let result = run(corpus[i % corpus.count])
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
            checksum += result?.text.count ?? 0
        }
        samples.sort()
        print(String(format: "Russian priority %@: p50 %.4f ms, p95 %.4f ms, max %.4f ms; checksum %d",
            enabled ? "on" : "off", samples[800], samples[1520], samples.last!, checksum))
    }
    print("Detector timing only; no keyboard input or editor delivery measured.")
}
