import Foundation
import SwitcherCore

func reliabilityChecks(dictionary: LocalDictionary) -> Int {
    var count = 0
    func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
        guard condition() else { fputs("Reliability regression: " + name + "\n", stderr); exit(1) }
        count += 1
    }
    let abc = KeyboardLayoutTable(id: "com.apple.keylayout.ABC")!
    let russian = KeyboardLayoutTable(id: "com.apple.keylayout.Russian")!
    for id in InputSources.englishIDs {
        let table = KeyboardLayoutTable(id: id)!
        for (_, character) in table.characters {
            guard let key = table.replacement(character) else { fputs("Missing English replacement key\n", stderr); exit(1) }
            expect(table.character(code: key.code, shift: key.shift, capsLock: key.capsLock, option: key.option) == character,
                   "English native modifier/replacement table: " + id)
        }
    }
    let convert: (String, Layout) -> String = { text, layout in
        layout == .russian ? abc.convert(text, to: russian) : russian.convert(text, to: abc)
    }
    func detect(_ token: String) -> String? {
        AutoCorrection.detect(token, recognizes: dictionary.recognizes,
                              recognizesFragment: dictionary.recognizesCommon, convert: convert)?.text
    }
    for (input, expected) in [("lkz", "для"), ("Lkz", "Для"), ("b[", "их"), ("B[", "Их")] {
        expect(detect(input) == expected, "reported complete word has an explicit expected result: " + input)
    }
    for word in ["их", "им", "ей", "не", "для", "и", "в", "ой", "эх", "ёж", "ум", "яд", "юг", "всё", "ещё", "знаю", "наших", "других", "неделю"] {
        expect(detect(russian.convert(word, to: abc)) == word, "short word / reported letter-ending omission: " + word)
    }
    for word in ["валюта", "июль", "июля", "интересуюсь", "волнуюсь", "впечатляющее", "возвращаюсь", "готовлюсь", "делюсь"] {
        expect(detect(word) == nil, "real word is not a foreign domain: " + word)
        expect(detect(russian.convert(word, to: abc)) == word, "bare-domain collision recovers: " + word)
    }
    for address in ["yandex.ru", "google.com", "hello.world", "https://dfk.nf", "user@b.km", "https://example.com/a?q=1"] {
        expect(detect(address) == nil, "real URL/email preserved: " + address)
    }
    for (layout, words) in [(Layout.russian, ["не", "их", "им", "ей", "на", "для", "привет", "работает", "Яндекс", "других", "наших", "клавиатура", "нейросеть"]),
                            (.english, ["to", "of", "in", "hello", "keyboard", "browser", "settings", "thanks", "Docker"])] {
        for word in words {
            let wrong = convert(word, layout == .russian ? .english : .russian)
            for i in 1..<word.count {
                for input in [String(word.prefix(i)) + wrong.dropFirst(i), String(wrong.prefix(i)) + word.dropFirst(i)] {
                    if input == word || input == wrong { continue }
                    for ending in ["", "!", "?"] {
                        expect(detect(input + ending) == word + ending, "whole mixed-script recovery: " + input + ending)
                    }
                }
            }
        }
    }
    expect(detect("рабоnf.") == nil, "mixed word ending may mean работаю or работа; no truncated guess")
    for token in ["ghbdtn_test", "someVariable", "sudo", "git", "hello123", "api/v1", "🙂", "ghbdtn\u{0}"] {
        expect(detect(token) == nil, "code/non-word protection: " + token)
    }
    for word in ["промптами", "нейросетями", "скриншотов", "автопереключение", "мессенджеров", "созвонов"] {
        expect(dictionary.recognizes(word, .russian), "modern Russian term: " + word)
        expect(detect(russian.convert(word, to: abc)) == word, "modern term converts: " + word)
    }
    for word in ["colour", "colours", "favourite", "organising", "customisation", "behaviour", "docker", "webhooks"] {
        expect(dictionary.recognizes(word, .english), "British/technical spelling: " + word)
        expect(detect(abc.convert(word, to: russian)) == word, "British/technical spelling converts: " + word)
    }
    for (option, function) in [(true, false), (false, true), (true, true)] {
        var buffer = TypingBuffer()
        for char in "ghbdtn" { buffer.append(String(char)) }
        let action = TypingShortcut.action(code: 51, command: false, control: false, option: option, shift: false, function: function)
        expect(action == .invalidate, "word/forward deletion isn't a one-character backspace")
        action?.apply(to: &buffer)
        for char in "b" { buffer.append(String(char)) }
        expect(buffer.finishWord() == nil, "no stale prefix after word/forward deletion")
        buffer.append("b"); expect(buffer.finishWord() == "b", "boundary resumes after untracked edit")
    }
    var permission = FocusPermission()
    // Click/Tab -> stale non-editable wrapper -> real editor -> first word.
    // A metadata observation inserts/deletes no characters. It must not turn an
    // empty, complete token into an incomplete one before any key was rejected.
    for input in ["lkz", "Lkz", "b[", "B["] {
        var firstWord = TypingBuffer()
        var focus = FocusPermission()
        focus.begin()
        focus.resolve(false, buffer: &firstWord)
        expect(focus.requiresKeyProbe, "stale blocked focus is checked on first key, not only a timer")
        focus.resolve(true, buffer: &firstWord)
        expect(!focus.requiresKeyProbe, "normal typing does not repeatedly synchronously probe focus")
        for ch in input { firstWord.append(String(ch)) }
        expect(firstWord.finishWord().flatMap(detect) == detect(input),
               "first word survives transient non-editable focus: " + input)
    }
    for rejectedKey in [false, true] {
        var partial = TypingBuffer()
        var focus = FocusPermission()
        if rejectedKey { partial.reset(startOfWord: false) }
        else { partial.append("l") }
        focus.resolve(false, buffer: &partial)
        focus.resolve(true, buffer: &partial)
        for ch in "kz" { partial.append(String(ch)) }
        expect(partial.finishWord() == nil, "a lost key/changed field cannot become a complete short word")
        for ch in "lkz" { partial.append(String(ch)) }
        expect(partial.finishWord().flatMap(detect) == "для", "next whole word resumes normally")
    }
    for repetitions in [1, 2, 10, 100] {
        var stream = TypingBuffer()
        var focus = FocusPermission()
        for _ in 0..<repetitions { focus.resolve(false, buffer: &stream) }
        focus.resolve(true, buffer: &stream)
        for ch in "b[" { stream.append(String(ch)) }
        expect(stream.finishWord().flatMap(detect) == "их", "repeated metadata replies don't consume first word")
    }
    expect(!FocusTracking.shouldReset(previousRole: "AXTextArea", nextRole: "AXTextArea", identityChanged: true, alreadyReset: false, sameLogicalField: true), "rebuilt web composer does not cut a word")
    expect(FocusTracking.shouldReset(previousRole: "AXTextArea", nextRole: "AXTextArea", identityChanged: true, alreadyReset: false, sameLogicalField: false), "different composer still invalidates a word")
    expect(!FocusTracking.shouldCancelPending(previousRole: "AXTextArea", nextRole: "AXTextArea", identityChanged: true,
        sameLogicalField: true), "rebuilt AX wrapper cannot cancel a held word in the same composer")
    expect(FocusTracking.shouldCancelPending(previousRole: "AXTextArea", nextRole: "AXTextArea", identityChanged: true,
        sameLogicalField: false), "different editor cancels a held word")
    expect(!FocusTracking.shouldCancelPending(previousRole: "AXTextArea", nextRole: "AXTextArea", identityChanged: false,
        sameLogicalField: false), "unchanged editor retains a held word")
    expect(FocusTracking.shouldCancelInput(previousRole: "AXTextArea", nextRole: "AXTextArea", identityChanged: true,
        sameIdentifiedField: false, sameCapturedField: true, phase: .deciding),
        "geometry alone cannot retain an uncommitted edit")
    expect(!FocusTracking.shouldCancelInput(previousRole: "AXTextArea", nextRole: "AXTextArea", identityChanged: true,
        sameIdentifiedField: false, sameCapturedField: true, phase: .delivering),
        "wrapper churn after commit retains ordered typing")
    expect(FocusTracking.shouldCancelInput(previousRole: "AXTextArea", nextRole: "AXTextArea", identityChanged: true,
        sameIdentifiedField: false, sameCapturedField: false, phase: .delivering),
        "a different field cancels later typing even after a commit")
    expect(FocusTracking.sameIdentifiedField(previousIdentity: "AXTextArea/id/composer", nextIdentity: "AXTextArea/id/composer",
        previousRole: "AXTextArea", nextRole: "AXTextArea"), "same stable editor identifier survives AX wrapper churn")
    expect(!FocusTracking.sameIdentifiedField(previousIdentity: "AXTextArea/rect/10/20/300", nextIdentity: "AXTextArea/rect/10/20/300",
        previousRole: "AXTextArea", nextRole: "AXTextArea"), "coincident editor geometry cannot retain a pending mutation")
    expect(!FocusTracking.sameIdentifiedField(previousIdentity: "AXTextArea/id/first", nextIdentity: "AXTextArea/id/second",
        previousRole: "AXTextArea", nextRole: "AXTextArea"), "different identified editor cancels a held word")
    expect(FocusTracking.needsWholeWordProof(identityChanged: true, sameLogicalField: true,
        sameIdentifiedField: false, previousRole: "AXTextArea", nextRole: "AXTextArea"),
        "equal editor geometry requires a complete-word check")
    expect(!FocusTracking.needsWholeWordProof(identityChanged: true, sameLogicalField: true,
        sameIdentifiedField: true, previousRole: "AXTextArea", nextRole: "AXTextArea"),
        "stable editor identifier does not require another word check")
    expect(!FocusTracking.needsWholeWordProof(identityChanged: false, sameLogicalField: true,
        sameIdentifiedField: false, previousRole: "AXTextArea", nextRole: "AXTextArea"),
        "unchanged AX wrapper does not require another word check")
    var geometryToken = TypingBuffer()
    geometryToken.append("r")
    if FocusTracking.needsWholeWordProof(identityChanged: true, sameLogicalField: true,
        sameIdentifiedField: false, previousRole: "AXTextArea", nextRole: "AXTextArea") {
        geometryToken.requireVerifiedText()
    }
    geometryToken.append("n")
    expect(geometryToken.token == "rn" && geometryToken.requiresVerifiedText,
        "ambiguous geometry retains input but cannot authorize an unverified replacement")
    for _ in 0..<50 {
        permission.resolve(true); permission.exclude() // Settings/Secure Input
        permission.begin() // back to the SAME PID or Tab to another field
        expect(permission.awaiting && !permission.permitted, "same-process return requests safety check")
        permission.resolve(true)
        expect(!permission.awaiting && permission.permitted, "first word can be captured after probe")
    }
    var paused = TypingBuffer()
    paused.noteKey(at: 1)
    for ch in "ghb" { paused.append(String(ch)) }
    paused.noteKey(at: 301)
    for ch in "dtn" { paused.append(String(ch)) }
    expect(paused.finishWord().flatMap(detect) == "привет", "five-minute pause doesn't split a word")
    for prefix in ["", " ", "\n", "\t", "(", "🙂 "] {
        expect(ReplacementContext.matches(original: "ghbdtn", beforeCaret: prefix + "ghbdtn", afterCaret: " ", selectionLength: 0), "complete caret suffix accepted")
    }
    for (actual, after, selection) in [("oldghbdtn", "", 0), ("ghbdtn", "tail", 0), ("ghbdtn", "", 2), ("ghbdt", "", 0), ("привет", "", 0), ("ghbdtn…", "", 0)] {
        expect(!ReplacementContext.matches(original: "ghbdtn", beforeCaret: actual, afterCaret: after, selectionLength: selection), "changed/partial field is not deleted")
    }
    expect(!ReplacementContext.matches(original: "ghbdtn...", beforeCaret: "ghbdtn…", afterCaret: nil, selectionLength: 0), "smart ellipsis cannot erase preceding characters")
    expect(!ReplacementContext.matches(original: "ghbdtn--", beforeCaret: "ghbdtn—", afterCaret: nil, selectionLength: 0), "smart dash cannot erase preceding characters")
    expect(ReplacementContext.needsVerifiedText("ghbdtn..."), "unverifiable smart punctuation requires context")
    expect(!ReplacementContext.needsVerifiedText("hf,jnftn"), "comma-letter needs no smart punctuation exception")
    expect(abc.character(code: 11, shift: true, capsLock: true) == "B", "real ABC Shift/Caps")
    expect(russian.character(code: 11, shift: true, capsLock: true) == "И", "real RU Shift/Caps")
    expect(russian.character(code: 11, shift: false, capsLock: true, option: true) == "и", "real RU Option/Caps differs from guessed uppercase")
    print("Passed \(count) reliability regressions")
    return count
}
