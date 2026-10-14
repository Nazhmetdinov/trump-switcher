import Carbon

public enum TypingShortcut: Equatable {
    case inputSource, selectAll, invalidate
    public static func action(code: UInt16, command: Bool, control: Bool, option: Bool, shift: Bool, function: Bool = false) -> Self? {
        // Option+Delete removes a word, Fn+Delete removes ahead of the caret.
        // Neither is a one-character backspace in the tracked token.
        if code == UInt16(kVK_Delete), option || function { return .invalidate }
        guard command || control else { return nil }
        if code == UInt16(kVK_Space), control, !command, !option { return .inputSource }
        if code == UInt16(kVK_ANSI_A), command, !control, !option, !shift { return .selectAll }
        return .invalidate
    }
    public func apply(to buffer: inout TypingBuffer) {
        switch self {
        case .inputSource: break
        case .selectAll: buffer.selectAll()
        case .invalidate: buffer.reset(startOfWord: false)
        }
    }
}
