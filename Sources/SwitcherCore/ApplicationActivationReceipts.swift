import Foundation

/// Receipt is captured before dispatching the notification to the keyboard
/// runloop. It proves whether a queued notification predates PID adoption.
public final class ApplicationActivationReceipts {
    public struct Receipt: Equatable {
        public let sequence: UInt64
        public let processID: Int32
    }
    private let lock = NSLock()
    private var sequence: UInt64 = 0
    private var latest: Receipt?
    public init() {}
    public func record(processID: Int32) -> Receipt {
        lock.lock(); defer { lock.unlock() }
        sequence &+= 1
        let receipt = Receipt(sequence: sequence, processID: processID)
        latest = receipt
        return receipt
    }
    public func current(for processID: Int32) -> Receipt? {
        lock.lock(); defer { lock.unlock() }
        return latest?.processID == processID ? latest : nil
    }
    public func clear() {
        lock.lock(); defer { lock.unlock() }
        latest = nil
    }
}
