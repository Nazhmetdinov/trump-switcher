import Foundation
import SwitcherCore

// Public, packaged vocabulary only. Never reads user documents or typing logs.
func runReliabilityAudit() throws {
    let dictionary = LocalDictionary()
    let directory = dictionary.resourceDirectory!
    let en = KeyboardLayoutTable(id: "com.apple.keylayout.ABC")!
    var rows: [[String: Any]] = []
    for id in InputSources.russianIDs {
        let ru = KeyboardLayoutTable(id: id)!
        let convert: (String, Layout) -> String = { text, layout in
            layout == .russian ? en.convert(text, to: ru) : ru.convert(text, to: en)
        }
        for (language, target) in [("ru", Layout.russian), ("en", .english)] {
            let sourceWords = try String(contentsOf: directory.appendingPathComponent(language + "_frequency.txt"), encoding: .utf8)
                .split(separator: "\n").map(String.init)
            // The frequency packs are observational corpora, not proof that
            // every token is a word. Audit only entries the current recognizer
            // accepts; report excluded source noise rather than counting it as
            // a valid spelling changed by the correction engine.
            let words = sourceWords.filter { dictionary.recognizes($0, target) }
            let rejectedSourceEntries = sourceWords.count - words.count
            var exact = 0, preserved = 0, collision = 0, missed = 0, incorrect = 0, changedValid = 0
            var samples: [String: [String]] = [:]
            func sample(_ key: String, _ value: String) { if samples[key, default: []].count < 30 { samples[key, default: []].append(value) } }
            let started = ProcessInfo.processInfo.systemUptime
            for word in words {
                let wrong = target == .russian ? ru.convert(word, to: en) : en.convert(word, to: ru)
                let output = AutoCorrection.detect(wrong, recognizes: dictionary.recognizes, recognizesFragment: dictionary.recognizesCommon, recognizesBackoff: dictionary.recognizesBackoff, convert: convert)?.text
                if output == word { exact += 1 }
                else if wrong == word { preserved += 1 }
                else if output == nil && dictionary.recognizes(wrong, target == .russian ? .english : .russian) { collision += 1; sample("collisions", word + " / " + wrong) }
                else if output == nil { missed += 1; sample("missed", word + " / " + wrong) }
                else { incorrect += 1; sample("incorrect", word + " / " + wrong + " → " + output!) }
                if let output = AutoCorrection.detect(word, recognizes: dictionary.recognizes, recognizesFragment: dictionary.recognizesCommon, recognizesBackoff: dictionary.recognizesBackoff, convert: convert)?.text {
                    changedValid += 1; sample("changedValid", word + " → " + output)
                }
            }
            let row: [String: Any] = ["layout": id, "language": language, "words": words.count,
                "rejectedSourceEntries": rejectedSourceEntries,
                "exact": exact, "samePhysicalSpelling": preserved, "sourceWordCollision": collision,
                "missedOrAmbiguous": missed, "incorrect": incorrect, "changedValid": changedValid,
                "seconds": ProcessInfo.processInfo.systemUptime - started, "samples": samples]
            rows.append(row)
            print("\(id) \(language): exact=\(exact), collisions=\(collision), skips=\(missed), wrong=\(incorrect), changed valid=\(changedValid)")
        }
    }
    if let flag = CommandLine.arguments.firstIndex(of: "--output"), flag + 1 < CommandLine.arguments.count {
        let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
    }
}

func runDictionaryExtensionAudit() throws {
    let dictionary = LocalDictionary()
    let dir = dictionary.resourceDirectory!
    var rows: [[String: Any]] = []
    for (name, layout, encoding) in [("ru_modern", Layout.russian, String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.KOI8_R.rawValue)))),
                                      ("en_GB", .english, .utf8)] {
        let source = try String(contentsOf: dir.appendingPathComponent(name + ".dic"), encoding: encoding)
        let words = Set(source.split(separator: "\n").dropFirst().compactMap { line -> String? in
            let word = line.split(separator: "/")[0].lowercased()
            return (3...48).contains(word.count) && word.allSatisfy(\.isLetter) ? word : nil
        })
        var added: [String] = []
        for word in words where !dictionary.recognizesCommon(word, layout) && dictionary.recognizes(word, layout) { added.append(word) }
        added.sort()
        rows.append(["dictionary": name, "uniqueBaseWordsReviewed": words.count, "additionalAcceptedBaseWords": added.count, "sample": Array(added.prefix(40))])
        print("\(name): \(added.count) additional base spellings after filters / \(words.count) reviewed (inflected forms not counted)")
    }
    if let flag = CommandLine.arguments.firstIndex(of: "--output"), flag + 1 < CommandLine.arguments.count {
        try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
    }
}
