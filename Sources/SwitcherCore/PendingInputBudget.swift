import Foundation

/// A read-only correction may wait for an idle editor, but must not hold a
/// continuing typist behind that entire grace period. No text or key data.
public struct PendingInputBudget {
    public static let continuedTypingGrace: TimeInterval = 0.12
    public let idleDeadline: TimeInterval
    public private(set) var typingDeadline: TimeInterval?
    public var deadline: TimeInterval { typingDeadline ?? idleDeadline }

    public init(startedAt: TimeInterval, idleTimeout: TimeInterval) {
        precondition(startedAt.isFinite && idleTimeout.isFinite && idleTimeout > 0)
        idleDeadline = startedAt + idleTimeout
    }

    /// Arm only once: further keys must not slide the deadline indefinitely.
    /// Key releases and modifier-only events do not count as continued typing.
    @discardableResult
    public mutating func noteInput(isKeyDown: Bool, at now: TimeInterval) -> TimeInterval? {
        guard isKeyDown, typingDeadline == nil else { return nil }
        typingDeadline = min(idleDeadline, now + Self.continuedTypingGrace)
        return typingDeadline
    }

    public func expired(at now: TimeInterval) -> Bool { now >= deadline }
}
