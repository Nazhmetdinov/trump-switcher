import Foundation
import SwitcherCore

func inputSourceRollbackChecks() -> Int {
    var checks = 0
    func expect(_ value: @autoclosure () -> Bool, _ name: String) {
        guard value() else { fputs("Source rollback: \(name)\n", stderr); exit(1) }
        checks += 1
    }
    let english = KeyboardLayoutTable(id: "com.apple.keylayout.ABC")!
    let russian = KeyboardLayoutTable(id: "com.apple.keylayout.Russian")!
    let pid: Int32 = 42
    let start: UInt64 = 200_000_000
    let finish: UInt64 = 210_000_000

    for (previous, temporary, word) in [(english, russian, "hello"), (russian, english, "привет")] {
        var source: String? = temporary.id
        var front: Int32? = pid
        var selectCalls = 0
        let ticket = InputSourceRollback(previous: previous, temporary: temporary, startedAt: start, destinationPID: pid)!
        let rollback = ticket.restore(preserving: nil, currentSource: { source }, foregroundPID: { front },
            selectPrevious: { selectCalls += 1; source = previous.id; return true }, restoredAt: { finish })!
        expect(selectCalls == 1 && source == previous.id, "restore owns only the temporary source")
        var output = ""
        for (index, character) in word.enumerated() {
            let key = previous.replacement(String(character))!
            let stale = temporary.character(code: key.code, shift: key.shift, capsLock: false, option: key.option)!
            func normalize(_ text: String, _ timestamp: UInt64, system: Bool = true) -> String? {
                rollback.normalized(text, code: key.code, shift: key.shift, capsLock: false, option: key.option,
                                    timestamp: timestamp, currentID: source, systemEvent: system)
            }
            output += normalize(stale, start + UInt64(index) + 1) ?? stale
            expect(normalize(stale, start) == nil, "boundary before temporary switch stays unchanged")
            expect(normalize(stale, start - 1) == nil, "earlier arbitrary mixed payload stays unchanged")
            expect(normalize(String(character), finish + 1) == nil, "already restored payload stays unchanged")
            expect(normalize(stale, finish + 100_000_001) == nil, "late stale payload stays unchanged")
            expect(normalize(stale, start + 1, system: false) == nil, "foreign injection cannot enter rollback interval")
        }
        expect(output == word, "whole stale word follows restored source: " + word)

        // A queued earlier cohort remains proved only in its original interval;
        // rollback must not erase it or bridge an unproved timestamp gap.
        let prior = QueuedLayoutTransition(previous: temporary, target: previous, boundary: 10, selectedAt: 20)
        source = temporary.id
        let merged = ticket.restore(preserving: prior, currentSource: { source }, foregroundPID: { front },
            selectPrevious: { source = previous.id; return true }, restoredAt: { finish })!
        let key = previous.replacement(String(word.first!))!
        let stale = temporary.character(code: key.code, shift: key.shift, capsLock: false, option: key.option)!
        func normalized(_ t: QueuedLayoutTransition, _ at: UInt64) -> String? {
            t.normalized(stale, code: key.code, shift: key.shift, capsLock: false, option: key.option,
                         timestamp: at, currentID: previous.id, systemEvent: true)
        }
        expect(normalized(merged, 100) == String(word.first!), "earlier forward cohort survives rollback")
        expect(normalized(merged, 150_000_000) == nil, "gap between source windows is not widened")
        expect(normalized(merged, start + 1) == String(word.first!), "temporary source cohort is restored")
        let sameSource = QueuedLayoutTransition.committed(previous: previous, target: previous, boundary: finish,
                                                         selectedAt: finish + 1, preserving: merged)!
        expect(normalized(sameSource, 100) == String(word.first!), "same-source commit preserves earlier forward cohort")
        expect(normalized(sameSource, start + 1) == String(word.first!), "same-source commit preserves rollback cohort")
        expect(InputSourceRollback(previous: previous, temporary: previous, startedAt: start, destinationPID: pid) == nil,
               "no-op source selection has no rollback ownership")

        selectCalls = 0; source = "external-source"
        expect(ticket.restore(preserving: prior, currentSource: { source }, foregroundPID: { front },
            selectPrevious: { selectCalls += 1; return true }, restoredAt: { finish }) == nil && selectCalls == 0,
               "external source change is never overwritten")
        source = temporary.id; front = pid + 1
        expect(ticket.restore(preserving: prior, currentSource: { source }, foregroundPID: { front },
            selectPrevious: { selectCalls += 1; return true }, restoredAt: { finish }) == nil && selectCalls == 0,
               "external application change is never overwritten")
        front = pid
        expect(ticket.restore(preserving: prior, currentSource: { source }, foregroundPID: { front },
            selectPrevious: { false }, restoredAt: { finish }) == nil, "failed source selection cannot authorize normalization")
        expect(ticket.restore(preserving: prior, currentSource: { source }, foregroundPID: { front },
            selectPrevious: { true }, restoredAt: { finish }) == nil, "unconfirmed source selection cannot authorize normalization")
        source = temporary.id
        expect(ticket.restore(preserving: prior, currentSource: { source }, foregroundPID: { front },
            selectPrevious: { source = previous.id; front = pid + 1; return true }, restoredAt: { finish }) == nil,
               "focus change during restore cannot authorize normalization")
        expect(normalized(prior, 100) == String(word.first!), "refused rollback leaves previous immutable proof intact")
    }

    // A successful automatic correction first selects the corrected word's
    // layout. Its final keyUp must cross the destination before the old layout
    // is selected; keys captured during that short interval can still carry
    // the temporary layout's Unicode payload after the return.
    var selected: String? = russian.id
    let forward = QueuedLayoutTransition.committed(previous: english, target: russian,
        boundary: 100, selectedAt: 101, preserving: nil)!
    let oneWord = InputSourceRollback(previous: english, temporary: russian,
        startedAt: 101, destinationPID: pid)!
    let returned = oneWord.restore(preserving: forward, currentSource: { selected },
        foregroundPID: { pid }, selectPrevious: { selected = english.id; return true },
        restoredAt: { 150 })!
    let englishKey = english.replacement("h")!
    let staleRussian = russian.character(code: englishKey.code, shift: englishKey.shift,
        capsLock: false, option: englishKey.option)!
    expect(selected == english.id, "successful one-word correction returns to its prior input source")
    expect(returned.normalized(staleRussian, code: englishKey.code, shift: englishKey.shift,
        capsLock: false, option: englishKey.option, timestamp: 125,
        currentID: selected, systemEvent: true) == "h", "queued next-word keys retain their intended layout")
    expect(returned.normalized("h", code: englishKey.code, shift: englishKey.shift,
        capsLock: false, option: englishKey.option, timestamp: 151,
        currentID: selected, systemEvent: true) == nil, "keys after the return stay unchanged")

    var chain = QueuedLayoutTransition(previous: english, target: russian, boundary: 1, selectedAt: 2)
    for index in 1..<32 {
        var source: String? = english.id
        let at = UInt64(index + 1) * 1_000
        let ticket = InputSourceRollback(previous: russian, temporary: english, startedAt: at, destinationPID: pid)!
        expect(chain.canPreserveAdditionalWindow, "bounded history admits window \(index + 1)")
        chain = ticket.restore(preserving: chain, currentSource: { source }, foregroundPID: { pid },
            selectPrevious: { source = russian.id; return true }, restoredAt: { at + 1 })!
    }
    expect(!chain.canPreserveAdditionalWindow, "full history refuses another temporary switch before selecting source")
    var selects = 0
    let fullTicket = InputSourceRollback(previous: russian, temporary: english, startedAt: 40_000, destinationPID: pid)!
    expect(fullTicket.restore(preserving: chain, currentSource: { english.id }, foregroundPID: { pid },
        selectPrevious: { selects += 1; return true }, restoredAt: { 40_001 }) == nil && selects == 0,
           "full history cannot discard an earlier queued cohort")
    expect(chain.normalized("h", code: 4, shift: false, capsLock: false, option: false,
                            timestamp: 100, currentID: russian.id, systemEvent: true) == "р",
           "earliest cohort is still available at capacity")
    print("Passed \(checks) input source rollback checks")
    return checks
}
