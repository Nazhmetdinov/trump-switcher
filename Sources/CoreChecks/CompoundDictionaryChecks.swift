import Foundation
import SwitcherCore

func compoundDictionaryChecks(dictionary: LocalDictionary) -> Int {
    var checks = 0
    func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
        guard condition() else { fputs("Compound dictionary regression: \(name)\n", stderr); exit(1) }
        checks += 1
    }
    for word in ["как-то", "чуть-чуть", "из-за", "по-русски", "по-прежнему", "бледно-розовый"] {
        expect(dictionary.recognizes(word, .russian), "exact Russian compound: \(word)")
        expect(dictionary.recognizesCommon(word, .russian), "same whole-word evidence: \(word)")
    }
    expect(dictionary.recognizes("well-known", .english), "bundled English whole compound")
    for word in ["какое-тго", "кто-ть", "достоин-ство", "мало-по-малу", "привет-мир",
                 "-как", "как-", "как--то", "как-то-еще-раз", "как-то123", "hello-мир"] {
        expect(!dictionary.recognizes(word, .russian), "forbidden or unproven compound: \(word)")
    }
    for word in ["hello-keyboard", "hello--world", "hello_world", "hello-мир", "api-v2"] {
        expect(!dictionary.recognizes(word, .english), "do not join arbitrary dictionary fragments: \(word)")
    }
    // Exercise the loader through its production caller, including precedence
    // across duplicate entries. Temporary files contain only these fixture words.
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("trump-compound-checks-" + UUID().uuidString)
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let affix = "SET UTF-8\nFORBIDDENWORD ?\nNEEDAFFIX !\nONLYINCOMPOUND _\n"
        let words = "7\ncolour\ngood-word\nbad-word/?\nroot-word/!\ninside-word/_\nrepeat-word/?\nrepeat-word\n"
        try affix.write(to: directory.appendingPathComponent("en_GB.aff"), atomically: true, encoding: .utf8)
        try words.write(to: directory.appendingPathComponent("en_GB.dic"), atomically: true, encoding: .utf8)
        let fixture = LocalDictionary(directory: directory)
        expect(fixture.recognizes("good-word", .english), "ordinary exact entry accepted")
        for word in ["bad-word", "root-word", "inside-word", "repeat-word"] {
            expect(!fixture.recognizes(word, .english), "honor dictionary restriction: \(word)")
        }
        try (affix + "FLAG num\n").write(to: directory.appendingPathComponent("en_GB.aff"), atomically: true, encoding: .utf8)
        expect(!LocalDictionary(directory: directory).recognizes("good-word", .english), "unknown flag format does not guess")
    } catch { fputs("Compound dictionary fixture failed: \(error)\n", stderr); exit(1) }
    print("Passed \(checks) compound dictionary regressions")
    return checks
}
