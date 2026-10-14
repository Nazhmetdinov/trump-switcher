/// Workspace notifications may arrive after keys from the newly active app.
/// They invalidate focus permission, but cannot turn a partial/replayed word
/// into a fresh token. A PID alone cannot prove a same-app notification is a
/// duplicate: the user may have left and returned without typing elsewhere.
public enum ApplicationActivationPolicy {
    public enum Decision: Equatable {
        case ignoreStale
        case invalidate(startOfWord: Bool)
        case verifyWholeWord
        case refreshOnly
    }

    public static func decision(notifiedPID: Int32?, frontmostPID: Int32?,
                                buffer: TypingBuffer, hasPendingInput: Bool,
                                trackedPID: Int32? = nil, receiptAlreadyApplied: Bool = false) -> Decision {
        if let notifiedPID, let frontmostPID, notifiedPID > 0, frontmostPID > 0,
           notifiedPID != frontmostPID {
            return .ignoreStale
        }
        if let notifiedPID, let frontmostPID, notifiedPID > 0, notifiedPID == frontmostPID,
           trackedPID == frontmostPID, receiptAlreadyApplied {
            return .refreshOnly
        }
        if let notifiedPID, let frontmostPID, notifiedPID > 0, notifiedPID == frontmostPID,
           trackedPID == frontmostPID, !hasPendingInput,
           buffer.isAccepting, !buffer.token.isEmpty {
            return .verifyWholeWord
        }
        var invalidated = buffer
        invalidated.invalidatePartialWord()
        // finishWord() empties the buffer before the held boundary is delivered.
        // Its queue may already own the beginning of the following word.
        return .invalidate(startOfWord: !hasPendingInput && invalidated.isAccepting)
    }
}
