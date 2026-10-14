// Headless model test. Compile with InputDeliveryQueue.swift,
// OrderedInputCancellation.swift and EllipsisBoundary.swift only.
// No AppKit/Carbon, input-source reads, event objects, application focus or UI.
import Foundation

private struct Event: Equatable {
    enum Effect: Equatable { case insert(String), erase, retarget(Int), neutral }
    let id: Int
    let pair: Int
    let down: Bool
    let effect: Effect
}
private struct Random {
    var state: UInt64
    mutating func next(_ bound: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int((state >> 32) % UInt64(bound))
    }
}
private func events(_ effects: [Event.Effect], start: Int = 0) -> [Event] {
    effects.enumerated().flatMap { offset, effect in
        let pair = start + offset
        return [Event(id: pair * 2, pair: pair, down: true, effect: effect),
                Event(id: pair * 2 + 1, pair: pair, down: false, effect: .neutral)]
    }
}
private func letters(_ text: String) -> [Event.Effect] { text.map { .insert(String($0)) } }

@main
private enum QueueModelChecks {
    static var assertions = 0
    static var schedules = 0
    static var fallbackSchedules = 0
    static var saturatedSchedules = 0
    static var earlySessionAttempts = 0

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
        assertions += 1
    }

    /// The oracle is the arrival ledger: original IDs retain destination A,
    /// interrupt IDs retain session routing, each exactly once and in order.
    /// It does not reimplement the gate's Phase state machine.
    static func run(effects: [Event.Effect], expectedTail: String, cut: Int, ownership: Int, seed: UInt64) {
        var random = Random(state: seed)
        let original = events(effects)
        let session = events([.retarget(2)] + letters("after ") + [.retarget(3)] + letters("tail"), start: 1000)
        let label = "seed=\(seed) cut=\(cut) ownership=\(ownership)"
        var queue = InputDeliveryQueue<Event>(capacity: original.count)
        for event in original { require(queue.enqueue(event), "arrival refused: " + label) }
        var posted: [(Int?, Event)] = [] // nil is session, Int is captured PID.
        var leases: [InputDeliveryQueue<Event>.Lease] = []
        for _ in 0..<cut {
            let lease = queue.beginDelivery()!
            leases.append(lease)
            posted.append((1, queue.commit(lease)!))
        }
        var pending: Event?
        if cut < original.count, ownership != 0 {
            let lease = queue.beginDelivery()!
            leases.append(lease)
            require(queue.beginDelivery() == nil, "two owners of one FIFO head: " + label)
            if ownership == 2 { pending = queue.transfer(lease) }
        }
        let captured = (pending.map { [$0] } ?? []) + queue.cancel()
        require(captured.map(\.id) == original.dropFirst(cut).map(\.id), "cancel reordered in-flight/transferred boundary: " + label)
        for lease in leases {
            require(queue.commit(lease) == nil && queue.transfer(lease) == nil, "stale frame duplicated input: " + label)
        }
        // A restarted generation must remain intact when an old callback fires.
        let sentinel = Event(id: -99, pair: -99, down: true, effect: .neutral)
        require(queue.enqueue(sentinel), "restarted queue unavailable: " + label)
        let fresh = queue.beginDelivery()!
        for old in leases { require(!queue.isActive(old), "old lease regained ownership: " + label) }
        require(queue.commit(fresh) == sentinel && queue.cancel().isEmpty, "old callback damaged new generation: " + label)

        let initiallyWaiting = random.next(2) == 0
        let capacity = max(captured.count, 1) + random.next(session.count + 1)
        var gate = OrderedInputCancellation(originals: captured, awaitingDestination: initiallyWaiting, capacity: capacity)
        // An empty prior batch means an already-posted replacement, never an
        // event owned by the cancellation gate. ACK is delayed independently.
        var destinationFence = initiallyWaiting
        var sessionFence = false
        var nextArrival = 0
        var ended = false
        var fallback = false

        func append(_ batch: [Event], destination: Int?) {
            posted += batch.map { (destination, $0) }
        }
        func takeDestination() {
            if let batch = gate.takeDestinationBatch() {
                require(!destinationFence && !sessionFence, "originals overtook an outstanding batch: " + label)
                append(batch, destination: 1)
                destinationFence = true
            }
        }
        func acknowledgeDestination() {
            let acknowledged = gate.destinationAcknowledged()
            require(acknowledged == destinationFence, "destination ACK completed wrong ownership: " + label)
            if acknowledged { destinationFence = false }
        }
        func takeSession() {
            if destinationFence { earlySessionAttempts += 1 }
            if let batch = gate.takeSessionBatch() {
                require(!destinationFence && !sessionFence, "interrupt overtook old originals: " + label)
                require(posted.filter { $0.0 == 1 }.map { $0.1.id } == original.map(\.id), "session route opened before every captured original: " + label)
                append(batch, destination: nil)
                if batch.isEmpty { ended = true } else { sessionFence = true }
            }
        }
        func acknowledgeSession() {
            let acknowledged = gate.sessionAcknowledged()
            require(acknowledged == sessionFence, "session ACK completed wrong ownership: " + label)
            if acknowledged {
                sessionFence = false
                if gate.phase == .finished { ended = true }
            }
        }
        func forceFallback() {
            let remaining = gate.takeOwnedFallback()
            append(remaining.destination, destination: 1)
            append(remaining.session, destination: nil)
            require(gate.takeOwnedFallback().destination.isEmpty && gate.takeOwnedFallback().session.isEmpty,
                    "reentrant fallback repeated ownership: " + label)
            require(!gate.destinationAcknowledged() && !gate.sessionAcknowledged(), "late ACK revived cancelled gate: " + label)
            destinationFence = false; sessionFence = false
            ended = true; fallback = true
        }
        func arrive() {
            guard nextArrival < session.count else { return }
            let event = session[nextArrival]
            nextArrival += 1
            if ended { append([event], destination: nil); return }
            if !gate.enqueueInterrupt(event) {
                saturatedSchedules += 1
                forceFallback()
                // The rejected event was never owned by either core queue.
                append([event], destination: nil)
            }
        }
        // Ensure the initiating interrupt belongs to the gate; later up/down
        // events arrive independently, including while session batches await ACK.
        arrive()
        for tick in 0..<96 where !ended || nextArrival < session.count {
            if ended { arrive(); continue }
            switch random.next(7) {
            case 0, 1: arrive()
            case 2: takeDestination()
            case 3: acknowledgeDestination()
            case 4: takeSession()
            case 5: acknowledgeSession()
            default:
                if tick > 8 && seed % 5 == 0 { forceFallback() }
            }
        }
        while nextArrival < session.count { arrive() }
        for _ in 0..<8 where !ended {
            if destinationFence { acknowledgeDestination() }
            takeDestination()
            if destinationFence { acknowledgeDestination() }
            takeSession()
            if sessionFence { acknowledgeSession() }
        }
        require(ended && gate.count == 0, "bounded schedule failed to drain: " + label)
        require(posted.filter { $0.0 == 1 }.map { $0.1.id } == original.map(\.id), "original IDs lost, duplicated, reordered or retargeted: " + label)
        require(posted.filter { $0.0 == nil }.map { $0.1.id } == session.map(\.id), "session IDs lost, duplicated or reordered: " + label)
        require(Set(posted.map { $0.1.id }).count == original.count + session.count, "duplicate event ID: " + label)
        var pressed = Set<Int>(), active = 1
        var documents = [1: "привет...", 2: "B:", 3: "C:"]
        for (destination, event) in posted {
            if event.down {
                require(pressed.insert(event.pair).inserted, "duplicate keyDown: " + label)
                let recipient = destination ?? active
                switch event.effect {
                case .insert(let text): documents[recipient, default: ""] += text
                case .erase:
                    require(!(documents[recipient] ?? "").isEmpty, "Backspace escaped its created text: " + label)
                    documents[recipient]!.removeLast()
                case .retarget(let target):
                    require(destination == nil, "retarget interrupt was rebound to old editor: " + label)
                    active = target
                case .neutral: break
                }
            } else {
                require(pressed.remove(event.pair) != nil, "keyUp overtook or duplicated keyDown: " + label)
            }
        }
        require(pressed.isEmpty, "key left down at end: " + label)
        require(documents[1] == "привет..." + expectedTail && documents[2] == "B:after " && documents[3] == "C:tail",
                "independent editor text/captured destination oracle disagrees: " + label)
        schedules += 1
        if fallback { fallbackSchedules += 1 }
    }

    static func punctuationContinuity() {
        // The expected literal punctuation is declared independently; fallback
        // text follows physical RU '.' position only after explicit invalidation.
        for totalDots in 3...12 {
            var continuation = EllipsisContinuation(code: 47, modifierBits: 0, sourceID: "ru", destinationPID: 1)
            var output = "привет..."
            for _ in 3..<totalDots {
                require(continuation.consume(code: 47, modifierBits: 0, sourceID: "ru", destinationPID: 1), "continuous punctuation disarmed")
                output += "."
            }
            require(output == "привет" + String(repeating: ".", count: totalDots), "punctuation swallowed or became ю")
            // A following word ends continuation; a later dot is a natural
            // key under the current source, not a permanent punctuation mode.
            require(!continuation.consume(code: 4, modifierBits: 0, sourceID: "ru", destinationPID: 1), "next word inherited punctuation")
            output += "р"
            output += continuation.consume(code: 47, modifierBits: 0, sourceID: "ru", destinationPID: 1) ? "." : "ю"
            require(output.hasSuffix("рю"), "punctuation mode leaked across next word")
        }
        for invalidation in 0..<4 {
            var continuation = EllipsisContinuation(code: 47, modifierBits: 0, sourceID: "ru", destinationPID: 1)
            switch invalidation {
            case 0: continuation.reset() // cancellation / same-PID focus change
            case 1: _ = continuation.consume(code: 47, modifierBits: 0, sourceID: "en", destinationPID: 1)
            case 2: _ = continuation.consume(code: 47, modifierBits: 0, sourceID: "ru", destinationPID: 2)
            default: _ = continuation.consume(code: 47, modifierBits: 1, sourceID: "ru", destinationPID: 1)
            }
            require(!continuation.consume(code: 47, modifierBits: 0, sourceID: "ru", destinationPID: 1), "metadata reverted after invalidation revived punctuation")
        }
    }

    static func main() {
        let scenarios: [([Event.Effect], String)] = [
            (letters(". hello "), ". hello "),
            (letters(".. hello "), ".. hello "),
            (letters("!? next "), "!? next "),
            (letters(" hello ") + [.erase] + letters("!"), " hello!"),
            (letters("  ") + [.erase, .erase] + letters(" world "), " world "),
            (letters("\nnext\tend"), "\nnext\tend")
        ]
        for (index, scenario) in scenarios.enumerated() {
            for cut in 0...events(scenario.0).count {
                for ownership in 0...2 {
                    for seed in 1...24 {
                        run(effects: scenario.0, expectedTail: scenario.1, cut: cut, ownership: ownership,
                            seed: UInt64(seed + index * 1000 + cut * 37 + ownership * 101))
                    }
                }
            }
        }
        punctuationContinuity()
        require(earlySessionAttempts > 0 && fallbackSchedules > 0 && saturatedSchedules > 0, "adversarial branches were not exercised")
        let result: [String: Any] = ["status": "passed", "schedules": schedules, "assertions": assertions,
            "fallbackSchedules": fallbackSchedules, "saturations": saturatedSchedules,
            "attemptsToOvertakeDestination": earlySessionAttempts,
            "scope": "Production pure queue/continuation policies; fixed semantic events and independent ID/routing/text oracle",
            "limitations": "No AutoMonitor adapter, AX/editor behavior, native input source, CGEvent, OS timing or live app validation",
            "uiAccess": false, "eventsPosted": 0, "sourceChanges": 0]
        print(String(data: try! JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
    }
}
