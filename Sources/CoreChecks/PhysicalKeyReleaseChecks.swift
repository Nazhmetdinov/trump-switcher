import Foundation
import SwitcherCore

func physicalKeyReleaseChecks() -> Int {
    var checks = 0
    func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        guard value() else { fatalError("Physical key release: \(message)") }
        checks += 1
    }

    // Regression: the old Set only recorded the replaced first Space down.
    // A later forwarded autorepeat down then lost its only physical release.
    var oldSuppression: Set<Int64> = [49]
    let oldForwarded = ["synthetic-down", "synthetic-up", "repeat-down"]
    let oldSwallowsRelease = oldSuppression.remove(49) != nil
    expect(oldForwarded.last == "repeat-down" && oldSwallowsRelease,
           "the previous policy reproduces an orphaned repeat down")

    for key: Int64 in [49, 47, 18] { // Space, period, shifted punctuation.
        for repeats in [1, 2, 32, 1_024] {
            var tracker = PhysicalKeyReleaseTracker()
            tracker.replacedKeyDown(key)
            for _ in 0..<repeats { tracker.forwardedKeyDown(key, isOriginal: true) }
            expect(!tracker.consumeKeyUp(key, isOriginal: true),
                   "forwarded autorepeats retain their release (\(key), \(repeats))")
            expect(!tracker.consumeKeyUp(key, isOriginal: true), "release is not remembered after delivery")
        }
        var replaced = PhysicalKeyReleaseTracker()
        replaced.replacedKeyDown(key)
        expect(replaced.consumeKeyUp(key, isOriginal: true), "replaced down consumes its original up")
        expect(!replaced.consumeKeyUp(key, isOriginal: true), "original up is consumed only once")

        // Merely holding/copying a repeat, or preparing a boundary that later
        // fails preflight, cannot change release ownership before delivery.
        var held = InputDeliveryQueue<Int64>()
        replaced.replacedKeyDown(key)
        held.enqueue(key)
        let lease = held.beginDelivery()!
        var beforeCommit = replaced
        expect(beforeCommit.consumeKeyUp(key, isOriginal: true), "an undecided queued down does not release ownership")
        let forwarded = held.commit(lease)!
        replaced.forwardedKeyDown(forwarded, isOriginal: true)
        expect(!replaced.consumeKeyUp(key, isOriginal: true), "committed replay down needs its physical up")

        // A continuation is itself replaced with a balanced pair. It must not
        // be mistaken for forwarding the original repeat/repress.
        replaced.replacedKeyDown(key)
        replaced.replacedKeyDown(key)
        replaced.forwardedKeyDown(key, isOriginal: false) // emitted synthetic down
        expect(!replaced.consumeKeyUp(key, isOriginal: false), "synthetic up cannot consume physical ownership")
        expect(replaced.consumeKeyUp(key, isOriginal: true), "replaced continuation still suppresses the physical up")

        replaced.replacedKeyDown(key)
        replaced.forwardedKeyDown(key + 1, isOriginal: true)
        expect(replaced.consumeKeyUp(key, isOriginal: true), "another key does not release this physical press")

        for origin in [(Int64(-1), Int64(0)), (Int64(7), Int64(0)), (Int64(0), Int64(123)),
                       (Int64(1), Int64(0x5452554d505357))] {
            replaced.replacedKeyDown(key)
            let admitted = KeyboardEventOrigin.isSystem(stateID: origin.0, userData: origin.1)
            replaced.forwardedKeyDown(key, isOriginal: admitted)
            expect(!replaced.consumeKeyUp(key, isOriginal: admitted), "foreign/self up does not modify suppression")
            expect(replaced.consumeKeyUp(key, isOriginal: true), "foreign/self down did not release original ownership")
        }
        for state: Int64 in [0, 1] {
            replaced.replacedKeyDown(key)
            replaced.forwardedKeyDown(key, isOriginal: KeyboardEventOrigin.isSystem(stateID: state, userData: 0))
            expect(!replaced.consumeKeyUp(key, isOriginal: true), "both admitted Quartz sources preserve the release")
        }
        replaced.replacedKeyDown(key)
        replaced.reset()
        expect(!replaced.consumeKeyUp(key, isOriginal: true), "stop/tap reset does not consume a later release")
    }

    struct Original: Equatable {
        let id: Int
        let key: Int64
        let down: Bool
        var original = true
    }
    // Exercise the real cancellation queue with each handoff route. Filtering
    // the entire batch before accounting its downs recreates the old defect.
    func prepare(_ events: [Original], _ tracker: inout PhysicalKeyReleaseTracker) -> [Original] {
        var delivered: [Original] = []
        for event in events {
            if !event.down && tracker.consumeKeyUp(event.key, isOriginal: event.original) { continue }
            if event.down { tracker.forwardedKeyDown(event.key, isOriginal: event.original) }
            delivered.append(event)
        }
        return delivered
    }
    let repeatDown = Original(id: 1, key: 49, down: true)
    let release = Original(id: 2, key: 49, down: false)
    for fallback in [false, true] {
        for releaseInSameBatch in [false, true] {
            var tracker = PhysicalKeyReleaseTracker()
            tracker.replacedKeyDown(49)
            var queue = OrderedInputCancellation(originals: releaseInSameBatch ? [repeatDown, release] : [repeatDown],
                                                 awaitingDestination: true)
            if !releaseInSameBatch { queue.enqueueInterrupt(release) }
            var output: [Original] = []
            if fallback {
                let owned = queue.takeOwnedFallback()
                output += prepare(owned.destination, &tracker)
                output += prepare(owned.session, &tracker)
            } else {
                expect(queue.takeDestinationBatch() == nil, "a held batch is not accounted as forwarded")
                var heldTracker = tracker
                expect(heldTracker.consumeKeyUp(49, isOriginal: true), "waiting for ACK retains physical ownership")
                queue.destinationAcknowledged()
                output += prepare(queue.takeDestinationBatch()!, &tracker)
                queue.destinationAcknowledged()
                output += prepare(queue.takeSessionBatch()!, &tracker)
            }
            expect(output == [repeatDown, release], "cancel/fallback preserves repeat down then release exactly once")
        }
        // The repeat itself can be the interrupt, routed through the session
        // batch, with its keyUp captured only while that batch is in flight.
        var tracker = PhysicalKeyReleaseTracker()
        tracker.replacedKeyDown(49)
        var queue = OrderedInputCancellation<Original>(originals: [], awaitingDestination: true)
        queue.enqueueInterrupt(repeatDown)
        if fallback {
            queue.enqueueInterrupt(release)
            let owned = queue.takeOwnedFallback()
            expect(prepare(owned.session, &tracker) == [repeatDown, release], "session fallback accounts each down before its up")
        } else {
            queue.destinationAcknowledged()
            var output = prepare(queue.takeSessionBatch()!, &tracker)
            queue.enqueueInterrupt(release)
            queue.sessionAcknowledged()
            output += prepare(queue.takeSessionBatch()!, &tracker)
            expect(output == [repeatDown, release], "late session release follows forwarded repeat")
        }
    }

    // Cancellation's punctuation preparation first consumes the third dot's
    // original up, then commits a fourth literal pair. The fourth original up
    // may already be queued or may arrive later; both must be consumed once.
    for capturedFourthUp in [false, true] {
        var tracker = PhysicalKeyReleaseTracker()
        tracker.replacedKeyDown(47)
        expect(tracker.consumeKeyUp(47, isOriginal: true), "third-dot up precedes fourth-dot replacement")
        tracker.replacedKeyDown(47)
        let pair = [Original(id: 3, key: 47, down: true, original: false),
                    Original(id: 4, key: 47, down: false, original: false)]
        if capturedFourthUp { expect(tracker.consumeKeyUp(47, isOriginal: true), "captured fourth-dot up is consumed in FIFO order") }
        expect(prepare(pair, &tracker) == pair, "own literal period pair never releases original ownership")
        if !capturedFourthUp { expect(tracker.consumeKeyUp(47, isOriginal: true), "late fourth-dot up is consumed") }
        expect(!tracker.consumeKeyUp(47, isOriginal: true), "neither dot can consume an extra up")
    }

    // If the run is interrupted by a modifier, a captured repeat is forwarded
    // unchanged. Irrevocable cancellation preparation must account it BEFORE
    // filtering a captured up, even though the batch is delivered after ACK.
    var tracker = PhysicalKeyReleaseTracker()
    tracker.replacedKeyDown(47)
    let rawRepeat = Original(id: 5, key: 47, down: true)
    let rawRelease = Original(id: 6, key: 47, down: false)
    let prepared = prepare([rawRepeat, rawRelease], &tracker)
    expect(prepared == [rawRepeat, rawRelease], "cancel preparation retains forwarded dot repeat's up")
    expect(prepare(prepared, &tracker) == prepared, "later delivery cannot consume an already retained up")

    print("Passed \(checks) physical key release checks")
    return checks
}
