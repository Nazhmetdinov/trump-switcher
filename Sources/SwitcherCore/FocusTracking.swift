import Foundation

public enum FocusTracking {
    private static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXSecureTextField"]
    public static func sameIdentifiedField(previousIdentity: String?, nextIdentity: String?,
                                           previousRole: String?, nextRole: String?) -> Bool {
        guard let previousIdentity, previousIdentity.contains("/id/") else { return false }
        return previousIdentity == nextIdentity && previousRole == nextRole &&
            textRoles.contains(nextRole ?? "")
    }
    /// Equal geometry is useful for retaining typed characters, but it cannot
    /// prove that two AX wrappers belong to the same editor. Keep the token
    /// only with a mandatory exact whole-word read before any replacement.
    public static func needsWholeWordProof(identityChanged: Bool, sameLogicalField: Bool,
                                           sameIdentifiedField: Bool, previousRole: String?,
                                           nextRole: String?) -> Bool {
        identityChanged && sameLogicalField && !sameIdentifiedField &&
            textRoles.contains(previousRole ?? "") && textRoles.contains(nextRole ?? "")
    }
    /// Wrapper identity churn in Qt/web editors is not a new text field.
    /// Real text-field changes still invalidate an unfinished token.
    public static func shouldReset(previousRole: String?, nextRole: String?, identityChanged: Bool, alreadyReset: Bool, sameLogicalField: Bool = false) -> Bool {
        identityChanged && !alreadyReset && shouldCancelPending(previousRole: previousRole, nextRole: nextRole,
            identityChanged: identityChanged, sameLogicalField: sameLogicalField)
    }

    /// A new AX wrapper for the same logical composer must not cancel an
    /// already held word. The write edge still verifies the exact field and
    /// preceding text; a genuinely different field cancels immediately.
    public static func shouldCancelPending(previousRole: String?, nextRole: String?,
                                           identityChanged: Bool, sameLogicalField: Bool) -> Bool {
        identityChanged && !sameLogicalField && textRoles.contains(previousRole ?? "") &&
            textRoles.contains(nextRole ?? "")
    }
}
