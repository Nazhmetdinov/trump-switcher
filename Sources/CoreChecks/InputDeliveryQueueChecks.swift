import SwitcherCore

func inputDeliveryQueueChecks() -> Int {
    var count = 0
    func expect(_ condition: @autoclosure () -> Bool, _ reason: String) {
        guard condition() else { fatalError("Input delivery queue: " + reason) }
        count += 1
    }

    // Reproduce cancellation during process(current). removeFirst()+flush used
    // to post the tail first and the already removed current event last.
    for size in [1, 2, 3, 16, 256] {
        for cancelAt in 0..<size {
            var queue = InputDeliveryQueue<Int>()
            var accepted = true
            for value in 0..<size { accepted = queue.enqueue(value) && accepted }
            expect(accepted, "accept input within capacity")
            var delivered: [Int] = []
            for _ in 0..<cancelAt {
                let lease = queue.beginDelivery()!
                delivered.append(queue.commit(lease)!)
            }
            let current = queue.beginDelivery()!
            expect(queue.beginDelivery() == nil, "never execute two in-flight events")
            delivered += queue.cancel()
            expect(queue.commit(current) == nil, "cancelled process return cannot duplicate current event")
            expect(queue.transfer(current) == nil, "cancelled event cannot become a late boundary")
            expect(delivered == Array(0..<size), "cancel flush preserves exact FIFO order including current")
            expect(queue.isEmpty && queue.cancel().isEmpty, "repeated cancellation never redelivers input")
        }
    }

    for size in [1, 2, 16, 256] {
        var queue = InputDeliveryQueue<Int>(capacity: size)
        for value in 0..<size { _ = queue.enqueue(value) }
        let current = queue.beginDelivery()!
        expect(queue.count == size && !queue.enqueue(size), "capacity includes the in-flight event")
        var delivered = queue.cancel()
        // Overflow was never owned, so the caller must pass it after the flush.
        delivered.append(size)
        expect(delivered == Array(0...size), "saturation preserves queued input plus incoming overflow")
        expect(!queue.isActive(current), "overflow cancellation invalidates old callback")
        _ = queue.enqueue(1000)
        let next = queue.beginDelivery()!
        expect(queue.commit(current) == nil && queue.isActive(next), "stale callback cannot consume a newer generation")
        expect(queue.commit(next) == 1000 && queue.commit(next) == nil, "exactly one delivery after restarting queue")
    }

    // A replayed boundary moves from inFlight to pending, never both at once.
    for cancelPending in [false, true] {
        var queue = InputDeliveryQueue<String>()
        ["space-down", "space-up", "next-down", "next-up"].forEach { _ = queue.enqueue($0) }
        let boundary = queue.beginDelivery()!
        let pending = queue.transfer(boundary)!
        expect(!queue.hasInFlight && queue.count == 3, "transfer removes only the boundary from queue ownership")
        var delivered: [String] = []
        if cancelPending { delivered.append(pending); delivered += queue.cancel() }
        else {
            delivered.append(pending)
            while let next = queue.beginDelivery() { delivered.append(queue.commit(next)!) }
        }
        expect(delivered == ["space-down", "space-up", "next-down", "next-up"], "pending completion/cancel preserves down-up order")
        expect(queue.commit(boundary) == nil, "transferred boundary cannot be posted twice by its old drain frame")
    }

    var first = InputDeliveryQueue<Int>(), second = InputDeliveryQueue<Int>()
    _ = first.enqueue(1); _ = second.enqueue(2)
    let firstLease = first.beginDelivery()!, secondLease = second.beginDelivery()!
    expect(second.commit(firstLease) == nil && first.commit(secondLease) == nil, "leases cannot target another destination queue")
    expect(first.commit(firstLease) == 1 && second.commit(secondLease) == 2, "foreign leases leave rightful input intact")
    print("Passed \(count) input delivery queue checks")
    return count
}
