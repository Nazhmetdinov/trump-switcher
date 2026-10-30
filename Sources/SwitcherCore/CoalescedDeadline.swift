import Foundation

/// At most one scheduled wakeup for a succession of transport fences. Advancing
/// the deadline does not allocate a timer (or retain another keyboard event).
public struct CoalescedDeadline {
    public enum Wake: Equatable { case idle, reschedule(TimeInterval), expired }
    private var scheduled = false
    private var deadline: TimeInterval?
    public init() {}
    public mutating func arm(until deadline: TimeInterval) -> TimeInterval? {
        self.deadline = deadline
        guard !scheduled else { return nil }
        scheduled = true
        return deadline
    }
    public mutating func disarm() { deadline = nil }
    public mutating func wake(at now: TimeInterval) -> Wake {
        scheduled = false
        guard let deadline else { return .idle }
        if now < deadline {
            scheduled = true
            return .reschedule(deadline)
        }
        self.deadline = nil
        return .expired
    }
}
