import Foundation
import SwitcherCore

func pendingInputBudgetChecks() -> Int {
    var count = 0
    func expect(_ result: Bool, _ message: String) {
        precondition(result, "Pending input budget: " + message)
        count += 1
    }
    var idle = PendingInputBudget(startedAt: 10, idleTimeout: 1)
    expect(idle.noteInput(isKeyDown: false, at: 10.01) == nil, "boundary keyUp keeps idle grace")
    expect(!idle.expired(at: 10.75) && idle.expired(at: 11), "idle editor keeps existing grace")
    expect(idle.noteInput(isKeyDown: true, at: 10.9) == 11, "late typing never extends hard deadline")

    var busy = PendingInputBudget(startedAt: 0, idleTimeout: 1)
    let first = busy.noteInput(isKeyDown: true, at: 0.01)!
    expect(abs(first - 0.13) < 0.000001, "120 ms grace after continuing input")
    for i in 2...1000 {
        expect(busy.noteInput(isKeyDown: true, at: Double(i) / 1000) == nil,
               "a continuous burst cannot rearm the deadline")
    }
    expect(busy.deadline == first && busy.expired(at: first), "deadline is inclusive and fixed")
    expect(!busy.expired(at: first - 0.000001), "ready result before cutoff remains eligible")

    // Exercise real queue ownership with an independent arrival-order oracle.
    // A timeout and a late result race: only one may release the held boundary.
    // Key-down/up pairs are represented by distinct IDs; none can be lost,
    // reordered or duplicated on cancellation or a repeated late callback.
    for size in [2, 20, 200, 1000] {
        for transferredBoundary in [false, true] {
            for timerFirst in [false, true] {
                var queue = InputDeliveryQueue<Int>(capacity: 1024)
                var boundary: Int? = 0
                if transferredBoundary {
                    expect(queue.enqueue(0), "enqueue replayed boundary")
                    boundary = queue.transfer(queue.beginDelivery()!)
                }
                for id in 1...size { expect(queue.enqueue(id), "enqueue burst") }
                expect(queue.contains { $0 % 2 == 0 }, "replayed boundary sees queued down events")
                var budget = PendingInputBudget(startedAt: 1, idleTimeout: 1)
                _ = budget.noteInput(isKeyDown: true, at: 1.01)
                var delivered: [Int] = []
                var committed = false
                let deadline = budget.deadline
                func complete(at now: Double) {
                    guard let owned = boundary else { return }
                    if budget.expired(at: now) {
                        boundary = nil
                        delivered += [owned] + queue.cancel()
                    } else { committed = true }
                }
                if timerFirst {
                    complete(at: deadline)
                    complete(at: deadline + 0.3)
                } else {
                    // Main run loop delayed both callbacks; result is first.
                    complete(at: deadline + 0.3)
                    complete(at: deadline + 0.31)
                }
                expect(!committed, "late result cannot switch layout or edit")
                expect(delivered == Array(0...size), "all original pairs delivered once, in order")
                expect(queue.isEmpty && queue.cancel().isEmpty, "late timeout owns no events")
            }
        }
    }
    // Retired budgets have no shared state with the next word/field.
    let next = PendingInputBudget(startedAt: 20, idleTimeout: 1)
    expect(next.typingDeadline == nil && next.deadline == 21, "new transaction has independent grace")
    print("Passed \(count) pending-input latency and ownership checks")
    return count
}
