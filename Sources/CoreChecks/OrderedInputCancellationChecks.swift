import SwitcherCore

func orderedInputCancellationChecks() -> Int {
    var count = 0
    func expect(_ condition: @autoclosure () -> Bool, _ reason: String) {
        guard condition() else { fatalError("Ordered input cancellation: " + reason) }
        count += 1
    }

    // These are semantic event labels, not real keyboard/pointer input. The fake
    // transport deliberately postpones ACKs and records the chosen destination.
    for interrupt in ["command-A", "command-tab", "control-space", "mouse-down", "foreign-key"] {
        var gate = OrderedInputCancellation(originals: ["old-space-up", "old-letter-down", "old-letter-up"],
                                            awaitingDestination: true)
        var transport = ["destination:committed-replacement"]
        expect(gate.enqueueInterrupt(interrupt), "own interrupt during older delivery")
        expect(gate.enqueueInterrupt("later-key-down"), "own later input after interrupt")
        expect(gate.takeDestinationBatch() == nil && gate.takeSessionBatch() == nil,
               "nothing overtakes the already committed destination batch")
        expect(!gate.sessionAcknowledged(), "a session ACK cannot discharge a destination fence")
        expect(gate.destinationAcknowledged(), "matching prior destination ACK unlocks old originals")
        expect(gate.phase == .readyDestination && !gate.destinationAcknowledged(),
               "an extra ACK before taking originals has no effect")
        let originals = gate.takeDestinationBatch()!
        transport += originals.map { "destination:" + $0 }
        expect(gate.count == 2 && gate.takeDestinationBatch() == nil,
               "taking originals transfers ownership once")
        expect(gate.takeSessionBatch() == nil, "posting originals does not mean they were delivered")
        expect(gate.destinationAcknowledged(), "original delivery ACK unlocks session interrupt")
        let session = gate.takeSessionBatch()!
        transport += session.map { "session:" + $0 }
        expect(gate.phase == .waitingSession && gate.takeSessionBatch() == nil,
               "posting session input keeps the gate closed")
        expect(gate.enqueueInterrupt("later-key-up"), "own new input while session batch is in transit")
        expect(!gate.destinationAcknowledged(), "late destination ACK cannot complete session delivery")
        expect(gate.sessionAcknowledged() && gate.phase == .readySession,
               "session ACK leaves its later backlog gated")
        transport += gate.takeSessionBatch()!.map { "session:" + $0 }
        expect(gate.phase == .waitingSession && gate.sessionAcknowledged() && gate.phase == .finished,
               "only the final session ACK completes cancellation")
        expect(transport == ["destination:committed-replacement", "destination:old-space-up",
            "destination:old-letter-down", "destination:old-letter-up", "session:" + interrupt,
            "session:later-key-down", "session:later-key-up"], "exact order and routing survive cancellation")
        expect(!gate.enqueueInterrupt("after-completion") && !gate.sessionAcknowledged(),
               "finished ownership cannot absorb new input or duplicate a completion")
        let fallback = gate.takeOwnedFallback()
        expect(fallback.destination.isEmpty && fallback.session.isEmpty, "completed events never reappear on timeout")
    }

    // A click must keep its drag/release and subsequent keyboard input ordered
    // through the session route. No pointer is rebound to the old application.
    var pointer = OrderedInputCancellation(originals: ["old-key"], awaitingDestination: false)
    ["mouse-down", "mouse-drag", "mouse-up", "new-field-key"].forEach { _ = pointer.enqueueInterrupt($0) }
    expect(pointer.takeSessionBatch() == nil, "pointer waits for queued old key")
    expect(pointer.takeDestinationBatch() == ["old-key"], "old key remains on destination route")
    _ = pointer.destinationAcknowledged()
    expect(pointer.takeSessionBatch() == ["mouse-down", "mouse-drag", "mouse-up", "new-field-key"],
           "complete pointer sequence and subsequent key retain session routing")
    expect(pointer.phase != .finished, "pointer post is not pointer delivery")
    _ = pointer.sessionAcknowledged()
    expect(pointer.phase == .finished, "pointer sequence completes after ACK")

    // Manual conversion/stop can wait for the old cohort without a session
    // interrupt. There is no fabricated empty fence to wait for forever.
    for originals in [[], ["old-key"]] {
        var manual = OrderedInputCancellation(originals: originals, awaitingDestination: true)
        expect(manual.takeSessionBatch() == nil, "manual work cannot overtake old committed input")
        _ = manual.destinationAcknowledged()
        if !originals.isEmpty {
            expect(manual.takeDestinationBatch() == originals, "manual work drains only originals")
            expect(manual.phase != .finished, "manual work still waits for originals ACK")
            _ = manual.destinationAcknowledged()
        }
        expect(manual.takeSessionBatch() == [] && manual.phase == .finished,
               "manual continuation is ready only after the old cohort drains")
    }

    // At every transfer boundary, fallback can return only unposted ownership.
    // The committed replacement is never supplied to this state machine.
    for stage in 0...3 {
        var gate = OrderedInputCancellation(originals: ["original-down", "original-up"], awaitingDestination: true)
        _ = gate.enqueueInterrupt("interrupt-down")
        var transferredOriginals: [String] = [], transferredSession: [String] = []
        if stage >= 1 { _ = gate.destinationAcknowledged() }
        if stage >= 2 { transferredOriginals = gate.takeDestinationBatch()! }
        if stage >= 3 {
            _ = gate.destinationAcknowledged()
            transferredSession = gate.takeSessionBatch()!
        }
        _ = gate.enqueueInterrupt("interrupt-up")
        let fallback = gate.takeOwnedFallback()
        expect(transferredOriginals + fallback.destination == ["original-down", "original-up"],
               "timeout conserves original ownership exactly once at stage \(stage)")
        expect(transferredSession + fallback.session == ["interrupt-down", "interrupt-up"],
               "timeout conserves session ownership exactly once at stage \(stage)")
        expect(gate.phase == .finished && !gate.destinationAcknowledged() && !gate.sessionAcknowledged(),
               "timeout invalidates late delivery callbacks")
        let again = gate.takeOwnedFallback()
        expect(again.destination.isEmpty && again.session.isEmpty, "second timeout cannot duplicate fallback")
    }

    var saturated = OrderedInputCancellation(originals: ["old"], awaitingDestination: true, capacity: 3)
    expect(saturated.enqueueInterrupt("interrupt") && saturated.enqueueInterrupt("later"), "bounded gate accepts its capacity")
    expect(!saturated.enqueueInterrupt("overflow") && saturated.count == 3, "saturation leaves overflow with caller")
    let fallback = saturated.takeOwnedFallback()
    expect(fallback.destination == ["old"] && fallback.session + ["overflow"] == ["interrupt", "later", "overflow"],
           "saturation preserves owned input and separately owned overflow")

    print("Passed \(count) ordered input cancellation checks")
    return count
}
