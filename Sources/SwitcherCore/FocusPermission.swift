/// Permission belongs to a focus epoch, not just a process ID. Returning to the
/// same application after Settings/password entry needs a new safety probe.
public struct FocusPermission {
    public private(set) var permitted = false
    public private(set) var awaiting = false
    /// A background reply can still describe the control used to enter an
    /// editor. Recheck on the first key instead of waiting for the next timer.
    public var requiresKeyProbe: Bool { !permitted }
    public init() {}
    public mutating func begin() { permitted = false; awaiting = true }
    public mutating func resolve(_ allowed: Bool) { permitted = allowed; awaiting = false }
    public mutating func resolve(_ allowed: Bool, buffer: inout TypingBuffer) {
        resolve(allowed)
        if !allowed { buffer.invalidatePartialWord() }
    }
    public mutating func exclude() { resolve(false) }
}
