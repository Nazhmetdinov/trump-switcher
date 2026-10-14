/// Tracks the physical release of a down replaced with a balanced synthetic
/// pair. A subsequent original down (including autorepeat) delivered to the
/// editor needs its original up, even when the first down was replaced.
/// Enqueuing an undecided down must not call `forwardedKeyDown`.
public struct PhysicalKeyReleaseTracker {
    private var replacedPresses = Set<Int64>()

    public init() {}

    public mutating func replacedKeyDown(_ code: Int64) {
        replacedPresses.insert(code)
    }
    /// A balanced replacement already released this key in the destination.
    /// Its first forwarded repeat must start a new press before more repeats.
    public func needsRestoredPress(_ code: Int64, isOriginal: Bool, isRepeat: Bool) -> Bool {
        isOriginal && isRepeat && replacedPresses.contains(code)
    }

    /// Call at irrevocable original-input handoff, in FIFO order. Repeated
    /// handoff accounting is harmless; private/self events are never originals.
    public mutating func forwardedKeyDown(_ code: Int64, isOriginal: Bool) {
        if isOriginal { replacedPresses.remove(code) }
    }

    public mutating func consumeKeyUp(_ code: Int64, isOriginal: Bool) -> Bool {
        isOriginal && replacedPresses.remove(code) != nil
    }

    public mutating func reset() {
        replacedPresses.removeAll()
    }
}
