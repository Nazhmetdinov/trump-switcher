/// Quartz allocates a unique positive ID for a private source. -1 is only the
/// constructor sentinel, not the ID carried by all private keyboard events.
public enum KeyboardEventOrigin {
    public static func isSystem(stateID: Int64, userData: Int64) -> Bool {
        userData == 0 && (stateID == 0 || stateID == 1)
    }
}
