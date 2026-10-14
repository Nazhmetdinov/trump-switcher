import AppKit

public final class SystemDictionary {
    private let checker = NSSpellChecker.shared
    private let document = NSSpellChecker.uniqueSpellDocumentTag()
    private let russian: String?
    private let english: String?
    public var available: Bool { russian != nil && english != nil }

    public init() {
        let languages = NSSpellChecker.shared.availableLanguages
        russian = languages.first { $0 == "ru" || $0.hasPrefix("ru_") || $0.hasPrefix("ru-") }
        english = languages.first { $0 == "en_US" } ?? languages.first { $0 == "en" || $0.hasPrefix("en_") || $0.hasPrefix("en-") }
        // Warm the system spelling service before keyboard monitoring begins.
        if available { _ = recognizes("привет", .russian); _ = recognizes("hello", .english) }
    }

    public func recognizes(_ word: String, _ layout: Layout) -> Bool {
        guard available, let language = layout == .russian ? russian : english else { return false }
        return checker.checkSpelling(of: word, startingAt: 0, language: language,
            wrap: false, inSpellDocumentWithTag: document, wordCount: nil).location == NSNotFound
    }

    deinit { checker.closeSpellDocument(withTag: document) }
}
