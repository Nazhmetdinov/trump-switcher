import Foundation

/// The third literal period can end a verified word before an editor folds the
/// three characters into a single ellipsis. No dictionary decision is made here.
public enum EllipsisBoundary {
    public static func isCandidate(original: String, incoming: String) -> Bool {
        incoming == "." && (3...127).contains(original.utf16.count)
            && original.hasSuffix("..") && !original.hasSuffix("...")
    }

    /// Both strings must come from the usual detector with the same destination
    /// layout. The caller checks that layout identity; this policy requires the
    /// complete answer to preserve all three dots and the separately known stem.
    public static func permits(original: String, correctionText: String, correctedStem: String?) -> Bool {
        guard isCandidate(original: original, incoming: "."),
              let correctedStem, !correctedStem.isEmpty,
              correctionText == correctedStem + "...",
              correctedStem.first?.isLetter == true, correctedStem.last?.isLetter == true,
              correctedStem.allSatisfy({ $0.isLetter || $0 == "-" || $0 == "'" || $0 == "’" }) else { return false }
        let originalStem = original.dropLast(2)
        // Never commit part of explicit address/code syntax on an early trigger.
        // Literal periods within a real mistyped word remain possible (ю on ABC),
        // but the independent whole-stem detector above must recognize that word.
        return !originalStem.contains(where: { $0.isNumber || $0.isWhitespace || ":/@\\_=?#%&+|<>".contains($0) })
    }
}

/// Bounded metadata for additional presses of the same physical dot key after
/// correction changed the layout. No text/history accumulates, and elapsed time
/// alone does not invalidate a physically continuous punctuation sequence.
public struct EllipsisContinuation {
    private struct Identity {
        let code: UInt16
        let modifierBits: UInt64
        let sourceID: String
        let destinationPID: Int32
    }
    private var identity: Identity?
    public var isActive: Bool { identity != nil }

    public init(code: UInt16, modifierBits: UInt64, sourceID: String, destinationPID: Int32) {
        if !sourceID.isEmpty, destinationPID > 0 {
            identity = Identity(code: code, modifierBits: modifierBits, sourceID: sourceID, destinationPID: destinationPID)
        }
    }
    public mutating func reset() { identity = nil }

    /// The first mismatch disarms the sequence permanently. The caller also
    /// resets on a same-process field/focus change, cancellation or disablement.
    public mutating func consume(code: UInt16, modifierBits: UInt64, sourceID: String, destinationPID: Int32) -> Bool {
        guard let identity, identity.code == code, identity.modifierBits == modifierBits,
              identity.sourceID == sourceID, identity.destinationPID == destinationPID else {
            reset()
            return false
        }
        return true
    }
}
