/// Ownership and ordering for an automatic edit which has been cancelled while
/// an older event batch is still in transit. Original input keeps its captured
/// destination; the interrupt and subsequent input return to the session stream.
///
/// The adapter supplies delivery acknowledgements only after checking its own
/// destination/session fence serial. Taking a batch transfers ownership before
/// posting: neither a timeout nor another cancellation may post that batch again.
public struct OrderedInputCancellation<Event> {
    public enum Phase: Equatable {
        case waitingDestination, readyDestination, readySession, waitingSession, finished
    }

    public private(set) var phase: Phase
    private let capacity: Int
    private var originals: [Event]
    private var interrupts: [Event] = []

    public init(originals: [Event], awaitingDestination: Bool, capacity: Int = 4096) {
        precondition(capacity > 0 && originals.count <= capacity)
        self.originals = originals
        self.capacity = capacity
        phase = awaitingDestination ? .waitingDestination :
            (originals.isEmpty ? .readySession : .readyDestination)
    }

    /// Counts only input still owned here. Transferred batches belong to the
    /// transport and are deliberately absent, including when its ACK is late.
    public var count: Int { originals.count + interrupts.count }

    /// False leaves this event with the caller. No existing event is evicted.
    @discardableResult public mutating func enqueueInterrupt(_ event: Event) -> Bool {
        guard phase != .finished, count < capacity else { return false }
        interrupts.append(event)
        return true
    }

    /// Never evaluates the original input for further corrections. Its sole
    /// remaining operation is delivery to the captured destination in order.
    public mutating func takeDestinationBatch() -> [Event]? {
        guard phase == .readyDestination else { return nil }
        let batch = originals
        originals.removeAll(keepingCapacity: false)
        phase = .waitingDestination
        return batch
    }

    /// The caller must reject stale/foreign fence acknowledgements first.
    @discardableResult public mutating func destinationAcknowledged() -> Bool {
        guard phase == .waitingDestination else { return false }
        phase = originals.isEmpty ? .readySession : .readyDestination
        return true
    }

    /// A session batch contains the interrupt followed by later input. An empty
    /// batch finishes without creating a fictitious event or acknowledgement.
    public mutating func takeSessionBatch() -> [Event]? {
        guard phase == .readySession else { return nil }
        let batch = interrupts
        interrupts.removeAll(keepingCapacity: false)
        phase = batch.isEmpty ? .finished : .waitingSession
        return batch
    }

    /// Input received while a session batch was in transit needs its own batch
    /// and fence. The live input gate opens only after the last ACK.
    @discardableResult public mutating func sessionAcknowledged() -> Bool {
        guard phase == .waitingSession else { return false }
        phase = interrupts.isEmpty ? .finished : .readySession
        return true
    }

    /// A timeout or saturation ends ordering guarantees, but cannot repeat any
    /// committed edit or transferred original. Preserve routing on the fallback.
    public mutating func takeOwnedFallback() -> (destination: [Event], session: [Event]) {
        let result = (destination: originals, session: interrupts)
        originals.removeAll(keepingCapacity: false)
        interrupts.removeAll(keepingCapacity: false)
        phase = .finished
        return result
    }
}
