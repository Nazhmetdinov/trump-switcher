/// A cancelled session batch can type in a newly activated app before its PID
/// is adopted. Keep only boundary provenance, never text or destination history.
/// Metadata changes cannot turn its unobserved prefix into a fresh word.
public struct SessionReplayBoundary {
    public enum Effect {
        case unknownText, boundary, focusNavigation, unchanged
    }

    public private(set) var requiresBoundary = false
    public init() {}

    public mutating func record(_ effect: Effect) {
        switch effect {
        case .unknownText: requiresBoundary = true
        case .boundary, .focusNavigation: requiresBoundary = false
        case .unchanged: break
        }
    }

    /// Call only after processing original input, not after a focus probe or
    /// notification. A real boundary/known reset can reopen an invalid token.
    public mutating func observeProcessedBuffer(_ buffer: TypingBuffer) {
        if buffer.isAccepting { requiresBoundary = false }
    }

    public func startOfWordOnPIDChange() -> Bool { !requiresBoundary }
}
