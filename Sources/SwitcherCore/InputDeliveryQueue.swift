import Foundation

/// Bounded FIFO for input temporarily removed from an OS event stream.
/// The owner retains the original destination for this queue's entire lifetime.
/// Posting events and deciding whether a correction is safe stay in the caller.
public struct InputDeliveryQueue<Event> {
    public struct Lease {
        public let event: Event
        fileprivate let queueID: UUID
        fileprivate let epoch: UInt64
        fileprivate let serial: UInt64
    }

    private let identity = UUID()
    private let capacity: Int
    private var epoch: UInt64 = 0
    private var serial: UInt64 = 0
    private var queued: [Event] = []
    private var inFlight: Lease?

    public init(capacity: Int = 256) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    public var count: Int { queued.count + (inFlight == nil ? 0 : 1) }
    public var isEmpty: Bool { count == 0 }
    public var hasInFlight: Bool { inFlight != nil }

    /// False means the caller must preserve this incoming event itself; no
    /// event already owned by the queue is discarded to make room.
    @discardableResult public mutating func enqueue(_ event: Event) -> Bool {
        guard count < capacity else { return false }
        queued.append(event)
        return true
    }

    /// The current event remains owned by the queue until commit/transfer.
    /// A cancellation inside process(event) therefore flushes it BEFORE its tail.
    public mutating func beginDelivery() -> Lease? {
        guard inFlight == nil, !queued.isEmpty else { return nil }
        serial &+= 1
        let lease = Lease(event: queued.removeFirst(), queueID: identity, epoch: epoch, serial: serial)
        inFlight = lease
        return lease
    }

    public func isActive(_ lease: Lease) -> Bool {
        lease.queueID == identity && lease.epoch == epoch && inFlight?.serial == lease.serial
    }

    /// Returns the event exactly once. The caller may now post it or consume it
    /// as part of a completed correction. A cancellation invalidates stale leases.
    public mutating func commit(_ lease: Lease) -> Event? {
        guard isActive(lease) else { return nil }
        inFlight = nil
        return lease.event
    }

    /// Transfer ownership to a pending-boundary transaction. Install that
    /// pending state immediately, without callbacks/yields between these steps.
    public mutating func transfer(_ lease: Lease) -> Event? { commit(lease) }

    /// Clears ownership BEFORE the caller posts anything, so reentrant input
    /// cannot duplicate the batch. The executing event precedes all queued input.
    public mutating func cancel() -> [Event] {
        let batch = inFlight.map { [$0.event] } ?? []
        let result = batch + queued
        inFlight = nil
        queued.removeAll(keepingCapacity: true)
        epoch &+= 1
        return result
    }
}
