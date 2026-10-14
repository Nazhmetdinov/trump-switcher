// Compile with InputPipelineEventPlan.swift. Pure values only: no framework,
// input source, CGEvent, Accessibility, UI, process launch, or event posting.
@main enum InputPipelineEventPlanChecks {
    static func main() {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ reason: String) {
            precondition(condition(), reason)
            checks += 1
        }
        typealias Event = InputPipelineEventPlan.Event
        // Independent physical-press oracle: repeat is legal only while that
        // same key is down, and every held key must eventually be released.
        func hasValidPressLifecycle(_ events: [Event]) -> Bool {
            var held = Set<UInt16>()
            for event in events {
                if event.down {
                    if event.autorepeat == 1 {
                        guard held.contains(event.code) else { return false }
                    } else {
                        guard event.autorepeat == 0, held.insert(event.code).inserted else { return false }
                    }
                } else {
                    guard event.autorepeat == 0, held.remove(event.code) != nil else { return false }
                }
            }
            return held.isEmpty
        }
        let codes: [UInt16] = [37, 40, 6, 49]
        let repeated = InputPipelineEventPlan.make(codes: codes, repeatFinalSpace: true)!
        let signature = repeated.events.map { "\($0.down ? "down" : "up"):\($0.code):\($0.autorepeat)" }
        expect(signature == ["down:37:0", "up:37:0", "down:40:0", "up:40:0", "down:6:0", "up:6:0",
                             "down:49:0", "down:49:1", "up:49:0"], "fixed original order")
        expect(repeated.groups.map(\.count) == [2, 2, 2, 3], "one atomic held-Space group")
        expect(repeated.keyDownCount == 5 && repeated.keyUpCount == 4 && repeated.repeatCount == 1,
               "separate original down/up/repeat counts")
        expect(hasValidPressLifecycle(repeated.events), "repeat has a preceding press and one final release")
        let ordinary = InputPipelineEventPlan.make(codes: codes + [49], repeatFinalSpace: false)!
        expect(ordinary.keyDownCount == 5 && ordinary.keyUpCount == 5 && ordinary.repeatCount == 0,
               "two ordinary Spaces remain distinct presses")
        expect(ordinary.events != repeated.events, "repeated Space is not disguised as a second key pair")
        expect(hasValidPressLifecycle(ordinary.events), "ordinary repeated key presses remain balanced")
        expect(InputPipelineEventPlan.make(codes: [], repeatFinalSpace: false)!.events.isEmpty,
               "manual-only fixture can still have no key events")
        for bad: [UInt16] in [[], [49], [37, 40, 6], [37, 40, 6, 48], [37, 40, 6, 36],
                              [37, 40, 6, 51], [37, 40, 6, 49, 49], [40, 37, 6, 49]] {
            expect(InputPipelineEventPlan.make(codes: bad, repeatFinalSpace: true) == nil,
                   "only the reviewed l/k/z/Space sequence can request autorepeat")
        }
        // Confirm that the independent oracle catches the actual ownership
        // mistakes this test is meant to expose, rather than accepting counts.
        var noRelease = repeated.events; noRelease.removeLast()
        expect(!hasValidPressLifecycle(noRelease), "missing final release is detected")
        var duplicateRelease = repeated.events; duplicateRelease.append(Event(code: 49, down: false, autorepeat: 0))
        expect(!hasValidPressLifecycle(duplicateRelease), "duplicate release is detected")
        var earlyRelease = repeated.events
        earlyRelease.swapAt(7, 8)
        expect(!hasValidPressLifecycle(earlyRelease), "repeat after release is detected despite unchanged totals")
        var repeatWithoutPress = repeated.events; repeatWithoutPress.remove(at: 6)
        expect(!hasValidPressLifecycle(repeatWithoutPress), "orphaned repeat is detected")
        print("Passed \(checks) owned-fixture input plan checks; no system reads or events")
    }
}
