import Foundation

public enum FocusTracking {
    public enum PendingPhase { case deciding, delivering }
    private static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXSecureTextField"]
    /// Some editors reuse one AX object for different controls. A changed
    /// stable identifier is a field change even when CFEqual still succeeds.
    /// Geometry may change while typing, so it is not a stable identity here.
    public static func changed(previousIdentity: String?, nextIdentity: String?,
                               previousRole: String?, nextRole: String?, sameElement: Bool) -> Bool {
        guard sameElement else { return true }
        guard let previousIdentity, let nextIdentity,
              previousIdentity.contains("/id/"), nextIdentity.contains("/id/") else { return false }
        return previousIdentity != nextIdentity || previousRole != nextRole
    }
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

    /// A geometry match cannot authorize a pending edit. Once the edit was
    /// committed, however, wrapper recreation must not cancel its ordered
    /// delivery or discard the next complete word. Every later edit still
    /// needs its own exact field/text preflight.
    public static func shouldCancelInput(previousRole: String?, nextRole: String?,
                                         identityChanged: Bool, sameIdentifiedField: Bool,
                                         sameCapturedField: Bool, phase: PendingPhase) -> Bool {
        shouldCancelPending(previousRole: previousRole, nextRole: nextRole,
            identityChanged: identityChanged, sameLogicalField: sameIdentifiedField) &&
            (phase == .deciding || !sameCapturedField)
    }
}
