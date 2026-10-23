import Foundation
import SwitcherCore

/// Offline end-to-end checks for a *sequence* of physical-layout mistakes.
/// Each expected spelling is chosen before asking the recognizer. The scratch
/// editor has text on both sides of the cursor, so a short or long deletion is
/// observable instead of accidentally passing a single-token assertion.
func complexDirectionChecks(dictionary: LocalDictionary) -> Int {
    var checks = 0
    func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
        guard condition() else { fputs("Complex direction: \(name)\n", stderr); exit(1) }
        checks += 1
    }

    struct Word {
        let spelling: String
        let language: Layout
    }
    let russianWords = ["привет", "работает", "для", "их", "Яндекс", "ещё"]
        .map { Word(spelling: $0, language: .russian) }
    let englishWords = ["hello", "world", "keyboard", "thanks", "worktree", "codegen"]
        .map { Word(spelling: $0, language: .english) }
    for englishID in InputSources.englishIDs {
        let english = KeyboardLayoutTable(id: englishID)!
        for russianID in InputSources.russianIDs {
            let russian = KeyboardLayoutTable(id: russianID)!
            let table: (Layout) -> KeyboardLayoutTable = { $0 == .russian ? russian : english }
            let convert: (String, Layout) -> String = { text, destination in
                destination == .russian ? english.convert(text, to: russian) : russian.convert(text, to: english)
            }
            var eligibleRussian = 0, eligibleEnglish = 0, protectedCollisions = 0

            // Alternate RU→EN and EN→RU, including two consecutive corrections
            // toward the same language. Deliberately select a wrong source for
            // each token to exercise detection independently of retained language.
            let sequences: [[Word]] = [
                [russianWords[0], englishWords[0], russianWords[2], englishWords[2]],
                [englishWords[3], russianWords[1], englishWords[1], russianWords[3]],
                [russianWords[4], russianWords[5], englishWords[4], englishWords[5]],
                [englishWords[0], englishWords[3], russianWords[0], russianWords[1]]
            ]
            for (sequenceIndex, sequence) in sequences.enumerated() {
                for boundary in [" ", "!", "?", "…", "\n", "\t"] {
                    let prefix = "🙂 Начало ["
                    let tail = "] Конец 🦊"
                    var editor = prefix + tail
                    var cursor = prefix.count
                    var intended = prefix
                    for (wordIndex, word) in sequence.enumerated() {
                        let target = table(word.language)
                        let source = table(word.language == .russian ? .english : .russian)
                        let wrong = target.convert(word.spelling, to: source)
                        expect(wrong != word.spelling && source.convert(wrong, to: target) == word.spelling,
                               "physical round trip \(englishID)/\(russianID) \(word.spelling)")
                        if wrong.count > 2 && dictionary.recognizes(wrong.lowercased(), word.language == .russian ? .english : .russian) {
                            // Phonetic Russian can turn привет into the genuine
                            // English word privet. No algorithm can infer intent
                            // from that token alone; preserving it is mandatory.
                            expect(AutoCorrection.detect(wrong, recognizes: dictionary.recognizes,
                                recognizesFragment: dictionary.recognizesCommon, recognizesBackoff: dictionary.recognizesBackoff, convert: convert) == nil,
                                "real source word preserved \(englishID)/\(russianID) \(wrong)")
                            protectedCollisions += 1
                            continue
                        }
                        if word.language == .russian { eligibleRussian += 1 } else { eligibleEnglish += 1 }
                        let editorIndex = editor.index(editor.startIndex, offsetBy: cursor)
                        editor.insert(contentsOf: wrong, at: editorIndex)
                        cursor += wrong.count

                        // Space/Enter/Tab are not part of a token. An immediate
                        // punctuation key has not yet reached the editor when the
                        // correction plan is prepared.
                        let immediate = ![" ", "\n", "\t"].contains(boundary)
                        let input = wrong + (immediate ? boundary : "")
                        let correction = AutoCorrection.detect(input, recognizes: dictionary.recognizes,
                            recognizesFragment: dictionary.recognizesCommon, recognizesBackoff: dictionary.recognizesBackoff, convert: convert)
                        expect(correction?.text == word.spelling + (immediate ? boundary : "") &&
                               correction?.layout == word.language,
                               "complete correction \(englishID)/\(russianID) sequence \(sequenceIndex) word \(wordIndex) boundary \(boundary)")
                        guard let correction else { return checks }
                        let plan = KeyboardReplacement.keys(original: wrong, corrected: correction.text,
                            layout: correction.layout, appendSpace: boundary == " ",
                            keyProvider: { text, _ in target.replacement(text) })
                        expect(plan != nil, "representable replacement \(englishID)/\(russianID) \(word.spelling)")
                        guard let plan else { return checks }
                        expect(plan.prefix(while: { $0.code == 51 }).count == wrong.count,
                               "delete the complete original token \(englishID)/\(russianID) \(wrong)")
                        for key in plan {
                            if key.code == 51 {
                                expect(cursor > prefix.count, "never backspace into preceding text")
                                let before = editor.index(editor.startIndex, offsetBy: cursor - 1)
                                editor.remove(at: before); cursor -= 1
                            } else {
                                let output = key.text!
                                expect(target.character(code: key.code, shift: key.shift,
                                    capsLock: key.capsLock, option: key.option) == output,
                                    "physical replacement key agrees with Unicode \(englishID)/\(russianID) \(output)")
                                let position = editor.index(editor.startIndex, offsetBy: cursor)
                                editor.insert(contentsOf: output, at: position); cursor += output.count
                            }
                        }
                        if boundary == "\n" || boundary == "\t" {
                            let position = editor.index(editor.startIndex, offsetBy: cursor)
                            editor.insert(contentsOf: boundary, at: position); cursor += 1
                        }
                        // A punctuation boundary is immediately followed by the
                        // next word; space and submit boundaries are emitted once.
                        intended += word.spelling + boundary
                        expect(editor == intended + tail,
                               "adjacent text preserved \(englishID)/\(russianID) sequence \(sequenceIndex) word \(wordIndex) boundary \(boundary)")
                    }
                }
            }

            // Literal quotes/brackets can also be a letter key on the opposite
            // layout. Check both directions with balanced and nested closers;
            // these assertions intentionally require a unique complete spelling.
            for word in [russianWords[0], russianWords[1], englishWords[0], englishWords[3]] {
                let target = table(word.language)
                let source = table(word.language == .russian ? .english : .russian)
                let wrong = target.convert(word.spelling, to: source)
                if wrong.count > 2 && dictionary.recognizes(wrong.lowercased(), word.language == .russian ? .english : .russian) {
                    expect(AutoCorrection.detect(wrong, recognizes: dictionary.recognizes,
                        recognizesFragment: dictionary.recognizesCommon, recognizesBackoff: dictionary.recognizesBackoff, convert: convert) == nil,
                        "quoted source-word collision must not be converted \(englishID)/\(russianID) \(wrong)")
                    continue
                }
                for (open, close) in [("(", ")"), ("\"", "\""), ("«", "»"), ("‘", "’"), ("(\"", "\")")] {
                    for ending in ["", "!", "?!"] {
                        let input = open + wrong + close + ending
                        let expected = open + word.spelling + close + ending
                        let correction = AutoCorrection.detect(input, recognizes: dictionary.recognizes,
                            recognizesFragment: dictionary.recognizesCommon, recognizesBackoff: dictionary.recognizesBackoff, convert: convert)
                        expect(correction?.text == expected && correction?.layout == word.language,
                               "balanced wrapper \(englishID)/\(russianID) \(input) → \(expected)")
                        expect(AutoCorrection.detect(expected, recognizes: dictionary.recognizes,
                            recognizesFragment: dictionary.recognizesCommon, recognizesBackoff: dictionary.recognizesBackoff, convert: convert) == nil,
                               "correct wrapped word preserved \(englishID)/\(russianID) \(expected)")
                    }
                }
            }
            expect(eligibleRussian > 0 && eligibleEnglish > 0,
                   "both correction directions exercised on \(englishID)/\(russianID)")
            if russianID == "com.apple.keylayout.Russian-Phonetic" {
                expect(protectedCollisions > 0, "phonetic source-word ambiguity explicitly exercised")
            }
        }
    }
    print("Passed \(checks) complex bidirectional sequence checks")
    return checks
}
