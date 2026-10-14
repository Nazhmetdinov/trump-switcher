import Foundation

public enum FocusTracking {
    /// Wrapper identity churn in Qt/web editors is not a new text field.
    /// Real text-field changes still invalidate an unfinished token.
    public static func shouldReset(previousRole: String?, nextRole: String?, identityChanged: Bool, alreadyReset: Bool, sameLogicalField: Bool = false) -> Bool {
        let roles: Set<String> = ["AXTextField", "AXTextArea", "AXSecureTextField"]
        return identityChanged && !alreadyReset && !sameLogicalField && roles.contains(previousRole ?? "") && roles.contains(nextRole ?? "")
    }
}
