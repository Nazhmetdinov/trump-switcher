public enum AccessibilityModeRequest {
    public struct Lease: Equatable {
        public let attribute: String
        public let restoreDisabled: Bool
    }
    /// Prefer the non-screen-reader API. A pre-existing enabled mode belongs
    /// to its original client; never disable it when this switcher stops.
    public static func acquire(read: (String) -> Bool?, enable: (String) -> Bool) -> Lease? {
        for attribute in ["AXManualAccessibility", "AXEnhancedUserInterface"] {
            let previous = read(attribute)
            if previous == true { return Lease(attribute: attribute, restoreDisabled: false) }
            if enable(attribute) { return Lease(attribute: attribute, restoreDisabled: previous == false) }
        }
        return nil
    }
}
