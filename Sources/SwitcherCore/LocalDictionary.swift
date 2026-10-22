import Foundation
import Hunspell

private final class PackagedSpeller {
    let handle: OpaquePointer
    let encoding: String.Encoding
    init?(directory: URL?, name: String, probe: String) {
        guard let directory,
              FileManager.default.isReadableFile(atPath: directory.appendingPathComponent(name + ".aff").path),
              FileManager.default.isReadableFile(atPath: directory.appendingPathComponent(name + ".dic").path),
              let handle = Hunspell_create(directory.appendingPathComponent(name + ".aff").path,
                                           directory.appendingPathComponent(name + ".dic").path) else { return nil }
        let name = String(cString: Hunspell_get_dic_encoding(handle)).uppercased()
        switch name {
        case "UTF-8": encoding = .utf8
        case "KOI8-R": encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.KOI8_R.rawValue)))
        default: Hunspell_destroy(handle); return nil
        }
        self.handle = handle
        guard recognizes(probe) else { return nil }
    }
    func recognizes(_ word: String) -> Bool {
        guard let bytes = word.cString(using: encoding) else { return false }
        return bytes.withUnsafeBufferPointer { Hunspell_spell(handle, $0.baseAddress) != 0 }
    }
    deinit { Hunspell_destroy(handle) }
}

/// Immutable packaged data, loaded once. No learned words, input cache or network.
/// Call on the main thread: Hunspell instances are not shared across threads.
public final class LocalDictionary {
    public static let shared = LocalDictionary()
    // A subtitle-frequency token is not proof of a word. This entry has no
    // support in either packaged Russian speller and shadows English "cat"
    // under the physical layout mapping. Keep the upstream pack unchanged.
    private static let rejectedRussianFrequencyTokens: Set<String> = ["сфе"]
    private let russian: PackagedSpeller?
    private let russianModern: PackagedSpeller?
    private let english: PackagedSpeller?
    private let englishBritish: PackagedSpeller?
    private let russianFrequency: Set<String>
    private let englishFrequency: Set<String>
    private let russianCompounds: Set<String>
    private let englishCompounds: Set<String>
    private let russianShape: LexicalShape
    private let englishShape: LexicalShape
    private let system: SystemDictionary?
    public let resourceDirectory: URL?
    public var bundledAvailable: Bool { russian != nil && russianModern != nil && english != nil && englishBritish != nil }
    public var available: Bool { bundledAvailable || system?.available == true }
    public var frequencyCounts: (russian: Int, english: Int) {
        (russianFrequency.count, englishFrequency.count)
    }
    public var status: String {
        bundledAvailable ? "RU + расширенный RU / EN US+GB · частотные списки \(russianFrequency.count)/\(englishFrequency.count)" :
            (system?.available == true ? "macOS · встроенные словари не загрузились" : "словари недоступны")
    }

    public init(includeSystem: Bool = false, directory: URL? = nil) {
        // An application must be self-contained, never silently use build-tree data.
        let appBundle = Bundle.main.bundleURL.pathExtension == "app"
        let dataDirectory = directory ?? (appBundle ? Bundle.main.resourceURL?.appendingPathComponent("Dictionaries") :
            Bundle.module.url(forResource: "Dictionaries", withExtension: nil))
        resourceDirectory = dataDirectory
        russian = PackagedSpeller(directory: dataDirectory, name: "ru_RU", probe: "привет")
        russianModern = PackagedSpeller(directory: dataDirectory, name: "ru_modern", probe: "привет")
        english = PackagedSpeller(directory: dataDirectory, name: "en_US", probe: "hello")
        englishBritish = PackagedSpeller(directory: dataDirectory, name: "en_GB", probe: "colour")
        func frequency(_ name: String) -> Set<String> {
            guard let url = dataDirectory?.appendingPathComponent(name + "_frequency.txt"),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
            return Set(text.split(separator: "\n").map(String.init))
        }
        russianFrequency = frequency("ru")
        englishFrequency = frequency("en")
        let koi8 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.KOI8_R.rawValue)))
        russianCompounds = CompoundWords.load(directory: dataDirectory, name: "ru_modern", encoding: koi8,
            layout: .russian).union(CompoundWords.commonRussian)
        englishCompounds = CompoundWords.load(directory: dataDirectory, name: "en_GB", encoding: .utf8,
            layout: .english)
        russianShape = LexicalShape(words: russianFrequency)
        englishShape = LexicalShape(words: englishFrequency)
        system = includeSystem ? SystemDictionary() : nil
    }

    public func recognizes(_ word: String, _ layout: Layout) -> Bool {
        if word.contains("-") { return recognizesCompound(word, layout) }
        guard (1...48).contains(word.count), word.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "’" }) else { return false }
        let normalized = word.precomposedStringWithCanonicalMapping.lowercased().replacingOccurrences(of: "’", with: "'")
        if layout == .russian && Self.rejectedRussianFrequencyTokens.contains(normalized) { return false }
        if recognizesCommon(normalized, layout) { return true }
        // Short forms in the large Russian source are frequently abbreviations
        // (ФКУ etc.), not evidence against "are" typed on a Cyrillic keyboard.
        // Common short words still come from the base lists and explicit rules.
        if layout == .russian && normalized.count < 5 { return false }
        let supplementary = layout == .russian ? russianModern : englishBritish
        let shape = layout == .russian ? russianShape : englishShape
        return shape.permits(normalized) && supplementary?.recognizes(normalized) == true
    }

    /// Stronger evidence for a fragment obtained by stripping a potential б/ю/ж.
    /// Supplementary rare forms must not manufacture punctuation ambiguity.
    public func recognizesCommon(_ word: String, _ layout: Layout) -> Bool {
        if word.contains("-") { return recognizesCompound(word, layout) }
        guard (1...48).contains(word.count), word.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "’" }) else { return false }
        let normalized = word.precomposedStringWithCanonicalMapping.lowercased().replacingOccurrences(of: "’", with: "'")
        if layout == .russian && Self.rejectedRussianFrequencyTokens.contains(normalized) { return false }
        let frequency = layout == .russian ? russianFrequency : englishFrequency
        if frequency.contains(normalized) || CommonNames.recognizes(normalized, layout) ||
            SupplementalWords.recognizes(normalized, layout) { return true }
        // Do not capitalize every candidate to make Hunspell accept it: this
        // licenses acronyms such as ФФПР as lowercase gibberish and suppresses
        // real English words. Product/person names have an explicit lexicon.
        if (layout == .russian ? russian : english)?.recognizes(normalized) == true { return true }
        return system?.recognizes(normalized, layout) == true
    }

    private func recognizesCompound(_ word: String, _ layout: Layout) -> Bool {
        let normalized = word.precomposedStringWithCanonicalMapping.lowercased()
        guard CompoundWords.valid(normalized, layout: layout) else { return false }
        return (layout == .russian ? russianCompounds : englishCompounds).contains(normalized)
    }
}
