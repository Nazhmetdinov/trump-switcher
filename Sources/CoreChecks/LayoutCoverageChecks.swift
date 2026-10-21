import Foundation
import SwitcherCore

/// Exercises Apple's installed Unicode tables without selecting a source,
/// posting a key, or reading user input. A Unicode glyph is not always enough
/// to reconstruct its physical key: count those ambiguities separately.
func layoutCoverageChecks() -> Int {
    var checks = 0
    func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
        guard condition() else { fputs("Layout coverage: \(name)\n", stderr); exit(1) }
        checks += 1
    }

    let ansiCodes = Array(UInt16(0)...UInt16(9)) + Array(UInt16(11)...UInt16(50))
    let extraCodes: [UInt16] = [10, 93, 94, 95, 102]
    let allCodes = ansiCodes + extraCodes
    let modifiers: [(shift: Bool, capsLock: Bool, option: Bool)] = [
        (false, false, false), (true, false, false),
        (false, true, false), (true, true, false),
        (false, false, true), (true, false, true),
        (false, true, true), (true, true, true)
    ]
    let english = InputSources.englishIDs.compactMap(KeyboardLayoutTable.init(id:))
    let russian = InputSources.russianIDs.compactMap(KeyboardLayoutTable.init(id:))
    expect(english.count == InputSources.englishIDs.count, "all supported English tables load")
    expect(russian.count == InputSources.russianIDs.count, "all supported Russian tables load")

    for table in english + russian {
        var observed = 0
        for code in allCodes {
            for modifier in modifiers {
                let character = table.character(code: code, shift: modifier.shift,
                                                capsLock: modifier.capsLock, option: modifier.option)
                guard let character else { continue }
                observed += 1
                guard let replacement = table.replacement(character) else {
                    fputs("Layout coverage: no replacement for \(table.id) \(character)\n", stderr)
                    exit(1)
                }
                expect(table.character(code: replacement.code, shift: replacement.shift,
                                       capsLock: replacement.capsLock, option: replacement.option) == character,
                       "replacement reproduces Apple glyph: \(table.id)")
            }
        }
        expect(observed > 300, "printable physical positions covered: \(table.id)")
    }

    var ambiguousGlyphs = 0
    var unambiguousMappings = 0
    var roundTrips = 0
    for en in english {
        for ru in russian {
            for (source, target) in [(en, ru), (ru, en)] {
                // On ANSI hardware, the source glyph can sometimes come from
                // more than one key. Only assert a Unicode-only conversion when
                // every such physical key has the same target glyph. Option and
                // Caps Lock are checked above as output, not assumed reversible.
                var destinations: [String: Set<String>] = [:]
                var reverse: [String: Set<String>] = [:]
                for code in ansiCodes {
                    for shift in [false, true] {
                        guard let original = source.character(code: code, shift: shift, capsLock: false),
                              let mapped = target.character(code: code, shift: shift, capsLock: false) else { continue }
                        destinations[original, default: []].insert(mapped)
                        reverse[mapped, default: []].insert(original)
                    }
                }
                for (original, outputs) in destinations {
                    guard outputs.count == 1, let mapped = outputs.first else {
                        ambiguousGlyphs += 1
                        continue
                    }
                    expect(source.convert(original, to: target) == mapped,
                           "unique ANSI conversion: \(source.id) → \(target.id), \(original)")
                    unambiguousMappings += 1
                    if reverse[mapped] == [original] {
                        expect(target.convert(mapped, to: source) == original,
                               "uniquely reversible ANSI conversion: \(source.id) ↔ \(target.id), \(original)")
                        roundTrips += 1
                    }
                }
            }
        }
    }

    let win = russian.first { $0.id == "com.apple.keylayout.RussianWin" }!
    let abc = english.first { $0.id == "com.apple.keylayout.ABC" }!
    expect(win.character(code: 50, shift: false, capsLock: false) == "ё", "ANSI RussianWin grave key is ё")
    expect(win.key(for: "ё")?.code == 50, "ANSI ё outranks duplicate ISO/JIS ё positions")
    expect(win.convert("ё", to: abc) == "`", "ANSI ё maps to ABC grave, not ISO section sign")
    print("Layout coverage: \(checks) checks; \(unambiguousMappings) unique ANSI mappings, " +
          "\(roundTrips) round trips, \(ambiguousGlyphs) duplicate-glyph physical ambiguities excluded")
    return checks
}
