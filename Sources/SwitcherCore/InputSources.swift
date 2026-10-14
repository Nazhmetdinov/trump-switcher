import Carbon

public enum InputSources {
    public static let russianIDs = ["com.apple.keylayout.Russian", "com.apple.keylayout.RussianWin", "com.apple.keylayout.Russian-Phonetic"]
    public static let englishIDs = ["com.apple.keylayout.ABC", "com.apple.keylayout.US"]
    public static var preferredRussian = russianIDs[0]
    public static var preferredEnglish = englishIDs[0]
    private static var lastRussian: String?
    private static var lastEnglish: String?
    private static var enabledSources: [String: TISInputSource] = [:]
    private static var warmed = false
    /// Refresh on startup/source changes, never for every replacement character.
    public static func refreshEnabledSources() {
        var next: [String: TISInputSource] = [:]
        for id in russianIDs + englishIDs { next[id] = enabled(matching: id).first }
        enabledSources = next; warmed = true
    }
    private static func ensureSources() { if !warmed { refreshEnabledSources() } }
    public static func layout(forID id: String?) -> Layout? {
        guard let id else { return nil }
        if russianIDs.contains(id) { lastRussian = id; return .russian }
        if englishIDs.contains(id) { lastEnglish = id; return .english }
        return nil
    }
    public static func sources(matching id: String, includeDisabled: Bool = false) -> [TISInputSource] {
        guard let key = kTISPropertyInputSourceID else { return [] }
        let query = [key as String: id] as CFDictionary
        guard let result = TISCreateInputSourceList(query, includeDisabled) else { return [] }
        return result.takeRetainedValue() as? [TISInputSource] ?? []
    }
    public static func enabled(matching id: String) -> [TISInputSource] { sources(matching: id) }
    private static func ids(_ layout: Layout) -> [String] { layout == .russian ? russianIDs : englishIDs }
    public static func available(_ layout: Layout) -> Bool { ids(layout).contains { !enabled(matching: $0).isEmpty } }
    public static func currentID() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }
    public static func currentLayout() -> Layout? { layout(forID: currentID()) }
    public static func sourceID(for layout: Layout) -> String? {
        if let current = currentID(), ids(layout).contains(current) { return current }
        ensureSources()
        let last = layout == .russian ? lastRussian : lastEnglish
        let preferred = layout == .russian ? preferredRussian : preferredEnglish
        for id in [last, preferred].compactMap({ $0 }) + ids(layout) {
            if ids(layout).contains(id), enabledSources[id] != nil { return id }
        }
        return nil
    }
    public static func setPreferences(russian: String, english: String) {
        if preferredRussian != russian { lastRussian = nil }
        if preferredEnglish != english { lastEnglish = nil }
        preferredRussian = russian; preferredEnglish = english
    }
    public static func select(_ layout: Layout) -> Bool {
        guard let id = sourceID(for: layout) else { return false }
        return selectID(id)
    }
    public static func selectID(_ id: String) -> Bool {
        ensureSources()
        guard let source = enabledSources[id] else { return false }
        return TISSelectInputSource(source) == noErr
    }
}
