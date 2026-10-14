import Foundation

/// Only the current physically typed token; never a document or previous words.
public struct TypingBuffer {
    public private(set) var token = ""
    private var accepting = true
    private var wholeSelection = false
    public private(set) var requiresVerifiedText = false
    public var isAccepting: Bool { accepting }
    public init() {}

    public mutating func reset(startOfWord: Bool = true) {
        token = ""
        accepting = startOfWord
        wholeSelection = false
        requiresVerifiedText = false
    }
    /// Retain all captured characters after a late activation, but authorize
    /// correction only if the editor confirms that exact complete token.
    public mutating func requireVerifiedText() {
        guard accepting, !token.isEmpty else { return }
        requiresVerifiedText = true
    }
    /// A metadata change is not a missed key. Preserve a known empty word
    /// boundary, but never resume a partial token or one with rejected input.
    public mutating func invalidatePartialWord() {
        reset(startOfWord: token.isEmpty && accepting)
    }
    /// Cmd+A followed by typing/deletion replaces the selected prefix completely.
    public mutating func selectAll() { reset(); wholeSelection = true }
    /// A pause doesn't edit text. Focus, navigation, paste and foreign events
    /// invalidate the token explicitly; elapsed time alone must not lose half a word.
    public mutating func noteKey(at time: TimeInterval) {
    }
    /// Repeated notifications for a window wrapper are not field changes.
    public mutating func updateFocus(changed: Bool) {
        if changed { reset() }
    }
    public mutating func append(_ text: String) {
        guard accepting else { return }
        wholeSelection = false
        let allowed = "«»“”‘’„‚…—–§±`[];'.,/~{}:\"<>?!()@#$%^&*+-=_|\\№"
        guard text.utf16.count == 1, let char = text.first,
              char.isLetter || char.isNumber || allowed.contains(char), token.count < 128 else {
            reset(startOfWord: false)
            return
        }
        token += text
    }
    public mutating func backspace() {
        if wholeSelection { reset(); return }
        guard accepting, !token.isEmpty else { reset(startOfWord: false); return }
        token.removeLast()
    }
    public mutating func finishWord() -> String? {
        let result = accepting && !token.isEmpty ? token : nil
        reset()
        return result
    }
}

/// Hardware keys and explicit Unicode agree, including in frameworks which
/// translate key codes themselves instead of honoring event Unicode.
public struct ReplacementKey {
    public let option: Bool
    public let capsLock: Bool
    public init(code: UInt16, shift: Bool, text: String?, option: Bool = false, capsLock: Bool = false) {
        self.code = code; self.shift = shift; self.text = text; self.option = option; self.capsLock = capsLock
    }
    public let code: UInt16
    public let shift: Bool
    public let text: String?
}
public enum KeyboardReplacement {
    public static func keys(original: String, corrected: String, layout: Layout, appendSpace: Bool = true, keyProvider: ((String, Layout) -> ReplacementKey?)? = nil) -> [ReplacementKey]? {
        guard (1...128).contains(original.count), original.utf16.count == original.count,
              (1...128).contains(corrected.count), corrected.utf16.count == corrected.count else { return nil }
        let codes: [Character: UInt16] = [
            "a":0,"s":1,"d":2,"f":3,"h":4,"g":5,"z":6,"x":7,"c":8,"v":9,"b":11,
            "q":12,"w":13,"e":14,"r":15,"y":16,"t":17,"1":18,"2":19,"3":20,
            "4":21,"6":22,"5":23,"=":24,"9":25,"7":26,"-":27,"8":28,"0":29,
            "]":30,"o":31,"u":32,"[":33,"i":34,"p":35,"l":37,"j":38,"'":39,
            "k":40,";":41,"\\":42,",":43,"/":44,"n":45,"m":46,".":47,"`":50
        ]
        let shifted = Dictionary(uniqueKeysWithValues: zip(Array("~!@#$%^&*()_+{}|:\"<>?"), Array("`1234567890-=[]\\;',./")))
        var typing: [ReplacementKey] = []
        for char in corrected {
            if let keyProvider {
                guard let key = keyProvider(String(char), layout) else { return nil }
                typing.append(key); continue
            }
            if char == " " { typing.append(ReplacementKey(code: 49, shift: false, text: " ")); continue }
            let position = layout == .russian ? Conversion.convert(String(char), to: .english) : String(char)
            guard position.count == 1, let key = position.first else { return nil }
            let base = shifted[key] ?? Character(String(key).lowercased())
            guard let code = codes[base] else { return nil }
            typing.append(ReplacementKey(code: code, shift: shifted[key] != nil || key.isUppercase, text: String(char)))
        }
        let deletion = Array(repeating: ReplacementKey(code: 51, shift: false, text: nil), count: original.count)
        return deletion + typing + (appendSpace ? [ReplacementKey(code: 49, shift: false, text: " ")] : [])
    }
}
