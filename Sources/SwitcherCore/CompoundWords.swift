import Foundation

/// Exact, local compound-word evidence. Hunspell's BREAK rules may accept any
/// pair of known words; that is too broad to authorize a mixed-layout edit.
enum CompoundWords {
    static let commonRussian: Set<String> = [
        "из-за", "из-под", "чуть-чуть", "еле-еле", "давным-давно", "точь-в-точь",
        "по-русски", "по-английски", "по-прежнему", "по-моему", "по-твоему",
        "по-своему", "по-новому", "по-другому", "по-настоящему", "всё-таки", "все-таки",
        "кто-то", "что-то", "где-то", "куда-то", "откуда-то", "когда-то", "как-то",
        "почему-то", "зачем-то", "какой-то", "какая-то", "какое-то", "какие-то",
        "кого-то", "кому-то", "кем-то", "чего-то", "чему-то", "чем-то",
        "кто-нибудь", "что-нибудь", "где-нибудь", "куда-нибудь", "когда-нибудь",
        "как-нибудь", "какой-нибудь", "какая-нибудь", "какое-нибудь", "какие-нибудь",
        "кто-либо", "что-либо", "где-либо", "куда-либо", "когда-либо", "как-либо"
    ]

    static func valid(_ word: String, layout: Layout) -> Bool {
        guard (3...48).contains(word.count) else { return false }
        let parts = word.split(separator: "-", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty }) else { return false }
        return parts.allSatisfy { part in
            part.unicodeScalars.allSatisfy { scalar in
                layout == .russian ? (0x430...0x44f).contains(scalar.value) || scalar.value == 0x451 :
                    (0x61...0x7a).contains(scalar.value)
            }
        }
    }

    static func load(directory: URL?, name: String, encoding: String.Encoding, layout: Layout) -> Set<String> {
        guard let url = directory?.appendingPathComponent(name + ".dic"),
              let affixURL = directory?.appendingPathComponent(name + ".aff"),
              let data = try? String(contentsOf: url, encoding: encoding),
              let affixes = try? String(contentsOf: affixURL, encoding: encoding) else { return [] }
        var forbidden = Set<Character>(), dependent = Set<Character>()
        for line in affixes.split(separator: "\n") {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard let directive = fields.first else { continue }
            if directive == "FLAG", fields.count != 2 || fields[1] != "UTF-8" { return [] }
            if ["FORBIDDENWORD", "NEEDAFFIX", "PSEUDOROOT", "ONLYINCOMPOUND"].contains(String(directive)) {
                guard fields.count == 2, fields[1].count == 1, let flag = fields[1].first else { return [] }
                if directive == "FORBIDDENWORD" { forbidden.insert(flag) }
                else { dependent.insert(flag) }
            }
        }
        var words = Set<String>(), blocked = Set<String>()
        for line in data.split(separator: "\n").dropFirst() {
            // Flags are semantic: a listed typo marked FORBIDDENWORD must never
            // become a correction, nor may a stem requiring an affix stand alone.
            let lexeme = line.prefix { !$0.isWhitespace }
            let fields = lexeme.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            guard let entry = fields.first else { continue }
            guard entry.contains("-") else { continue }
            let word = String(entry).precomposedStringWithCanonicalMapping.lowercased()
            guard valid(word, layout: layout) else { continue }
            let flags = Set(fields.count == 2 ? String(fields[1]) : "")
            if !flags.isDisjoint(with: forbidden) { blocked.insert(word) }
            else if flags.isDisjoint(with: dependent) { words.insert(word) }
        }
        return words.subtracting(blocked)
    }
}
