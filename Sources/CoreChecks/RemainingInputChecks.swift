import Foundation
import SwitcherCore

func remainingInputChecks() -> Int {
    var count = 0
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), "Remaining input: " + message); count += 1
    }
    // Role-only/native activation is insufficient for a provider whose web
    // editor exists only in the enhanced mode. No OS calls or UI here.
    var webEnabled = false
    var writes: [String] = []
    let browser = AccessibilityModeRequest.acquire(read: { _ in false }, enable: { name in
        writes.append(name)
        if name == "AXEnhancedUserInterface" { webEnabled = true; return true }
        return false
    })
    expect(webEnabled && browser?.attribute == "AXEnhancedUserInterface", "web-provider handshake enables its editor")
    expect(writes == ["AXManualAccessibility", "AXEnhancedUserInterface"], "prefer manual mode, use supported fallback once")
    expect(browser?.restoreDisabled == true, "a known previous disabled state can be restored")
    writes.removeAll()
    let manual = AccessibilityModeRequest.acquire(read: { _ in false }, enable: { name in writes.append(name); return true })
    expect(manual?.attribute == "AXManualAccessibility" && writes == ["AXManualAccessibility"], "manual mode avoids screen-reader fallback")
    writes.removeAll()
    let alreadyEnabled = AccessibilityModeRequest.acquire(read: { _ in true }, enable: { name in writes.append(name); return true })
    expect(writes.isEmpty && alreadyEnabled?.restoreDisabled == false, "another assistive client's mode is never toggled")
    let unknown = AccessibilityModeRequest.acquire(read: { _ in nil }, enable: { _ in true })
    expect(unknown?.restoreDisabled == false, "unknown prior state cannot authorize disabling another client")
    expect(AccessibilityModeRequest.acquire(read: { _ in nil }, enable: { _ in false }) == nil, "unsupported APIs never grant a lease")

    // Exact callback ordering: the receipt exists before a first key adopts B,
    // but the queued notification handler runs after that character.
    let receipts = ApplicationActivationReceipts()
    let activation = receipts.record(processID: 200)
    let adopted = receipts.current(for: 200)!.sequence
    var buffer = TypingBuffer(); buffer.append("r")
    let late = ApplicationActivationPolicy.decision(notifiedPID: 200, frontmostPID: 200,
        buffer: buffer, hasPendingInput: false, trackedPID: 200, receiptAlreadyApplied: activation.sequence == adopted)
    expect(late == .refreshOnly, "already adopted activation does not erase the first physical character")
    buffer.append("n"); buffer.append("j")
    expect(buffer.finishWord() == "rnj" && !buffer.requiresVerifiedText, "opaque editor retains a whole captured first word")
    expect(ApplicationActivationPolicy.decision(notifiedPID: 200, frontmostPID: 200, buffer: buffer,
        hasPendingInput: true, trackedPID: 200, receiptAlreadyApplied: true) == .refreshOnly,
        "same handled receipt does not cancel a held boundary")
    receipts.record(processID: 100)
    let returned = receipts.record(processID: 200)
    buffer.append("r")
    expect(returned.sequence != adopted, "leaving and returning creates a different receipt")
    expect(ApplicationActivationPolicy.decision(notifiedPID: 200, frontmostPID: 200,
        buffer: buffer, hasPendingInput: false, trackedPID: 200,
        receiptAlreadyApplied: returned.sequence == adopted) == .verifyWholeWord,
        "unobserved same-PID reactivation cannot bypass verification")
    expect(receipts.current(for: 100) == nil, "receipt from another app cannot authorize the current context")
    expect(ApplicationActivationPolicy.decision(notifiedPID: 100, frontmostPID: 200,
        buffer: buffer, hasPendingInput: false, trackedPID: 200, receiptAlreadyApplied: true) == .ignoreStale,
        "a handled flag never makes a foreign notification current")
    receipts.clear()
    expect(receipts.current(for: 200) == nil, "restart drops old context provenance")
    expect(receipts.record(processID: 200).sequence > returned.sequence, "receipt IDs cannot be reused across restart")

    // Independent target-key interpreter rejects a repeat after release. The
    // first restored repeat becomes a new press; later repeats retain repeat
    // semantics and the one original release closes that press.
    for key: Int64 in [49, 47, 18] {
        for repeats in [1, 2, 32] {
            var tracker = PhysicalKeyReleaseTracker()
            tracker.replacedKeyDown(key)
            var pressed = false, characters = 1, restorations = 0 // replacement already emitted down/up
            for _ in 0..<repeats {
                let restore = tracker.needsRestoredPress(key, isOriginal: true, isRepeat: true)
                if restore { pressed = true; restorations += 1 }
                if pressed { characters += 1 }
                tracker.forwardedKeyDown(key, isOriginal: true)
            }
            let suppressed = tracker.consumeKeyUp(key, isOriginal: true)
            if !suppressed { pressed = false }
            expect(characters == 1 + repeats, "no repeated character disappears after balanced replacement")
            expect(restorations == 1 && !suppressed && !pressed, "one press restoration preserves one final release")
        }
        var untouched = PhysicalKeyReleaseTracker()
        expect(!untouched.needsRestoredPress(key, isOriginal: true, isRepeat: true), "ordinary hardware repeat is unchanged")
        untouched.replacedKeyDown(key)
        expect(!untouched.needsRestoredPress(key, isOriginal: false, isRepeat: true), "self/foreign repeat cannot consume original ownership")
        expect(!untouched.needsRestoredPress(key, isOriginal: true, isRepeat: false), "ordinary repress is not transformed")
        expect(untouched.consumeKeyUp(key, isOriginal: true), "replaced key without repetition keeps its original release rule")
    }
    return count
}
