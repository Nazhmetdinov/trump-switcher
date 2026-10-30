/// Tracks only boundaries in originals returned after a cancelled edit.
/// Never detects/corrects replayed words or assumes an unknown suffix is complete.
public enum CancelledInputBoundary {
    public static func observe(key: UInt16, keyDown: Bool, click: Bool = false,
                               command: Bool = false, control: Bool = false,
                               option: Bool = false, shift: Bool = false, function: Bool = false,
                               buffer: inout TypingBuffer, replay: inout SessionReplayBoundary) {
        if click {
            buffer.reset(); replay.record(.focusNavigation); return
        }
        guard keyDown else { return }
        if let shortcut = TypingShortcut.action(code: key, command: command, control: control,
                                               option: option, shift: shift, function: function) {
            shortcut.apply(to: &buffer)
            switch shortcut {
            case .inputSource: replay.record(.unchanged)
            case .selectAll: replay.record(.boundary)
            case .invalidate:
                let appSwitch = key == 48 && command && !control && !option
                replay.record(appSwitch ? .focusNavigation : .unknownText)
            }
        } else if [UInt16(49), 36, 48, 76].contains(key) {
            buffer.rejectKey(wordBoundary: true); replay.record(.boundary)
        } else {
            buffer.rejectKey(wordBoundary: false); replay.record(.unknownText)
        }
    }
}
