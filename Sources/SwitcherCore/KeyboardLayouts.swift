import Carbon
import Foundation

public struct PhysicalKey: Hashable {
    public let code: UInt16
    public let shift: Bool
    public let option: Bool
    public let capsLock: Bool
    public init(code: UInt16, shift: Bool, option: Bool = false, capsLock: Bool = false) {
        self.code = code; self.shift = shift; self.option = option; self.capsLock = capsLock
    }
}

/// Snapshot of an Apple Unicode keyboard layout; immutable and warmed before
/// monitoring. No preference changes or keyboard events are needed to read it.
public struct KeyboardLayoutTable {
    public let id: String
    public let characters: [PhysicalKey: String]
    private let inverse: [String: PhysicalKey]
    private let typingInverse: [String: PhysicalKey]
    public init?(id: String) {
        guard let source = InputSources.sources(matching: id, includeDisabled: true).first,
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        let table = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var characters: [PhysicalKey: String] = [:]
        var inverse: [String: PhysicalKey] = [:]
        var typingInverse: [String: PhysicalKey] = [:]
        // Prefer ordinary ANSI positions when several physical keys produce
        // the same glyph. For example RussianWin maps ё from key 10 (ISO §)
        // and key 50 (ANSI grave); choosing key 10 would convert ё to § on
        // ABC instead of the expected ` on a standard ANSI keyboard. Still
        // retain ISO/JIS positions for keyboards that actually use them.
        // Navigation/function keys and dead-key composition are omitted.
        for code: UInt16 in Array(0...9) + Array(11...50) + [10, 93, 94, 95, 102] {
            for modifiers: UInt32 in [0, 2, 4, 6, 8, 10, 12, 14] {
                let shifted = modifiers & 2 != 0
                let option = modifiers & 8 != 0
                let capsLock = modifiers & 4 != 0
                var state: UInt32 = 0
                var length = 0
                var units = [UniChar](repeating: 0, count: 8)
                let result = UCKeyTranslate(table, code, UInt16(kUCKeyActionDown), modifiers,
                    UInt32(LMGetKbdType()), OptionBits(1 << kUCKeyTranslateNoDeadKeysBit), &state, units.count, &length, &units)
                guard result == noErr, length == 1, let scalar = UnicodeScalar(Int(units[0])),
                      !CharacterSet.controlCharacters.contains(scalar),
                      (!CharacterSet.whitespacesAndNewlines.contains(scalar) || code == 49) else { continue }
                let value = String(scalar)
                let key = PhysicalKey(code: code, shift: shifted, option: option, capsLock: capsLock)
                characters[key] = value
                if !capsLock {
                    if !option && inverse[value] == nil { inverse[value] = key }
                }
                func cost(_ key: PhysicalKey) -> Int { (key.option ? 4 : 0) + (key.capsLock ? 2 : 0) + (key.shift ? 1 : 0) }
                if typingInverse[value].map({ cost(key) < cost($0) }) ?? true { typingInverse[value] = key }
            }
        }
        guard characters.count > 40 else { return nil }
        self.id = id; self.characters = characters; self.inverse = inverse; self.typingInverse = typingInverse
    }
    public func key(for character: String) -> PhysicalKey? { inverse[character] }
    public func character(code: UInt16, shift: Bool, capsLock: Bool, option: Bool = false) -> String? {
        // macOS does NOT cancel Caps Lock with Shift. Option/Caps combinations
        // also differ between Russian, Russian-PC and ABC: use Apple's data.
        characters[PhysicalKey(code: code, shift: shift, option: option, capsLock: capsLock)]
    }
    public func convert(_ text: String, to target: KeyboardLayoutTable) -> String {
        String(text.map { char in
            guard let key = inverse[String(char)], let result = target.characters[key], result.count == 1 else { return char }
            return result.first!
        })
    }
    public func replacement(_ character: String) -> ReplacementKey? {
        if character == " " { return ReplacementKey(code: 49, shift: false, text: " ") }
        guard let key = typingInverse[character] else { return nil }
        return ReplacementKey(code: key.code, shift: key.shift, text: character, option: key.option, capsLock: key.capsLock)
    }
}

public final class KeyboardLayouts {
    private var tables: [String: KeyboardLayoutTable] = [:]
    public init() {
        for id in InputSources.russianIDs + InputSources.englishIDs { tables[id] = KeyboardLayoutTable(id: id) }
    }
    public func table(_ id: String) -> KeyboardLayoutTable? { tables[id] }
    public func table(for layout: Layout) -> KeyboardLayoutTable? {
        InputSources.sourceID(for: layout).flatMap { tables[$0] }
    }
    public func convert(_ text: String, to target: Layout) -> String {
        let source: Layout = target == .russian ? .english : .russian
        guard let from = table(for: source), let to = table(for: target) else { return text }
        return from.convert(text, to: to)
    }
    public func replacement(_ text: String, layout: Layout) -> ReplacementKey? { table(for: layout)?.replacement(text) }
}
