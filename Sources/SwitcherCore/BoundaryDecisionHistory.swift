/// In-memory diagnostics for one asynchronous boundary at a time. Contains
/// identifiers, a character count and fixed reason strings, never typed text.
/// This observes decisions; it grants no permission and owns no input events.
public struct BoundaryDecisionHistory {
    public enum Outcome: String {
        case posted, preserved, cancelled, timedOut
    }
    public struct Entry {
        public let transactionID: UInt64
        public let processID: Int32
        public let characterCount: Int
        public let outcome: Outcome
        public let reason: String
    }
    private struct Pending {
        let id: UInt64
        let pid: Int32
        let length: Int
    }
    private let capacity: Int
    private var pending: Pending?
    public private(set) var entries: [Entry] = []

    public init(capacity: Int = 12) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    @discardableResult public mutating func begin(id: UInt64, processID: Int32, characterCount: Int) -> Bool {
        guard pending == nil, characterCount >= 0 else { return false }
        pending = Pending(id: id, pid: processID, length: characterCount)
        return true
    }

    /// Intermediate retries do not call this. Cancelled/late workers cannot
    /// overwrite a terminal decision or finish a newer transaction.
    @discardableResult public mutating func finish(id: UInt64, outcome: Outcome, reason: String) -> Bool {
        guard let value = pending, value.id == id else { return false }
        pending = nil
        entries.append(Entry(transactionID: id, processID: value.pid, characterCount: value.length,
                             outcome: outcome, reason: String(reason.prefix(240))))
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
        return true
    }
}
