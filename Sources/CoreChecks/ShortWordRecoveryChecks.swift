import Foundation
import SwitcherCore

func shortWordRecoveryChecks(dictionary: LocalDictionary) -> Int {
    var checks = 0
    func expect(_ condition: Bool, _ message: String) {
        guard condition else { fputs("Short word recovery: " + message + "\n", stderr); exit(1) }; checks += 1
    }
    // Real cancellation ownership + the same boundary observer used by the app.
    // Previously the destination batch was posted without this observer, leaving
    // the buffer invalid even when its final event was a physical Space.
    for boundary: UInt16 in [49, 36, 48, 76] {
        for waiting in [false, true] {
            for word in ["а", "в", "к", "и", "с", "у", "о", "я", "не", "на", "от", "из", "по", "за", "до", "для", "их"] {
                var queue = OrderedInputCancellation(originals: [boundary], awaitingDestination: waiting)
                var buffer = TypingBuffer(); buffer.reset(startOfWord: false)
                var replay = SessionReplayBoundary()
                if waiting {
                    expect(queue.takeDestinationBatch() == nil, "unacknowledged originals cannot be processed")
                    _ = queue.destinationAcknowledged()
                }
                for key in queue.takeDestinationBatch()! {
                    CancelledInputBoundary.observe(key: key, keyDown: true, buffer: &buffer, replay: &replay)
                    CancelledInputBoundary.observe(key: key, keyDown: false, buffer: &buffer, replay: &replay)
                }
                expect(buffer.isAtWordBoundary, "delivered boundary enables the next complete word")
                _ = queue.destinationAcknowledged(); _ = queue.takeSessionBatch()
                let input = Conversion.convert(word, to: .english)
                for char in input { buffer.append(String(char)) }
                let token = buffer.finishWord()
                expect(token == input, "next captured word survives a cancelled edit")
                expect(token.flatMap { AutoCorrection.detect($0, recognizes: dictionary.recognizes)?.text } == word,
                       "short RU word after cancellation: " + word)
            }
        }
    }
    // A metadata rejection with no missed text must preserve a known boundary.
    // Rejected letters/paste/navigation still invalidate the partial word.
    for boundary in [false, true] {
        var buffer = TypingBuffer(); buffer.append("old")
        buffer.rejectKey(wordBoundary: boundary)
        var permission = FocusPermission()
        permission.resolve(false, buffer: &buffer)
        buffer = buffer.afterCancellation(preserveEmptyBoundary: true)
        permission.resolve(true, buffer: &buffer)
        buffer.append("d")
        expect(buffer.finishWord() == (boundary ? "d" : nil), "focus recovery never invents a prefix")
    }
    var buffer = TypingBuffer(); buffer.append("old")
    expect(!buffer.afterCancellation(preserveEmptyBoundary: true).isAccepting, "partial token cannot survive cancellation")
    buffer.reset()
    expect(!buffer.afterCancellation().isAccepting, "ordinary cancellation remains conservative")
    var replay = SessionReplayBoundary()
    for key: UInt16 in [49, 2] {
        CancelledInputBoundary.observe(key: key, keyDown: true, buffer: &buffer, replay: &replay)
    }
    buffer.append("f")
    expect(buffer.finishWord() == nil, "flushed partial suffix cannot become a shorter word")

    // Actual supported tables, not a guessed alphabet substitution. Existing
    // valid English words must win when a phonetic mapping creates a collision.
    for englishID in InputSources.englishIDs {
        let english = KeyboardLayoutTable(id: englishID)!
        for russianID in InputSources.russianIDs {
            let russian = KeyboardLayoutTable(id: russianID)!
            let convert: (String, Layout) -> String = { text, layout in
                layout == .russian ? english.convert(text, to: russian) : russian.convert(text, to: english)
            }
            for word in ["а", "в", "к", "и", "с", "у", "о", "я", "на", "не", "от", "до", "за", "по", "из", "для", "их"] {
                let wrong = russian.convert(word, to: english)
                let isEnglishWord = ["a", "i", "to", "of", "in", "is", "it", "he", "we", "be", "by", "at", "an", "as", "am", "on", "or", "so", "if", "do", "no", "up", "us", "me", "my", "go", "oh", "ok", "hi"].contains(wrong.lowercased())
                for context: Layout? in [nil, .russian, .english] {
                    let result = AutoCorrection.detect(wrong, recognizes: dictionary.recognizes,
                        establishedLanguage: context, convert: convert)
                    let protectedAbbreviation = context == .english && ["vs", "dj", "kb", "jr", "bp", "ye", "ds"].contains(wrong.lowercased())
                    expect(isEnglishWord || protectedAbbreviation ? result == nil : result?.text == word, "physical short word mapping: " + englishID + "/" + russianID + " " + word)
                }
                var settings = CorrectionSettings(); settings.shortWords = false
                if word.count <= 2 {
                    expect(AutoCorrection.detect(wrong, recognizes: dictionary.recognizes, settings: settings, convert: convert) == nil, "short-word setting respected")
                }
            }
            for valid in ["a", "I", "in", "to", "on", "hello", "world", "а", "в", "к", "не"] {
                expect(AutoCorrection.detect(valid, recognizes: dictionary.recognizes, convert: convert) == nil, "correct source text preserved")
            }
        }
    }
    print("Passed \(checks) short-word and boundary-recovery checks")
    return checks
}
