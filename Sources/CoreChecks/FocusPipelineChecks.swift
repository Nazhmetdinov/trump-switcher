import Foundation
import SwitcherCore

/// Offline editor model. It combines the production focus policy, buffer,
/// detector, exact-word preflight, keyboard plan, and source rollback. It does
/// not post events, inspect other apps, or claim to exercise the AX adapter.
func focusPipelineChecks(dictionary: LocalDictionary) -> Int {
    var checks = 0
    var context = "fixed"
    func expect(_ condition: @autoclosure () -> Bool, _ reason: String) {
        guard condition() else { fatalError("Focus pipeline [\(context)]: \(reason)") }
        checks += 1
    }
    let english = KeyboardLayoutTable(id: "com.apple.keylayout.ABC")!
    let russian = KeyboardLayoutTable(id: "com.apple.keylayout.Russian")!
    let convert: (String, Layout) -> String = { text, target in
        target == .russian ? english.convert(text, to: russian) : russian.convert(text, to: english)
    }
    let expectedWords = ["lkz": "для", "b[": "их", "ghbdtn": "привет",
                         "руддщ": "hello", "цщкдв": "world"]

    final class Editor {
        var text = ""
        var writes = 0
    }
    struct Model {
        var fields = [Editor(), Editor()]
        var active = 0
        var buffer = TypingBuffer()
        var identity = "AXTextArea/id/first"
        var role = "AXTextArea"
        var wrapper = 1
        var source = "com.apple.keylayout.ABC"
    }
    func focus(_ model: inout Model, field: Int, wrapper: Int, identity: String) {
        let changed = FocusTracking.changed(previousIdentity: model.identity, nextIdentity: identity,
            previousRole: model.role, nextRole: model.role, sameElement: model.wrapper == wrapper)
        let sameLogical = model.identity == identity
        let identified = FocusTracking.sameIdentifiedField(previousIdentity: model.identity,
            nextIdentity: identity, previousRole: model.role, nextRole: model.role)
        if FocusTracking.needsWholeWordProof(identityChanged: changed, sameLogicalField: sameLogical,
            sameIdentifiedField: identified, previousRole: model.role, nextRole: model.role) {
            model.buffer.requireVerifiedText()
        }
        if FocusTracking.shouldCancelPending(previousRole: model.role, nextRole: model.role,
            identityChanged: changed, sameLogicalField: identified) {
            if !sameLogical { model.buffer.reset() }
        }
        if FocusTracking.shouldReset(previousRole: model.role, nextRole: model.role,
            identityChanged: changed, alreadyReset: false, sameLogicalField: sameLogical) {
            model.buffer.invalidatePartialWord()
        }
        model.active = field
        model.wrapper = wrapper
        model.identity = identity
    }
    func type(_ model: inout Model, _ value: String) {
        for character in value {
            model.fields[model.active].text.append(character)
            model.buffer.append(String(character))
        }
    }
    @discardableResult
    func boundary(_ model: inout Model, _ value: String, manualSourceChange: Bool = false) -> Bool {
        let field = model.fields[model.active]
        let other = model.fields[1 - model.active]
        let otherBefore = other.text
        let before = field.text
        let sourceBefore = model.source
        let mustVerify = model.buffer.requiresVerifiedText
        let token = model.buffer.finishWord()
        var corrected = false
        if let token,
           let correction = AutoCorrection.detect(token, recognizes: dictionary.recognizes,
                recognizesFragment: dictionary.recognizesCommon, convert: convert),
           let plan = WordReplacementPlan(original: token, replacement: correction.text,
                selection: NSRange(location: before.utf16.count, length: 0),
                beforeCaret: before, afterCaret: nil) {
            // A geometry-only focus match is never enough: only exact text in
            // the current field authorizes its deletion, including this path.
            expect(!mustVerify || plan.original == token && before.hasSuffix(token),
                   "tentative prefix lacked complete-word proof")
            let table = correction.layout == .russian ? russian : english
            if let keys = KeyboardReplacement.keys(original: token, corrected: correction.text,
                layout: correction.layout, appendSpace: false,
                keyProvider: { character, _ in table.replacement(character) }),
               keys.count == token.count + correction.text.count,
               keys.prefix(token.count).allSatisfy({ $0.code == 51 && $0.text == nil }),
               keys.dropFirst(token.count).compactMap(\.text).joined() == correction.text {
                var output = before
                for key in keys {
                    if key.code == 51 { output.removeLast() }
                    else { output += key.text! }
                }
                expect(output == String(before.dropLast(token.count)) + correction.text,
                       "keyboard plan changed a neighbour or dropped a letter")
                field.text = output
                field.writes += 1
                corrected = true
                if table.id != sourceBefore {
                    var selectedSource = table.id
                    if manualSourceChange { selectedSource = "explicit-user-source" }
                    let previous = sourceBefore == russian.id ? russian : english
                    let rollback = InputSourceRollback(previous: previous, temporary: table,
                        startedAt: 100, destinationPID: 42)!
                    let result = rollback.restore(preserving: nil, currentSource: { selectedSource },
                        foregroundPID: { 42 }, selectPrevious: { selectedSource = previous.id; return true },
                        restoredAt: { 110 })
                    expect((result != nil) == !manualSourceChange, "rollback ownership disagrees with manual switch")
                    model.source = selectedSource
                }
            }
        }
        field.text += value // the held physical boundary is delivered once
        expect(other.text == otherBefore, "replacement modified the other editor")
        if corrected, let token, let expected = expectedWords[token] {
            expect(field.text == String(before.dropLast(token.count)) + expected + value,
                   "word or boundary was lost/duplicated")
        } else if !corrected {
            expect(field.text == before + value, "uncorrected text or boundary changed")
        }
        expect(model.source == (manualSourceChange && corrected ? "explicit-user-source" : sourceBefore),
               "prior layout was not restored")
        return corrected
    }

    for (word, expected) in expectedWords.sorted(by: { $0.key < $1.key }) {
        for delimiter in [" ", "\n", "\t"] {
            context = "fixed \(word) boundary \(delimiter.debugDescription)"
            var model = Model()
            model.source = word.first?.isASCII == true ? english.id : russian.id
            type(&model, word)
            expect(boundary(&model, delimiter), "known word was not corrected")
            expect(model.fields[0].text == expected + delimiter && model.fields[0].writes == 1,
                   "fixed editor output or write count disagreed")
        }
        context = "fixed \(word) repeated space"
        var twice = Model()
        twice.source = word.first?.isASCII == true ? english.id : russian.id
        type(&twice, word)
        expect(boundary(&twice, " "), "first space did not correct")
        expect(!boundary(&twice, " ") && twice.fields[0].text == expected + "  " && twice.fields[0].writes == 1,
               "second space triggered duplicate correction or disappeared")
    }
    context = "stable ID wrapper churn"
    var same = Model()
    type(&same, "l")
    focus(&same, field: 0, wrapper: 2, identity: same.identity)
    type(&same, "kz")
    expect(boundary(&same, " ") && same.fields[0].text == "для ", "same composer lost its first letter")

    context = "geometry-only wrapper churn"
    var geometry = Model()
    geometry.identity = "AXTextArea/rect/10/20/300"
    type(&geometry, "l")
    focus(&geometry, field: 0, wrapper: 2, identity: geometry.identity)
    expect(geometry.buffer.requiresVerifiedText, "geometry retained an unverified prefix")
    type(&geometry, "kz")
    expect(boundary(&geometry, " ") && geometry.fields[0].text == "для ",
           "same editor did not recover after exact word verification")

    context = "reused AX object, new stable ID"
    var reused = Model()
    type(&reused, "r")
    focus(&reused, field: 1, wrapper: 1, identity: "AXTextArea/id/second")
    expect(reused.buffer.token.isEmpty && reused.buffer.isAccepting,
           "new stable field kept the prior editor's partial word")
    type(&reused, "zz")
    expect(!boundary(&reused, " ") && reused.fields[0].text == "r" &&
           reused.fields[1].text == "zz ", "reused object corrected a suffix in another field")

    context = "first word in newly focused field"
    var first = Model()
    type(&first, "r")
    focus(&first, field: 1, wrapper: 1, identity: "AXTextArea/id/second")
    type(&first, "lkz")
    expect(boundary(&first, " ") && first.fields[0].text == "r" &&
           first.fields[1].text == "для ", "new field skipped its first complete word")

    context = "two fields at the same coordinates"
    var coincident = Model()
    coincident.identity = "AXTextArea/rect/10/20/300"
    type(&coincident, "r")
    focus(&coincident, field: 1, wrapper: 2, identity: coincident.identity)
    type(&coincident, "nj")
    expect(!boundary(&coincident, " ") && coincident.fields[0].text == "r" &&
           coincident.fields[1].text == "nj ", "coincident geometry deleted the wrong editor")

    context = "manual layout change owns the source"
    var manual = Model()
    type(&manual, "lkz")
    expect(boundary(&manual, " ", manualSourceChange: true) &&
           manual.fields[0].text == "для " && manual.source == "explicit-user-source",
           "rollback overrode a later user layout change")

    // Seeded sequences keep every failure reproducible. These combine partial
    // words, editor changes, wrapper recreation, boundaries and both layouts.
    struct Random {
        var state: UInt64
        mutating func next(_ limit: Int) -> Int {
            state = state &* 2862933555777941757 &+ 3037000493
            return Int((state >> 33) % UInt64(limit))
        }
    }
    let words = ["lkz", "b[", "ghbdtn", "руддщ", "цщкдв", "hello", "привет"]
    for seed in 1...240 {
        var random = Random(state: UInt64(seed))
        var model = Model()
        for step in 0..<24 {
            context = "seed \(seed), step \(step)"
            let word = words[random.next(words.count)]
            model.source = word.first?.isASCII == true ? english.id : russian.id
            let action = random.next(5)
            if (action == 1 || action == 3) && !model.identity.contains("/rect/") {
                focus(&model, field: model.active, wrapper: model.wrapper + 1,
                      identity: "AXTextArea/rect/10/20/300")
            }
            let split = random.next(word.count + 1)
            type(&model, String(word.prefix(split)))
            switch action {
            case 0: focus(&model, field: model.active, wrapper: model.wrapper + 1, identity: model.identity)
            case 1:
                focus(&model, field: model.active, wrapper: model.wrapper + 1, identity: model.identity)
            case 2:
                let next = 1 - model.active
                focus(&model, field: next, wrapper: model.wrapper,
                      identity: "AXTextArea/id/\(next == 0 ? "first" : "second")")
            case 3:
                let next = 1 - model.active
                focus(&model, field: next, wrapper: model.wrapper + 1, identity: model.identity)
            default: break
            }
            type(&model, String(word.dropFirst(split)))
            let delimiter = [" ", "\n", "\t"][random.next(3)]
            let before = model.fields[model.active].text
            let other = model.fields[1 - model.active].text
            let writes = model.fields[model.active].writes
            _ = boundary(&model, delimiter)
            expect(model.fields[model.active].text.hasSuffix(delimiter), "boundary not delivered")
            expect(model.fields[1 - model.active].text == other, "another editor changed")
            expect(model.fields[model.active].writes - writes <= 1, "duplicate replacement")
            expect(model.fields[model.active].text.utf16.count >= before.utf16.count - word.utf16.count + delimiter.utf16.count,
                   "unrelated editor prefix removed")
        }
    }
    print("Passed \(checks) isolated focus/pipeline model checks (240 deterministic seeds)")
    return checks
}
