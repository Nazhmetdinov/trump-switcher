import Foundation

/// Refuses a manual edit while originals are held or were just handed back to
/// an editor. A session hotkey may arrive after its Control modifier cancelled
/// the automatic transaction, so an empty FIFO alone is insufficient.
///
/// The main-thread owner supplies monotonic uptime and notes each final handoff
/// or delivery. This fixed grace is not proof that an editor applied its input.
/// The gate never schedules a manual retry, performs AX I/O, or owns a callback.
public struct ManualConversionGate {
    public static let settlingInterval: TimeInterval = 1
    public private(set) var blockUntil: TimeInterval = 0

    public init() {}

    public mutating func noteInputHandoff(at time: TimeInterval) {
        guard time.isFinite, time >= 0 else { blockUntil = .infinity; return }
        blockUntil = max(blockUntil, time + Self.settlingInterval)
    }

    /// False means cancel the automatic proposal in order and return to the
    /// user without invoking the manual read/write operation. An explicit later
    /// request may proceed after the last delivery's grace has elapsed.
    public mutating func request(hasPendingInput: Bool, at time: TimeInterval) -> Bool {
        guard time.isFinite, time >= 0 else { return false }
        if hasPendingInput {
            noteInputHandoff(at: time)
            return false
        }
        return time >= blockUntil
    }
}
