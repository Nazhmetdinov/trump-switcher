import Foundation

/// Only reconciles a small, timestamp-bounded queue after our own source switch.
/// Key position/modifiers must match the old payload exactly. Other software's
/// injected text, dead keys, manual source changes and arbitrary mixed text stay.
public struct QueuedLayoutTransition {
    private struct Window {
        let previous: KeyboardLayoutTable
        let boundary: UInt64
        let deadline: UInt64
    }
    private let windows: [Window]
    /// Refuse another temporary switch rather than discard queued provenance.
    public var canPreserveAdditionalWindow: Bool { windows.count < 32 }
    public let previous: KeyboardLayoutTable
    public let target: KeyboardLayoutTable
    public let boundary: UInt64
    public let deadline: UInt64
    public init(previous: KeyboardLayoutTable, target: KeyboardLayoutTable, boundary: UInt64, selectedAt: UInt64) {
        self.init(previous: previous, target: target, boundary: boundary, selectedAt: selectedAt, preserving: nil)
    }
    /// A same-source correction does not invalidate an earlier real switch.
    public static func committed(previous: KeyboardLayoutTable, target: KeyboardLayoutTable, boundary: UInt64,
                                 selectedAt: UInt64, preserving prior: QueuedLayoutTransition?) -> QueuedLayoutTransition? {
        previous.id == target.id ? prior : QueuedLayoutTransition(previous: previous, target: target, boundary: boundary, selectedAt: selectedAt)
    }
    init(previous: KeyboardLayoutTable, target: KeyboardLayoutTable, boundary: UInt64, selectedAt: UInt64,
         preserving prior: QueuedLayoutTransition?) {
        self.previous = previous; self.target = target; self.boundary = boundary
        self.deadline = selectedAt > UInt64.max - 100_000_000 ? UInt64.max : selectedAt + 100_000_000
        // Earlier events retain their earlier source proof; never extend one
        // interval across the gap before our temporary source selection.
        let earlier = prior?.target.id == target.id ? prior!.windows.compactMap { window -> Window? in
            let end = min(window.deadline, boundary)
            return window.boundary < end ? Window(previous: window.previous, boundary: window.boundary, deadline: end) : nil
        } : []
        self.windows = earlier + [Window(previous: previous, boundary: boundary, deadline: self.deadline)]
    }
    public func normalized(_ text: String, code: UInt16, shift: Bool, capsLock: Bool, option: Bool,
                           timestamp: UInt64, currentID: String?, systemEvent: Bool) -> String? {
        guard systemEvent, currentID == target.id else { return nil }
        for window in windows where timestamp > window.boundary && timestamp <= window.deadline {
            if let old = window.previous.character(code: code, shift: shift, capsLock: capsLock, option: option), old == text,
               let new = target.character(code: code, shift: shift, capsLock: capsLock, option: option), new != text { return new }
        }
        return nil
    }
}
