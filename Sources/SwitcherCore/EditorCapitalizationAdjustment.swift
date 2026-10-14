import Foundation

/// An editor may capitalize the first character after the physical keystroke
/// was captured. Admit only that one exact change; never compare whole words
/// case-insensitively or use it for an unverified/opaque field.
public struct EditorCapitalizationAdjustment: Equatable {
    public let actualOriginal: String
    public let replacement: String

    /// A source-only check for the read-only preflight. Its result must also be
    /// the exact source used by the final focus/caret revalidation at write time.
    public static func verifiedOriginal(original: String, beforeCaret: String,
                                        afterCaret: String?, selectionLength: Int) -> String? {
        guard (1...128).contains(original.utf16.count), let first = original.first,
              let uppercase = capitalizedLetter(first, requireLowercase: true) else { return nil }
        let observed = uppercase + original.dropFirst()
        guard observed.utf16.count == original.utf16.count,
              ReplacementContext.matches(original: observed, beforeCaret: beforeCaret,
                                         afterCaret: afterCaret, selectionLength: selectionLength) else { return nil }
        return observed
    }

    /// Apply the verified editor capitalization to an already-approved layout
    /// correction. Explicit user-rule outputs should keep their declared case.
    public static func verified(original: String, replacement: String, beforeCaret: String,
                                afterCaret: String?, selectionLength: Int) -> Self? {
        guard let observed = verifiedOriginal(original: original, beforeCaret: beforeCaret,
                                             afterCaret: afterCaret, selectionLength: selectionLength),
              (1...128).contains(replacement.utf16.count), let first = replacement.first,
              let uppercase = capitalizedLetter(first, requireLowercase: false) else { return nil }
        let adjusted = uppercase + replacement.dropFirst()
        guard adjusted.utf16.count == replacement.utf16.count else { return nil }
        return Self(actualOriginal: observed, replacement: adjusted)
    }

    private static func capitalizedLetter(_ character: Character, requireLowercase: Bool) -> String? {
        // Fixed one-scalar mappings avoid locale rules, normalization, Unicode
        // case-fold expansion (ß → SS), and combining-character substitutions.
        let scalars = character.unicodeScalars
        guard scalars.count == 1, let value = scalars.first?.value else { return nil }
        let uppercase: UInt32
        switch value {
        case 0x61...0x7a, 0x430...0x44f: uppercase = value - 0x20
        case 0x451: uppercase = 0x401
        case 0x41...0x5a, 0x410...0x42f, 0x401:
            guard !requireLowercase else { return nil }
            uppercase = value
        default: return nil
        }
        return UnicodeScalar(uppercase).map(String.init)
    }
}
