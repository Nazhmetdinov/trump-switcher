import Foundation
import SwitcherCore

func inputPerformanceChecks() -> Int {
    var count = 0
    func expect(_ value: Bool, _ reason: String) {
        precondition(value, "Input performance: " + reason); count += 1
    }
    // Compare circular storage against an independent FIFO while continuously
    // wrapping, filling, cancelling and reusing it (including capacity one).
    for capacity in [1, 2, 3, 32, 256, 1024] {
        var queue = InputDeliveryQueue<Int>(capacity: capacity), oracle: [Int] = []
        var random: UInt64 = UInt64(capacity)
        for value in 0..<5000 {
            random = random &* 6364136223846793005 &+ 1
            switch (random >> 32) % 5 {
            case 0:
                expect(queue.cancel() == oracle, "cancel retains arrival order across wrap")
                oracle.removeAll()
            case 1, 2:
                if let lease = queue.beginDelivery() {
                    expect(lease.event == oracle.removeFirst(), "FIFO head after wrap")
                    expect(queue.commit(lease) == lease.event && queue.commit(lease) == nil, "one owner only")
                } else { expect(oracle.isEmpty, "empty queue has no lease") }
            default:
                let accepted = queue.enqueue(value)
                expect(accepted == (oracle.count < capacity), "bounded capacity")
                if accepted { oracle.append(value) }
            }
            expect(queue.count == oracle.count, "count after mixed operations")
            expect(queue.contains { $0 % 7 == 0 } == oracle.contains { $0 % 7 == 0 }, "membership ignores empty slots")
        }
        var copied = queue
        expect(copied.cancel() == oracle && queue.cancel() == oracle, "queue copies retain value semantics")
    }
    // Watchdog keeps one timer for a burst, cannot expire the newest fence
    // early, and ACK/disarm cannot leave a spurious timeout behind.
    var timer = CoalescedDeadline(), scheduled = 0
    for event in 0..<10000 {
        if timer.arm(until: Double(event) / 100000 + 0.75) != nil { scheduled += 1 }
    }
    expect(scheduled == 1, "one watchdog for ten thousand armed events")
    expect(timer.wake(at: 0.75) == .reschedule(0.84999), "old wake follows newest deadline")
    timer.disarm()
    expect(timer.wake(at: 1) == .idle, "ACK removes expiry")
    expect(timer.arm(until: 2) == 2, "new cohort can arm after idle wake")
    timer.disarm()
    expect(timer.arm(until: 3) == nil, "reuse already scheduled wake after ACK")
    expect(timer.wake(at: 2) == .reschedule(3), "old cohort wake cannot cancel new one")
    expect(timer.wake(at: 3) == .expired && timer.wake(at: 4) == .idle, "expiry happens exactly once")

    var settings = CorrectionSettings()
    settings.rules = [CorrectionRule(input: "bad", output: "", russian: true),
        CorrectionRule(input: "abc", output: "первый", russian: true),
        CorrectionRule(input: "abc", output: "second", russian: false),
        CorrectionRule(input: "bad", output: "good", russian: false),
        CorrectionRule(input: "ABC", output: "LOUD", russian: false)]
    let compiled = CompiledCorrectionRules(settings.rules)
    for token in ["abc", "ABC", "bad", "missing", "(abc)", "abc!", "\"ABC\"", "bad...", "abc,bad"] {
        for disabled in [false, true] {
            settings.toRussian = !disabled
            let original = AutoCorrection.detect(token, recognizes: { _, _ in false }, settings: settings)
            let indexed = AutoCorrection.detect(token, recognizes: { _, _ in false }, settings: settings, rules: compiled)
            expect(original?.text == indexed?.text && original?.layout == indexed?.layout &&
                   original?.preservesExactCase == indexed?.preservesExactCase,
                   "indexed rules retain invalid/duplicate/case/disabled/recursive semantics")
        }
    }
    settings.excludedWords = ["abc", "good"]
    for token in ["abc", "bad", "(bad)"] {
        let result = AutoCorrection.detect(token, recognizes: { _, _ in false }, settings: settings, rules: compiled)
        expect(result == nil, "source/target exclusions still outrank compiled rules")
    }
    print("Passed \(count) input-performance regression checks")
    return count
}

func benchmarkInputPerformance() {
    let dictionary = LocalDictionary()
    let corpus = ["ghbdtn", "lkz", "b[", "руддщ", "hello", "привет", "f,vfqrbyf.",
                  "((((ghbdtn))))", "ghbdtn,ghbdtn", "word999", "unsupportedword", String(repeating: "z", count: 48)]
    func measure(_ name: String, run: (String) -> AutoCorrection?) -> [Double] {
        for token in corpus { _ = run(token) }
        var values: [Double] = [], checksum = 0
        for i in 0..<120 {
            let token = corpus[i % corpus.count]
            let start = DispatchTime.now().uptimeNanoseconds
            let result = run(token)
            values.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            checksum += result?.text.utf16.count ?? 0
        }
        values.sort()
        print(String(format: "%@: p50 %.4f ms, p95 %.4f ms, max %.4f ms; checksum %d", name,
                     values[values.count / 2], values[Int(Double(values.count) * 0.95)], values.last!, checksum))
        return values
    }
    for ruleCount in [0, 1000] {
        var settings = CorrectionSettings()
        settings.rules = (0..<ruleCount).map { CorrectionRule(input: "word\($0)", output: "replacement\($0)", russian: false) }
        settings.excludedWords = (0..<5000).map { "excluded\($0)" }
        settings.wordExclusionRules = (0..<500).map { WordExclusionRule("pattern-\($0)-end", match: .contains) }
        let exclusions = CompiledExclusions(settings.excludedWords, rules: settings.wordExclusionRules!)
        let rules = CompiledCorrectionRules(settings.rules)
        for token in corpus {
            let a = AutoCorrection.detect(token, recognizes: dictionary.recognizes,
                recognizesFragment: dictionary.recognizesCommon, recognizesBackoff: dictionary.recognizesBackoff,
                settings: settings, exclusions: exclusions)
            let b = AutoCorrection.detect(token, recognizes: dictionary.recognizes,
                recognizesFragment: dictionary.recognizesCommon, recognizesBackoff: dictionary.recognizesBackoff,
                settings: settings, exclusions: exclusions, rules: rules)
            precondition(a?.text == b?.text && a?.layout == b?.layout)
        }
        _ = measure("linear rules=\(ruleCount)") { token in
            AutoCorrection.detect(token, recognizes: dictionary.recognizes,
                recognizesFragment: dictionary.recognizesCommon, recognizesBackoff: dictionary.recognizesBackoff,
                settings: settings, exclusions: exclusions)
        }
        _ = measure("indexed rules=\(ruleCount)") { token in
            AutoCorrection.detect(token, recognizes: dictionary.recognizes,
                recognizesFragment: dictionary.recognizesCommon, recognizesBackoff: dictionary.recognizesBackoff,
                settings: settings, exclusions: exclusions, rules: rules)
        }
    }
    print("Scope: local detector CPU time with bundled dictionaries and maximum exclusion lists; not end-to-end OS/editor latency.")
}
