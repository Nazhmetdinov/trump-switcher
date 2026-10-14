import Foundation

/// A bounded, transient suffix check. The editor may have applied autocorrect,
/// smart dashes/ellipsis, a completion, or moved the selection since key capture.
public enum ReplacementContext {
    public static func matches(original: String, beforeCaret: String, afterCaret: String?, selectionLength: Int) -> Bool {
        guard selectionLength == 0, !original.isEmpty, beforeCaret.hasSuffix(original) else { return false }
        let prefix = beforeCaret.dropLast(original.count)
        func continuesWord(_ char: Character) -> Bool { char.isLetter || char.isNumber || char == "_" }
        if let previous = prefix.last, continuesWord(previous) { return false }
        if let next = afterCaret?.first, continuesWord(next) { return false }
        return true
    }
    public static func needsVerifiedText(_ original: String) -> Bool {
        original.contains("--") || original.contains("...")
    }
}
