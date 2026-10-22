import Foundation

public struct CorrectionRule: Codable, Equatable, Identifiable {
    public var id: UUID
    public var input: String
    public var output: String
    public var russian: Bool
    public init(input: String, output: String, russian: Bool, id: UUID = UUID()) {
        self.id = id; self.input = input; self.output = output; self.russian = russian
    }
    public var layout: Layout { russian ? .russian : .english }
    public var valid: Bool {
        !input.isEmpty && input.utf16.count <= 128 && input.utf16.count == input.count &&
        !input.contains(where: { $0.isWhitespace || $0.isNewline }) &&
        !input.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) &&
        !output.isEmpty && output.utf16.count <= 128 && output.utf16.count == output.count &&
        !output.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) && input != output
    }
}

public struct CorrectionSettings: Codable, Equatable {
    public var automatic = true
    public var toRussian = true
    public var toEnglish = true
    public var shortWords = true
    public var punctuation = true
    public var addresses = true
    public var onEnter = true
    public var onTab = true
    public var allowAllCaps = false
    public var preferredRussian = "com.apple.keylayout.Russian"
    public var preferredEnglish = "com.apple.keylayout.ABC"
    public var excludedWords: [String] = []
    public var excludedApps: [String] = []
    public var rules: [CorrectionRule] = []
    public init() {}
    public func excludes(_ token: String) -> Bool {
        guard !excludedWords.isEmpty else { return false }
        let normalized = LexicalNormalization.exclusionKey(token)
        return excludedWords.contains { LexicalNormalization.exclusionKey($0) == normalized }
    }
    public func excludesApp(_ id: String) -> Bool {
        excludedApps.contains { $0.caseInsensitiveCompare(id) == .orderedSame }
    }
    public func permits(_ layout: Layout) -> Bool { layout == .russian ? toRussian : toEnglish }
    public static func decode(_ data: Data) -> CorrectionSettings? {
        guard data.count <= 1_048_576, let settings = try? JSONDecoder().decode(Self.self, from: data),
              InputSources.russianIDs.contains(settings.preferredRussian), InputSources.englishIDs.contains(settings.preferredEnglish),
              settings.rules.count <= 1000, Set(settings.rules.map(\.input)).count == settings.rules.count,
              Set(settings.rules.map(\.id)).count == settings.rules.count, settings.excludedWords.count <= 5000, settings.excludedApps.count <= 1000,
              settings.rules.allSatisfy(\.valid),
              settings.excludedWords.allSatisfy({ !$0.isEmpty && $0.utf16.count <= 128 && !$0.contains(where: \.isWhitespace) && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }),
              settings.excludedApps.allSatisfy({ !$0.isEmpty && $0.count <= 256 && !$0.contains(where: \.isWhitespace) && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) else { return nil }
        return settings
    }
}
