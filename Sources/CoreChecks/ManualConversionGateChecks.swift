import Foundation
import SwitcherCore

func manualConversionGateChecks() -> Int {
    var checks = 0
    func expect(_ value: @autoclosure () -> Bool, _ name: String) {
        guard value() else { fputs("Manual conversion race: \(name)\n", stderr); exit(1) }
        checks += 1
    }

    // A fake destination keeps posted originals separate from applied text.
    // Neither cancellation nor a transport ACK is allowed to execute a manual
    // callback that was refused while those originals were still in flight.
    final class Pipeline {
        var gate = ManualConversionGate()
        var queued = ["l", "k", "z", " "]
        var posted: [String] = []
        var text = ""
        var pending = true
        var cancellations = 0
        var reads = 0
        var writes = 0

        func cancel(at time: TimeInterval) {
            guard pending || !queued.isEmpty else { return }
            cancellations += 1
            posted += queued
            queued.removeAll()
            pending = false
            gate.noteInputHandoff(at: time)
        }
        func manual(at time: TimeInterval) {
            guard gate.request(hasPendingInput: pending, at: time) else {
                cancel(at: time)
                return
            }
            cancel(at: time)
            reads += 1
            text = Conversion.convert(text, to: .russian)
            writes += 1
        }
        func deliver(at time: TimeInterval) {
            text += posted.joined()
            posted.removeAll()
            gate.noteInputHandoff(at: time)
        }
    }

    let pending = Pipeline()
    pending.manual(at: 10)
    expect(pending.reads == 0 && pending.writes == 0 && pending.text.isEmpty,
           "pending request cannot read stale text or write before originals")
    expect(pending.cancellations == 1 && pending.posted == ["l", "k", "z", " "],
           "refusal returns each owned original in order once")
    pending.manual(at: 10.2)
    expect(pending.reads == 0 && pending.cancellations == 1 && pending.posted.count == 4,
           "repeated request during grace cannot duplicate originals")
    pending.deliver(at: 10.8)
    expect(pending.text == "lkz " && pending.reads == 0 && pending.writes == 0,
           "late delivery cannot run the refused manual operation")
    pending.manual(at: 11.1)
    expect(pending.reads == 0 && pending.text == "lkz ",
           "last delivery extends grace beyond the original cancellation")
    pending.manual(at: 11.8)
    expect(pending.reads == 1 && pending.writes == 1 && pending.text == "для ",
           "explicit idle retry invokes exactly one current-text conversion")

    // Carbon delivers the hotkey after its Control modifier has already
    // cancelled the automatic proposal and emptied the monitor's old FIFO.
    let carbon = Pipeline()
    carbon.cancel(at: 20)
    expect(!carbon.pending && carbon.queued.isEmpty, "modifier already cleared pending state")
    carbon.manual(at: 20.01)
    expect(carbon.reads == 0 && carbon.writes == 0 && carbon.posted.count == 4,
           "same hotkey still refuses after modifier-induced cancellation")
    carbon.deliver(at: 20.2)
    expect(carbon.reads == 0 && carbon.writes == 0, "ACK never retries manual conversion automatically")

    var gate = ManualConversionGate()
    expect(gate.request(hasPendingInput: false, at: 0), "initial idle request is available")
    gate.noteInputHandoff(at: 30)
    gate.noteInputHandoff(at: 29)
    expect(gate.blockUntil == 31, "stale handoff cannot shorten the grace period")
    expect(!gate.request(hasPendingInput: false, at: Double(31).nextDown), "request before deadline is refused")
    expect(gate.request(hasPendingInput: false, at: 31), "exact deadline permits an explicit request")
    expect(!gate.request(hasPendingInput: true, at: 100), "pending input remains blocked regardless of old deadline")
    expect(!gate.request(hasPendingInput: false, at: 100.5), "pending refusal remembers the interrupted request")
    expect(!gate.request(hasPendingInput: false, at: .nan), "invalid time cannot authorize an edit")
    expect(!gate.request(hasPendingInput: false, at: .infinity), "infinite time cannot skip grace")

    print("Passed \(checks) manual conversion gate checks")
    return checks
}
