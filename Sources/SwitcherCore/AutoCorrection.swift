import Foundation

public struct AutoCorrection {
    public let text: String
    public let layout: Layout
    /// User rules specify their output spelling explicitly (for example iPhone).
    public let preservesExactCase: Bool

    private init(text: String, layout: Layout, preservesExactCase: Bool = false) {
        self.text = text
        self.layout = layout
        self.preservesExactCase = preservesExactCase
    }
    public static let shortRussian: Set<String> = [
        "а", "я", "и", "в", "к", "с", "у", "о", "не", "на", "да", "но",
        "он", "мы", "вы", "ты", "то", "до", "за", "из", "по", "от", "об",
        "же", "бы", "ли", "ну", "уж", "во", "со", "ко", "ее", "её", "ни", "та", "те", "ту",
        "их", "им", "ей", "ах", "ох", "эх", "ой", "ай", "ха", "хи", "фу", "ух",
        "ёж", "ум", "ус", "яд", "юг", "ад", "ил", "ас", "ок"
    ]
    private static let shortEnglish: Set<String> = [
        "a", "i", "to", "of", "in", "is", "it", "he", "we", "be", "by", "at", "an", "as", "am",
        "on", "or", "so", "if", "do", "no", "up", "us", "me", "my", "go", "oh", "ok", "hi"
    ]
    private static let opening = Set("([{'\"«“‘„‚")
    private static let closing = Set(".,!?;:)]}'\"»”’…—–")
    public static func isWordSeparator(_ text: String) -> Bool {
        text.unicodeScalars.count == 1 && text.unicodeScalars.first?.properties.generalCategory == .spaceSeparator
    }
    private static func knownShort(_ word: String, _ layout: Layout) -> Bool {
        (layout == .russian ? shortRussian : shortEnglish).contains(word.lowercased())
    }
    /// Exact exclusions win over explicit rules, which win over the dictionary.
    /// Physical conversion is injected by the macOS app; the default is the PC
    /// fixture used by portable/manual conversion checks.
    public static func detect(_ token: String, recognizes rawRecognizes: (String, Layout) -> Bool,
                              recognizesFragment rawRecognizesFragment: ((String, Layout) -> Bool)? = nil,
                              isAddress: (String) -> Bool = AddressRecognizer.shared.recognizes,
                              settings: CorrectionSettings = CorrectionSettings(),
                              establishedLanguage: Layout? = nil,
                              exclusions compiledExclusions: CompiledExclusions? = nil,
                              convert: (String, Layout) -> String = { Conversion.convert($0, to: $1) },
                              onKnownSource: ((Layout) -> Void)? = nil) -> AutoCorrection? {
        guard (1...128).contains(token.utf16.count) else { return nil }
        let exclusions = compiledExclusions ?? CompiledExclusions(settings.excludedWords)
        guard !exclusions.contains(token) else { return nil }
        // Punctuation variants often ask Hunspell about the same spelling.
        // Cache only inside this decision: no typed-word history or shared state.
        var wordCache: [String: Bool] = [:], fragmentCache: [String: Bool] = [:]
        func recognizes(_ word: String, _ layout: Layout) -> Bool {
            let key = (layout == .russian ? "r:" : "e:") + word
            if let result = wordCache[key] { return result }
            let result = rawRecognizes(word, layout); wordCache[key] = result
            return result
        }
        let recognizesFragment: ((String, Layout) -> Bool)? = rawRecognizesFragment.map { raw in
            { word, layout in
                let key = (layout == .russian ? "r:" : "e:") + word
                if let result = fragmentCache[key] { return result }
                let result = raw(word, layout); fragmentCache[key] = result
                return result
            }
        }
        func split(_ value: String) -> (String, String, String) {
            var core = value; var prefix = ""; var suffix = ""
            while let char = core.first, opening.contains(char) { prefix.append(core.removeFirst()) }
            while let char = core.last, closing.contains(char) { suffix.insert(core.removeLast(), at: suffix.startIndex) }
            return (prefix, core, suffix)
        }
        // Adapt RuSwitcher's two-sided never-convert policy: an exclusion
        // entered in its intended spelling also protects a wrong-layout token.
        // Apply only after choosing a result; filtering competing candidates
        // earlier could turn an ambiguity into an incorrect partial correction.
        func makeResult(_ text: String, _ layout: Layout, exactCase: Bool = false) -> AutoCorrection? {
            guard !exclusions.contains(text) else { return nil }
            let core = split(text).1
            guard core == text || !exclusions.contains(core) else { return nil }
            let output = exactCase ? text : LexicalNormalization.hyphens(text)
            return AutoCorrection(text: output, layout: layout, preservesExactCase: exactCase)
        }
        let (prefix, stem, suffix) = split(token)
        guard !exclusions.contains(stem) else { return nil }
        var variants = settings.punctuation && stem != token ? [("", token, ""), (prefix, stem, suffix)] : [("", token, "")]
        if settings.punctuation, !prefix.isEmpty, !suffix.isEmpty {
            // Opening quote/bracket keys can be э/х while the final sign really
            // is punctuation. Parse the two edges independently.
            variants.append(("", String(token.dropLast(suffix.count)), suffix))
            variants.append((prefix, String(token.dropFirst(prefix.count)), ""))
        }
        if settings.punctuation, prefix.count + suffix.count <= 12 {
            for leading in 0...prefix.count {
                for trailing in 0...suffix.count {
                    let before = String(prefix.prefix(leading)), after = String(suffix.suffix(trailing))
                    let input = String(token.dropFirst(leading).dropLast(trailing))
                    if !input.isEmpty, !variants.contains(where: { $0.0 == before && $0.1 == input && $0.2 == after }) {
                        variants.append((before, input, after))
                    }
                }
            }
        }
        let matchingClosers: [Character: Character] = ["(": ")", "[": "]", "{": "}", "'": "'", "\"": "\"", "«": "»", "“": "”", "‘": "’", "„": "“", "‚": "‘"]
        for (before, input, after) in variants {
            if let rule = settings.rules.first(where: { $0.valid && $0.input == input }), settings.permits(rule.layout) {
                return makeResult(before + rule.output + after, rule.layout, exactCase: true)
            }
        }
        func compound(_ word: String) -> Bool {
            let parts = LexicalNormalization.hyphens(word).split(separator: "-", omittingEmptySubsequences: false)
            return (2...3).contains(parts.count) && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isLetter) }
        }
        func known(_ word: String, layout: Layout) -> Bool {
            guard !word.isEmpty, word.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "’" }) || compound(word) else { return false }
            return word.count <= 2 ? knownShort(word, layout) : recognizes(word.lowercased(), layout)
        }
        // A real word wins over an accidental domain in the other layout:
        // валюта -> dfk.nf, июль -> b.km, интересуюсь -> bynthtce.cm.
        if let direction = Conversion.direction(token) {
            let source: Layout = direction == .russian ? .english : .russian
            if known(token, layout: source) || known(stem, layout: source) {
                onKnownSource?(source); return nil
            }
            if ShortSourceProtection.recognizes(token, source, establishedLanguage: establishedLanguage) { return nil }
            if ShortSourceProtection.recognizes(stem, source, establishedLanguage: establishedLanguage) {
                // Do not let a stripped short-token guard hide a proved whole
                // word whose letter lives on a punctuation key: 'dj = эво.
                // Retain the existing complete-word/punctuation policy here.
                let full = convert(token, direction)
                if !full.allSatisfy(\.isLetter) || !known(full, layout: direction) { return nil }
            }
        }
        let literalAddress = isAddress(token) || (settings.punctuation && isAddress(stem))
        if literalAddress {
            // Bare ASCII "domains" can themselves be a Russian word typed on
            // ABC (dfk.nf). Explicit URL/email syntax is always preserved.
            let mapped = convert(token, .russian)
            guard !token.contains(where: { ":/@\\_=?#0123456789".contains($0) }),
                  mapped.allSatisfy(\.isLetter), mapped.count >= 3,
                  known(mapped, layout: .russian) else { return nil }
        }
        let russianCandidate = convert(token, .russian)
        let completeRussianWord = russianCandidate != token && russianCandidate.allSatisfy(\.isLetter) &&
            russianCandidate.count >= 3 && known(russianCandidate, layout: .russian)
        if settings.addresses && settings.permits(.english) && !completeRussianWord {
            for (before, input, after) in variants {
                let candidate = convert(input, .english)
                if candidate != input, isAddress(candidate) {
                    return makeResult(before + candidate + after, .english)
                }
            }
        }
        let cyrillic = stem.unicodeScalars.contains { (0x410...0x44f).contains($0.value) || $0.value == 0x401 || $0.value == 0x451 }
        let latin = stem.unicodeScalars.contains { (65...90).contains($0.value) || (97...122).contains($0.value) }
        let letterKeys = "[];'.,`{}:\"<>\\"
        let partialLayout = cyrillic && (latin || stem.contains(where: { letterKeys.contains($0) }))
        // эх / ёж consist entirely of symbol keys on ABC (including § for the
        // PC ё position). Check the same bounded wrapper variants as words,
        // so punctuation around such a word cannot hide its alphabet entirely.
        let punctuationWord = variants.contains { _, input, _ in
            guard input.allSatisfy({ !$0.isLetter && !$0.isNumber }) else { return false }
            let candidate = convert(input, .russian)
            let word = settings.punctuation ? split(candidate).1 : candidate
            return word.count == 2 && knownShort(word, .russian)
        }
        let direction = Conversion.direction(token) ?? (punctuationWord ? Layout.russian : nil)
        if direction == nil || partialLayout {
            // Recover a complete mixed-alphabet word only when exactly one
            // complete dictionary/name spelling results. Never guess fragments,
            // identifiers, addresses or a manually truncated token.
            guard (settings.punctuation || (prefix.isEmpty && suffix.isEmpty)),
                  (2...48).contains(stem.count),
                  stem.allSatisfy({ $0.isLetter || letterKeys.contains($0) || $0 == "’" || LexicalNormalization.hyphenCharacters.contains($0) }), partialLayout else { return nil }
            var candidates: [String: AutoCorrection] = [:]
            var wholeWordCandidates = Set<String>()
            var literalCandidates: [String: Int] = [:]
            for destination in [Layout.russian, .english] where settings.permits(destination) {
                let opposite: Layout = destination == .russian ? .english : .russian
                for (before, input, after) in variants {
                    let candidate = convert(input, destination)
                    let (mappedPrefix, word, mappedSuffix) = split(candidate)
                    // Mixed input may include a genuine English apostrophe;
                    // it remains eligible only when the complete contraction
                    // is recognized, under the same case/ambiguity policy.
                    guard candidate != input, (2...48).contains(word.count),
                          word.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "’" }) || compound(word),
                          Conversion.direction(word) == opposite else { continue }
                    if compound(word) {
                        // The dictionary must recognize this exact compound.
                        // Independently known pieces cannot license a new pair.
                        guard settings.punctuation, recognizes(word.lowercased(), destination) else { continue }
                    } else if word.count <= 2 {
                        guard settings.shortWords, knownShort(word, destination) else { continue }
                    } else if !recognizes(word.lowercased(), destination) { continue }
                    if (!before.isEmpty || !after.isEmpty || !mappedPrefix.isEmpty || !mappedSuffix.isEmpty),
                       word.count > 2, let recognizesFragment, !recognizesFragment(word.lowercased(), destination) { continue }
                    let capitals = word.filter(\.isLetter)
                    guard !capitals.dropFirst().contains(where: \.isUppercase) ||
                          (settings.allowAllCaps && capitals.allSatisfy(\.isUppercase)) ||
                          (!capitals.allSatisfy(\.isUppercase) && CommonNames.recognizes(word, destination)) else { continue }
                    let result = before + candidate + after
                    candidates[result] = AutoCorrection(text: result, layout: destination)
                    if before.isEmpty && after.isEmpty && mappedPrefix.isEmpty && mappedSuffix.isEmpty {
                        wholeWordCandidates.insert(result)
                    }
                    if !before.isEmpty || !after.isEmpty {
                        literalCandidates[result] = max(literalCandidates[result] ?? 0, before.count + after.count)
                    }
                }
            }
            // Use the same literal-punctuation policy as an unmixed token.
            // A complete competing word or a second destination stays ambiguous.
            if candidates.count > 1, wholeWordCandidates.isEmpty,
               let first = candidates.values.first,
               candidates.values.allSatisfy({ $0.layout == first.layout }),
               let longest = literalCandidates.values.max() {
                let preferred = literalCandidates.filter { $0.value == longest }
                if preferred.count == 1, let text = preferred.keys.first, let candidate = candidates[text] {
                    return makeResult(candidate.text, candidate.layout)
                }
            }
            guard candidates.count == 1, let candidate = candidates.values.first else { return nil }
            return makeResult(candidate.text, candidate.layout)
        }
        guard let target = direction else { return nil }
        guard settings.permits(target) else { return nil }
        let encodedPrefixIndex = prefix.enumerated().first { _, opener in
            convert(String(opener), target).allSatisfy(\.isLetter) &&
            (matchingClosers[opener].map { !suffix.contains($0) } ?? false)
        }?.offset
        let source: Layout = target == .russian ? .english : .russian
        guard token.count <= 48, !token.contains(where: { $0.isNumber || $0.isWhitespace }) else { return nil }
        // Validate the converted word, not punctuation encoded as source letters:
        // EN ':' / '"' are RU 'Ж' / 'Э'; Mac RU '"' is EN '@', and 'ё' is '\\'.
        // A blanket symbol/capital ban discarded valid words before parsing them.
        // A correctly spelled dotted abbreviation/word pair is not a mistake.
        let parts = stem.split(whereSeparator: { ".,…!?;:-‐‑—–".contains($0) }).map(String.init)
        if parts.count > 1 && parts.allSatisfy({ known($0, layout: source) }) { return nil }
        var answers = Set<String>()
        var wholeWordAnswers = Set<String>()
        var answersWithConvertedPrefix = Set<String>()
        var literalAnswers: [String: Int] = [:]
        var wrappedAnswer: String?
        func record(_ answer: String, before: String) {
            answers.insert(answer)
            if before.count <= (encodedPrefixIndex ?? 0) { answersWithConvertedPrefix.insert(answer) }
        }
        func accept(_ word: String, partial: Bool = false) -> Bool {
            guard word.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "’" }), !word.isEmpty else { return false }
            let capitals = word.filter(\.isLetter)
            if capitals.dropFirst().contains(where: \.isUppercase) &&
                !(settings.allowAllCaps && capitals.count > 1 && capitals.allSatisfy(\.isUppercase)) &&
                !(!capitals.allSatisfy(\.isUppercase) && CommonNames.recognizes(word, target)) { return false }
            if word.count <= 2 {
                guard settings.shortWords, knownShort(word, target) else { return false }
                if word.count == 1 {
                    // Preserve initials and English a/I; Russian lowercase
                    // function words typed on a Latin key remain eligible.
                    if source == .english {
                        guard capitals == capitals.lowercased() else { return false }
                    } else {
                        guard ["a", "i"].contains(word.lowercased()) else { return false }
                    }
                }
                return true // Do not rely on spelling services for one letter.
            }
            if partial, let recognizesFragment { return recognizesFragment(word.lowercased(), target) }
            return recognizes(word.lowercased(), target)
        }
        for (before, input, after) in variants {
            let candidate = convert(input, target)
            if accept(candidate, partial: !before.isEmpty || !after.isEmpty) {
                let answer = before + candidate + after; record(answer, before: before)
                if before.isEmpty && after.isEmpty { wholeWordAnswers.insert(answer) }
                else {
                    // Iteration order must not let a later shorter suffix eat
                    // punctuation: rjytxyj... is конечно..., not конечною..
                    literalAnswers[answer] = max(literalAnswers[answer] ?? 0, before.count + after.count)
                    let closingPair = String(prefix.reversed().compactMap { matchingClosers[$0] })
                    if before == prefix, after == suffix, !closingPair.isEmpty,
                       closingPair.count == prefix.count, suffix.hasPrefix(closingPair) { wrappedAnswer = answer }
                }
                continue
            }
            if settings.punctuation {
                let (mappedPrefix, mappedStem, mappedSuffix) = split(candidate)
                if accept(mappedStem, partial: true) { record(before + mappedPrefix + mappedStem + mappedSuffix + after, before: before) }
                // Compact phrases/abbreviations without spaces. Both pieces
                // must be known in the target; letters such as б/ю are kept
                // inside whole words if the whole converted word is known.
                let components = candidate.split(whereSeparator: { ".,…!?;:-‐‑—–".contains($0) }).map(String.init)
                if components.count > 1 && components.allSatisfy({ accept($0, partial: true) }) { record(before + candidate + after, before: before) }
            }
        }
        if answers.isEmpty && settings.punctuation {
            // Literal punctuation may separate two mistyped words without a
            // space. Do not split comma/period inside a recognized whole word.
            let components = stem.split(whereSeparator: { ".,…!?;:-‐‑—–".contains($0) }).map(String.init)
            if components.count > 1 {
                var result = prefix; var current = ""; var didChange = false; var valid = true
                func flush() {
                    guard !current.isEmpty else { return }
                    if known(current, layout: source) { valid = false }
                    else if let correction = detect(current, recognizes: recognizes, recognizesFragment: recognizesFragment, isAddress: isAddress, settings: settings,
                                                    establishedLanguage: establishedLanguage, exclusions: exclusions, convert: convert), correction.layout == target {
                        result += correction.text; didChange = true
                    } else { valid = false }
                    current = ""
                }
                for char in stem {
                    if ".,…!?;:-‐‑—–".contains(char) { flush(); result.append(char) }
                    else { current.append(char) }
                }
                flush()
                if valid && didChange { answers.insert(result + suffix) }
            }
        }
        if encodedPrefixIndex != nil, !answersWithConvertedPrefix.isEmpty {
            // 'nj = это, not an unmatched quote followed by то. Keep genuine
            // whole-word vs trailing-letter ambiguity (думаю / дума.) intact.
            answers.formIntersection(answersWithConvertedPrefix)
        }
        // If both versions only disagree on final punctuation, retain the
        // punctuation the user actually typed. A competing *whole word* (ю/б)
        // remains ambiguous and is never silently discarded.
        if answers.count > 1, wholeWordAnswers.isEmpty {
            if let wrappedAnswer, answers.contains(wrappedAnswer) { answers = [wrappedAnswer] }
            else {
                // Filter first: an encoded initial э/х must not let a discarded
                // literal quote/bracket outrank the remaining full-word answer.
                let eligible = literalAnswers.filter { answers.contains($0.key) }
                if let longest = eligible.values.max() {
                    let preferred = eligible.filter { $0.value == longest }
                    if preferred.count == 1, let answer = preferred.keys.first { answers = [answer] }
                }
            }
        }
        guard answers.count == 1, let answer = answers.first, answer != token else { return nil }
        return makeResult(answer, target)
    }
}
