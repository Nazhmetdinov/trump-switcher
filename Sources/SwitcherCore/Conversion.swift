import Foundation

public enum Layout: Equatable { case english, russian }

public enum Conversion {
    /// Group roles alone do not authorize editing. Chromium contenteditable
    /// roots can expose AXGroup, with themselves as AXEditableAncestor.
    public static func allowedEditableGroup(role: String?, subrole: String?, enabled: Bool?,
                                            editableRoot: Bool, boundedRead: Bool, selectionWritable: Bool) -> Bool {
        role == "AXGroup" && (subrole == nil || subrole == "AXUnknown") && enabled == true &&
            editableRoot && boundedRead && selectionWritable
    }
    public static func allowedField(role: String?, subrole: String?, enabled: Bool?) -> Bool {
        guard enabled != false, subrole != "AXSecureTextField" else { return false }
        // Native NSTextView has AXTextArea role and may omit AXEnabled and subrole.
        // NSTextField can also omit AXSubrole. Its standard text role and an
        // explicit enabled state are sufficient here; TextAccess separately
        // rejects protected content and verifies bounded access/write support.
        if role == "AXTextArea" { return subrole == nil || subrole == "AXUnknown" }
        return role == "AXTextField" && (subrole == nil || subrole == "AXUnknown") && enabled == true
    }

    // Standard US and Russian ЙЦУКЕН. Other layouts are deliberately unsupported.
    private static let english = Array("`qwertyuiop[]asdfghjkl;'zxcvbnm,./~QWERTYUIOP{}ASDFGHJKL:\"ZXCVBNM<>?@#$^&|")
    private static let russian = Array("ёйцукенгшщзхъфывапролджэячсмитьбю.ЁЙЦУКЕНГШЩЗХЪФЫВАПРОЛДЖЭЯЧСМИТЬБЮ,\"№;:?/")

    public static func direction(_ text: String) -> Layout? {
        let latin = text.unicodeScalars.contains { (65...90).contains($0.value) || (97...122).contains($0.value) }
        let cyrillic = text.unicodeScalars.contains { (0x410...0x44f).contains($0.value) || $0.value == 0x401 || $0.value == 0x451 }
        guard latin != cyrillic else { return nil }
        return latin ? .russian : .english
    }

    public static func convert(_ text: String, to target: Layout) -> String {
        let pairs = target == .russian ? zip(english, russian) : zip(russian, english)
        let map = Dictionary(uniqueKeysWithValues: pairs)
        return String(text.map { map[$0] ?? $0 })
    }

    /// UTF-16 offsets match the Accessibility API. Trailing spaces remain untouched.
    public static func lastToken(in text: String) -> NSRange? {
        let chars = Array(text)
        var end = chars.count
        while end > 0 && chars[end - 1].isWhitespace { end -= 1 }
        guard end > 0 else { return nil }
        var start = end
        while start > 0 && !chars[start - 1].isWhitespace { start -= 1 }
        // A full bounded window may start in the middle of a word: never truncate it.
        guard start > 0 || text.utf16.count < 128 else { return nil }
        return NSRange(location: String(chars[..<start]).utf16.count,
                       length: String(chars[start..<end]).utf16.count)
    }

    public static func deniedApp(_ id: String) -> Bool {
        let prefixes = ["com.1password.", "com.agilebits.", "com.bitwarden.", "org.keepassxc.",
                        "com.apple.keychainaccess", "com.apple.Passwords", "com.apple.loginwindow",
                        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
                        "dev.warp.", "net.kovidgoyal.kitty", "io.alacritty", "com.github.wez."]
        return prefixes.contains { id.lowercased().hasPrefix($0.lowercased()) }
    }
}
