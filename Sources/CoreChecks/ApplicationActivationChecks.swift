import Foundation
import SwitcherCore

func applicationActivationChecks() -> Int {
    var count = 0
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError("Application activation: \(message)") }
        count += 1
    }
    func correction(_ token: String?) -> AutoCorrection? {
        token.flatMap { AutoCorrection.detect($0, recognizes: { _, _ in false }, isAddress: { _ in false }) }
    }
    func activate(_ buffer: inout TypingBuffer, notified: Int32?, frontmost: Int32?, pending: Bool = false) -> Bool {
        let decision = ApplicationActivationPolicy.decision(notifiedPID: notified, frontmostPID: frontmost,
                                                           buffer: buffer, hasPendingInput: pending)
        guard case .invalidate(let startOfWord) = decision else { return false }
        buffer.reset(startOfWord: false) // AutoMonitor.cancel()
        buffer.reset(startOfWord: startOfWord)
        return true // Production must still invalidate its AX permission.
    }
    func deliver(_ original: String, suffix: String) -> String {
        guard let result = correction(suffix),
              let keys = KeyboardReplacement.keys(original: suffix, corrected: result.text, layout: result.layout) else {
            return original + " "
        }
        var editor = original
        for key in keys {
            if key.code == 51 { editor.removeLast() }
            else { editor += key.text ?? "" }
        }
        return editor
    }

    // Real buffer/detector/keyboard plan reproduce the old mixed-word defect.
    var old = TypingBuffer()
    old.append("r")
    old.reset(startOfWord: false)
    old.reset() // Unconditional didActivate reset after the first physical key.
    old.append("n"); old.append("j")
    let oldSuffix = old.finishWord()
    expect(oldSuffix == "nj", "old notification forgets the already forwarded prefix")
    expect(correction(oldSuffix)?.text == "то", "the surviving suffix is a real short-word candidate")
    expect(deliver("rnj", suffix: oldSuffix!) == "rто ", "old opaque path produces a mixed word")

    var late = TypingBuffer()
    late.append("r")
    expect(activate(&late, notified: 200, frontmost: 200), "late current notification still revokes focus permission")
    expect(late.token.isEmpty && !late.isAccepting, "late notification blocks the partial word")
    late.append("n"); late.append("j")
    expect(late.finishWord() == nil, "suffix cannot become a replacement candidate")
    expect(late.isAccepting, "a real word boundary resumes normal monitoring")
    late.append("n"); late.append("j")
    expect(correction(late.finishWord())?.text == "то", "the next complete word still works")

    var beforeFirstKey = TypingBuffer()
    expect(activate(&beforeFirstKey, notified: 200, frontmost: 200), "notification before typing invalidates permission")
    beforeFirstKey.append("n"); beforeFirstKey.append("j")
    expect(correction(beforeFirstKey.finishWord())?.text == "то", "known empty boundary retains the first complete word")

    // A stale notification must not cancel the current app's token or pending
    // delivery. This is the only case in which permission is not invalidated.
    for pending in [false, true] {
        var current = TypingBuffer()
        current.append("n")
        expect(!activate(&current, notified: 100, frontmost: 200, pending: pending), "proven stale PID is ignored")
        expect(current.token == "n" && current.isAccepting, "stale notification preserves the active prefix")
        current.append("j")
        expect(correction(current.finishWord())?.text == "то", "stale notification does not split the active word")
    }

    // Same PID is deliberately not a duplicate heuristic: A -> B -> A can
    // happen without a single key/metadata poll while B was frontmost.
    for state in 0...2 {
        var returning = TypingBuffer()
        if state == 1 { returning.append("r") }
        if state == 2 { returning.reset(startOfWord: false) }
        expect(activate(&returning, notified: 100, frontmost: 100), "same-PID reactivation always revokes permission")
        expect(returning.isAccepting == (state == 0), "same-PID return cannot revive old partial/rejected input")
        expect(activate(&returning, notified: 100, frontmost: 100), "duplicate current notification remains a safety invalidation")
        expect(returning.isAccepting == (state == 0), "repeated invalidation cannot reopen a blocked prefix")
    }

    // Empty after finishWord is not a new boundary while input is in flight:
    // the cancellation queue may deliver 'r' without passing process() again.
    var queued = TypingBuffer()
    queued.append("n"); queued.append("j")
    expect(queued.finishWord() == "nj", "fixture owns a held boundary after a complete token")
    expect(activate(&queued, notified: 200, frontmost: 200, pending: true), "pending delivery is still cancelled")
    expect(!queued.isAccepting, "pending input forbids restoring the empty-buffer boundary")
    var editor = "nj r" // Held original Space and first next-word key delivered.
    for char in "nj" { editor.append(char); queued.append(String(char)) }
    let queuedSuffix = queued.finishWord()
    expect(queuedSuffix == nil && editor == "nj rnj", "a replayed prefix cannot acquire a corrected suffix")

    // Missing/invalid identity is uncertainty, never proof of a stale event.
    for identities: (Int32?, Int32?) in [(nil, 200), (200, nil), (nil, nil), (0, 200), (200, 0)] {
        var unknown = TypingBuffer()
        unknown.append("r")
        expect(activate(&unknown, notified: identities.0, frontmost: identities.1), "unknown PID invalidates permission")
        unknown.append("n"); unknown.append("j")
        expect(unknown.finishWord() == nil, "unknown activation cannot expose a suffix")
    }
    var preserved = TypingBuffer()
    preserved.append("r")
    expect(ApplicationActivationPolicy.decision(notifiedPID: 200, frontmostPID: 200,
        buffer: preserved, hasPendingInput: false, trackedPID: 200) == .verifyWholeWord,
        "late activation can retain a prefix already captured in the current process")
    preserved.requireVerifiedText()
    preserved.append("n"); preserved.append("j")
    expect(preserved.token == "rnj" && preserved.requiresVerifiedText,
        "retained prefix produces a whole candidate rather than a suffix")
    expect(AutoCorrection.detect(preserved.token,
        recognizes: { word, layout in word == "кто" && layout == .russian },
        isAddress: { _ in false })?.text == "кто",
        "the detector corrects the retained whole token rather than nj")
    expect(WordReplacementPlan(original: preserved.token, replacement: "кто",
        selection: NSRange(location: 3, length: 0), beforeCaret: "rnj", afterCaret: nil) != nil,
        "exact editor text can authorize the complete first word")
    expect(WordReplacementPlan(original: preserved.token, replacement: "кто",
        selection: NSRange(location: 2, length: 0), beforeCaret: "nj", afterCaret: nil) == nil,
        "another editor containing only the suffix cannot authorize deletion")
    expect(WordReplacementPlan(original: preserved.token, replacement: "кто",
        selection: NSRange(location: 4, length: 0), beforeCaret: "xrnj", afterCaret: nil) == nil,
        "matching suffix inside a larger word is not a complete token")
    expect(preserved.finishWord() == "rnj" && !preserved.requiresVerifiedText,
        "verification requirement belongs to only one word")
    preserved.append("n"); preserved.append("j")
    expect(!preserved.requiresVerifiedText && preserved.finishWord() == "nj",
        "subsequent words keep ordinary correction behavior")
    var pendingPrefix = TypingBuffer(); pendingPrefix.append("r")
    expect(ApplicationActivationPolicy.decision(notifiedPID: 200, frontmostPID: 200,
        buffer: pendingPrefix, hasPendingInput: true, trackedPID: 200) == .invalidate(startOfWord: false),
        "a captured prefix is not recoverable while cancellation owns other input")
    expect(ApplicationActivationPolicy.decision(notifiedPID: 200, frontmostPID: 200,
        buffer: pendingPrefix, hasPendingInput: false, trackedPID: 100) == .invalidate(startOfWord: false),
        "the previous process's token is never retained in a new process")
    pendingPrefix.requireVerifiedText(); pendingPrefix.selectAll()
    expect(!pendingPrefix.requiresVerifiedText && pendingPrefix.token.isEmpty,
        "known replacement of the selection clears the tentative prefix")
    return count
}
