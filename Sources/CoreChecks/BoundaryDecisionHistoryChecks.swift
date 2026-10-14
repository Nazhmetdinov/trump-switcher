import Foundation
import SwitcherCore

func boundaryDecisionHistoryChecks() -> Int {
    var checks = 0
    func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
        guard condition() else { fatalError("Boundary diagnostic: \(name)") }
        checks += 1
    }
    var history = BoundaryDecisionHistory(capacity: 3)
    expect(history.begin(id: 10, processID: 101, characterCount: 3), "start an asynchronous word check")
    expect(history.entries.isEmpty, "a proposal is not a final result")
    expect(!history.begin(id: 11, processID: 202, characterCount: 5), "another proposal cannot replace pending metadata")
    expect(!history.finish(id: 9, outcome: .posted, reason: "stale"), "a stale callback cannot finish the pending word")
    // Retries retain transaction 10; there is no finish call until it reaches
    // an actual terminal outcome. The reason is fixed metadata, not a word.
    expect(history.finish(id: 10, outcome: .preserved, reason: "Редактор не подтвердил поле до срока ожидания"),
           "terminal refusal is retained")
    expect(history.entries.count == 1 && history.entries[0].transactionID == 10 &&
           history.entries[0].processID == 101 && history.entries[0].characterCount == 3 &&
           history.entries[0].outcome == .preserved, "terminal record retains original transaction metadata")
    let originalReason = history.entries[0].reason
    expect(!history.finish(id: 10, outcome: .posted, reason: "late"), "late success cannot replace an earlier refusal")
    expect(history.entries[0].reason == originalReason, "a later status does not overwrite the saved reason")

    expect(history.begin(id: 11, processID: 101, characterCount: 0), "literal continuation has no retained word")
    expect(history.finish(id: 11, outcome: .posted, reason: "Продолжение многоточия отправлено"), "commit is recorded as posted")
    expect(history.entries[0].reason == originalReason, "following continuation cannot erase the previous outcome")
    expect(history.entries[1].outcome == .posted, "posting never claims editor confirmation")

    expect(history.begin(id: 12, processID: 202, characterCount: 5), "new application gets new transaction metadata")
    expect(history.finish(id: 12, outcome: .cancelled, reason: "Проверка отменена; исходные клавиши сохранены"),
           "focus/shortcut cancellation finishes its owned transaction")
    expect(history.begin(id: 13, processID: 202, characterCount: 7), "new pending check after cancellation")
    expect(!history.finish(id: 12, outcome: .posted, reason: "old worker"), "cancelled worker cannot finish a newer transaction")
    expect(history.finish(id: 13, outcome: .timedOut, reason: "Редактор не ответил вовремя; исходные клавиши сохранены"),
           "watchdog timeout retains its own final reason")
    expect(history.entries.map(\.transactionID) == [11, 12, 13], "bounded history evicts only the oldest final result")
    expect(history.entries.map(\.outcome) == [.posted, .cancelled, .timedOut], "different terminal paths keep their outcomes")
    expect(!history.finish(id: 10, outcome: .posted, reason: "evicted worker"), "an evicted old callback cannot reinsert itself")

    expect(!history.begin(id: 14, processID: 303, characterCount: -1), "invalid diagnostic metadata is rejected")
    expect(history.begin(id: 14, processID: 303, characterCount: 128), "rejection cannot occupy the pending slot")
    expect(history.finish(id: 14, outcome: .preserved, reason: String(repeating: "x", count: 1_000)), "large reason cannot grow history without bound")
    expect(history.entries.last?.reason.count == 240, "reason storage is bounded")
    for id: UInt64 in 15..<1_015 {
        expect(history.begin(id: id, processID: 404, characterCount: 1), "sequential transaction starts")
        expect(history.finish(id: id, outcome: .preserved, reason: "fixed"), "sequential transaction finishes")
        expect(history.entries.count == 3, "long typing session keeps fixed history capacity")
    }
    expect(history.entries.map(\.transactionID) == [1_012, 1_013, 1_014], "history order follows final decisions")
    print("Passed \(checks) boundary decision history checks")
    return checks
}
