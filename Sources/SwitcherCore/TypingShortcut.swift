import Carbon

public enum TypingShortcut: Equatable {
    case inputSource, selectAll, moveCaret, invalidate
    public static func action(code: UInt16, command: Bool, control: Bool, option: Bool, shift: Bool, function: Bool = false) -> Self? {
        // Option+Delete removes a word, Fn+Delete removes ahead of the caret.
        // Neither is a one-character backspace in the tracked token.
        if code == UInt16(kVK_Delete), option || function { return .invalidate }
        // A navigation key may invalidate the old word without losing the
        // first one at the new position. Ctrl+arrows can change Spaces, so
        // keep those in the normal context-invalidating shortcut path.
        if !control {
            switch Int(code) {
            case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
                 kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown:
                return .moveCaret
            default: break
            }
        }
        guard command || control else { return nil }
        if code == UInt16(kVK_Space), control, !command, !option { return .inputSource }
        if code == UInt16(kVK_ANSI_A), command, !control, !option, !shift { return .selectAll }
        return .invalidate
    }
    public func apply(to buffer: inout TypingBuffer) {
        switch self {
        case .inputSource: break
        case .selectAll: buffer.selectAll()
        case .moveCaret: buffer.beginAtMovedCaret()
        case .invalidate: buffer.reset(startOfWord: false)
        }
    }
}
