import Foundation

/// A bounded, transient suffix check. The editor may have applied autocorrect,
/// smart dashes/ellipsis, a completion, or moved the selection since key capture.
public enum ReplacementContext {
    public static func matches(original: String, beforeCaret: String, afterCaret: String?, selectionLength: Int, insertingSpace: Bool = false) -> Bool {
        guard selectionLength == 0, !original.isEmpty, beforeCaret.hasSuffix(original) else { return false }
        let prefix = beforeCaret.dropLast(original.count)
        func continuesWord(_ char: Character) -> Bool { char.isLetter || char.isNumber || char == "_" }
        if let previous = prefix.last, continuesWord(previous) { return false }
        if let next = afterCaret?.first, continuesWord(next) {
            // The held space will separate the new word from existing text.
            // Only accept an exact left edge at document start or whitespace.
            return insertingSpace && (prefix.last?.isWhitespace ?? true)
        }
        return true
    }
    public static func needsVerifiedText(_ original: String) -> Bool {
        original.contains("--") || original.contains("...")
    }
}
