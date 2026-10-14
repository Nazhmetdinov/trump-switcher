import Foundation
import SwitcherCore

func wordReplacementChecks() -> Int {
    var count = 0
    func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
        guard condition() else { fatalError("Word replacement: " + name) }
        count += 1
    }
    final class Editor {
        var text: String
        var selection: NSRange
        var current = true
        var writes = 0
        var selections = 0
        init(_ text: String, _ caret: Int) { self.text = text; selection = NSRange(location: caret, length: 0) }
        func read(_ range: NSRange) -> String? {
            guard range.location >= 0, NSMaxRange(range) <= text.utf16.count else { return nil }
            return (text as NSString).substring(with: range)
        }
        func write(_ plan: WordReplacementPlan) {
            writes += 1
            text = (text as NSString).replacingCharacters(in: plan.target, with: plan.replacement)
            selection = plan.resultSelection
        }
    }
    let words = [("lkz", "для"), ("Lkz", "Для"), ("b[", "их"), ("B[", "Их"),
                 ("руддщ", "hello"), ("ghbdtn", "привет!"), ("g", "длинная замена"),
                 ("нфтвучюкг", "yandex.ru"), ("hf,jnftn", "работает")]
    for (original, replacement) in words {
        for prefix in ["", "До этого ", "🙂 ", "предыдущее\n", "\t"] {
            for suffix in ["", " после", "\nстрока", "?!", "\t"] {
                for direct in [false, true] {
                    let editor = Editor(prefix + original + suffix, prefix.utf16.count + original.utf16.count)
                    let plan = WordReplacementPlan(original: original, replacement: replacement, selection: editor.selection,
                        beforeCaret: prefix + original, afterCaret: suffix)!
                    let result = WordReplacement.perform(plan, needsSelection: direct,
                        isCurrent: { editor.current }, selection: { editor.selection }, read: editor.read,
                        select: { editor.selection = $0; editor.selections += 1; return .accepted },
                        write: { editor.write(plan); return .accepted }, awaitSelection: { editor.selection == $0 },
                        awaitResult: { editor.read(plan.resultRange) == replacement })
                    expect(result == .confirmed, "confirmed complete word: " + original)
                    expect(editor.text == prefix + replacement + suffix, "preserve both neighbours and every final letter")
                    expect(editor.writes == 1 && editor.selections == (direct ? 1 : 0), "one content write, never backspaces")
                    expect(editor.selection == plan.resultSelection, "caret after replacement of any length")
                    // The real boundary is delivered afterwards, once. Enter/Tab
                    // are actions and are deliberately absent from the write.
                    for boundary in [" ", "\u{00a0}", "\n", "\t"] {
                        let text = (editor.text as NSString).replacingCharacters(in: editor.selection, with: boundary)
                        expect(text == prefix + replacement + boundary + suffix, "next physical boundary preserves word")
                    }
                }
            }
        }
    }
    for fault in ["focus-before", "text-before", "selection-before", "selection-refused", "focus-after-selection",
                  "text-after-selection", "write-timeout-but-applied", "write-late", "wrong-result", "focus-after-write", "caret-after-write"] {
        let editor = Editor("before lkz after", 10)
        let plan = WordReplacementPlan(original: "lkz", replacement: "для", selection: editor.selection,
                                       beforeCaret: "before lkz", afterCaret: " after")!
        if fault == "focus-before" { editor.current = false }
        if fault == "text-before" { editor.text = "before xxx after" }
        if fault == "selection-before" { editor.selection = NSRange(location: 9, length: 0) }
        var pending = false
        let result = WordReplacement.perform(plan, needsSelection: true,
            isCurrent: { editor.current }, selection: { editor.selection }, read: editor.read,
            select: { range in
                editor.selections += 1
                if fault != "selection-refused" { editor.selection = range }
                if fault == "focus-after-selection" { editor.current = false }
                if fault == "text-after-selection" { editor.text = "before xxx after" }
                return fault == "selection-refused" ? .rejected : .accepted
            }, write: {
                if fault == "write-late" { editor.writes += 1; pending = true; return .uncertain }
                editor.write(plan)
                if fault == "wrong-result" { editor.text = "before дл after" }
                if fault == "focus-after-write" { editor.current = false }
                if fault == "caret-after-write" { editor.selection = NSRange(location: 0, length: 0) }
                return fault == "write-timeout-but-applied" ? .uncertain : .accepted
            }, awaitSelection: { editor.selection == $0 },
            awaitResult: { editor.read(plan.resultRange) == "для" })
        if ["focus-before", "text-before", "selection-before", "selection-refused", "focus-after-selection"].contains(fault) {
            expect(result == .refused && editor.writes == 0, "refuse changed context: " + fault)
        } else if fault == "text-after-selection" {
            expect(result == .unsafeSelection && editor.writes == 0, "do not pass a boundary into a changed selected word")
        } else if fault == "write-timeout-but-applied" {
            expect(result == .confirmed && editor.writes == 1, "readback, not AX return code, proves success")
        } else {
            expect(result == (fault == "focus-after-write" ? .unconfirmed : .unsafeSelection) && editor.writes == 1,
                   "no boundary/second write into uncertain selection: " + fault)
            if pending {
                editor.text = (editor.text as NSString).replacingCharacters(in: plan.target, with: plan.replacement)
                expect(editor.text == "before для after", "late acknowledgement cannot trigger duplicate deletion")
            }
        }
    }

    // Regression for the real 0.6.23 bug: isCurrent used to include the deadline.
    // Successful selection + exhausted budget then skipped restoration, and the
    // released Space replaced the entire selected word.
    for fault in ["budget-after-select", "write-rejected", "selection-timeout-applied", "restore-late"] {
        for boundary in [" ", "\n", "\t", "!"] {
            let editor = Editor("prefix lkz", 10)
            let plan = WordReplacementPlan(original: "lkz", replacement: "для", selection: editor.selection,
                beforeCaret: editor.text, afterCaret: "")!
            var budget = true
            var restorationChecks = 0
            let result = WordReplacement.perform(plan, needsSelection: true,
                isCurrent: { editor.current }, selection: { editor.selection }, read: editor.read,
                select: { range in
                    editor.selections += 1
                    if !(fault == "restore-late" && range == plan.initialSelection) { editor.selection = range }
                    return fault == "selection-timeout-applied" && range == plan.target ? .uncertain : .accepted
                }, write: { editor.writes += 1; return .rejected },
                awaitSelection: { expected in
                    if fault != "write-rejected" { budget = false }
                    return fault != "selection-timeout-applied" && editor.selection == expected
                }, awaitResult: { false }, mayContinue: { budget },
                awaitRestoration: { expected in
                    restorationChecks += 1
                    if fault == "restore-late" { editor.selection = expected }
                    return editor.selection == expected
                })
            expect(result == .refused, "rejected/deadline edit has a safe cursor: " + fault)
            expect(editor.writes == (fault == "write-rejected" ? 1 : 0), "no mutation after selection deadline")
            expect(editor.selection == plan.initialSelection && restorationChecks == 1, "separate bounded restoration budget")
            editor.text = (editor.text as NSString).replacingCharacters(in: editor.selection, with: boundary)
            expect(editor.text == "prefix lkz" + boundary, "physical boundary must not erase selected word: " + fault)
        }
    }
    for fault in ["selection-timeout-pending", "restore-rejected", "restore-timeout", "restore-no-effect",
                  "write-accepted-no-effect", "write-timeout-pending"] {
        let editor = Editor("prefix lkz", 10)
        let plan = WordReplacementPlan(original: "lkz", replacement: "для", selection: editor.selection,
            beforeCaret: editor.text, afterCaret: "")!
        var budget = true
        var pendingWrite = false
        var pendingSelection = false
        let result = WordReplacement.perform(plan, needsSelection: true,
            isCurrent: { editor.current }, selection: { editor.selection }, read: editor.read,
            select: { range in
                editor.selections += 1
                if range == plan.target {
                    if fault == "selection-timeout-pending" { pendingSelection = true; return .uncertain }
                    editor.selection = range; return .accepted
                }
                switch fault {
                case "restore-rejected": return .rejected
                case "restore-timeout": return .uncertain
                case "restore-no-effect": return .accepted
                default: fatalError("An uncertain text write must not move its selection")
                }
            }, write: {
                editor.writes += 1
                if fault == "write-timeout-pending" { pendingWrite = true; return .uncertain }
                return .accepted
            }, awaitSelection: { expected in
                if fault.hasPrefix("restore-") { budget = false }
                return editor.selection == expected
            }, awaitResult: { false }, mayContinue: { budget }, awaitRestoration: { _ in false })
        expect(result == .unsafeSelection, "unsettled mutation cannot release a boundary: " + fault)
        expect(editor.text == "prefix lkz", "uncertain transaction does not delete original text")
        expect(editor.writes == (fault.hasPrefix("write-") ? 1 : 0), "never fall through to another text write")
        if pendingSelection {
            editor.selection = plan.target
            expect(editor.text == "prefix lkz", "late select was flagged unsafe even while initial read looked unchanged")
        }
        if pendingWrite {
            expect(editor.selection == plan.target && editor.selections == 1, "pending SelectedText request retains its original target")
            editor.text = (editor.text as NSString).replacingCharacters(in: editor.selection, with: plan.replacement)
            expect(editor.text == "prefix для", "late write has no stale-cursor insertion or duplicate deletion")
        }
    }
    for request in [WordReplacementRequestResult.rejected, .accepted, .uncertain] {
        let editor = Editor("prefix lkz", 10)
        let plan = WordReplacementPlan(original: "lkz", replacement: "для", selection: editor.selection,
            beforeCaret: editor.text, afterCaret: "")!
        let result = WordReplacement.perform(plan, needsSelection: false,
            isCurrent: { true }, selection: { editor.selection }, read: editor.read,
            select: { _ in fatalError("Atomic range transport must never select text") },
            write: { editor.writes += 1; return request }, awaitSelection: { _ in false }, awaitResult: { false })
        expect(result == (request == .rejected ? .refused : .unconfirmed), "atomic write honours request result")
        expect(editor.selection == plan.initialSelection && editor.writes == 1, "atomic timeout leaves no selected word")
        editor.text = (editor.text as NSString).replacingCharacters(in: editor.selection, with: " ")
        expect(editor.text == "prefix lkz ", "atomic unconfirmed result cannot erase word through a selected range")
    }
    for needsSelection in [false, true] {
        let editor = Editor("prefix lkz", 10)
        let plan = WordReplacementPlan(original: "lkz", replacement: "для", selection: editor.selection,
            beforeCaret: editor.text, afterCaret: "")!
        var budget = true
        let result = WordReplacement.perform(plan, needsSelection: needsSelection,
            isCurrent: { true }, selection: { editor.selection }, read: editor.read,
            select: { editor.selection = $0; return .accepted },
            write: { editor.write(plan); budget = false; return .uncertain },
            awaitSelection: { editor.selection == $0 }, awaitResult: { false }, mayContinue: { budget })
        expect(result == .confirmed && editor.writes == 1, "final matching read confirms timeout response at deadline")
        expect(editor.selection == plan.resultSelection, "confirmed result leaves collapsed cursor")
    }
    // WebKit AXTextOperation selects its replacement. The manual caller may
    // collapse only that verified range, and must preserve trailing spaces.
    for (before, after) in [("lkz", "для"), ("b[", "их"), ("руддщ", "hello"), ("g", "длиннее")] {
        for prefix in ["", "prefix ", "🙂\n"] {
            for trailing in ["", " ", "  "] {
                let target = NSRange(location: prefix.utf16.count, length: before.utf16.count)
                let initial = NSRange(location: NSMaxRange(target) + trailing.utf16.count, length: 0)
                let plan = MarkerReplacementPlan(initialCaret: initial, target: target, before: before, after: after)!
                expect(plan.state(selection: initial, originalText: before, replacementText: nil) == .waiting,
                    "late marker response may leave original caret temporarily")
                expect(plan.state(selection: target, originalText: before, replacementText: nil) == .waiting,
                    "never collapse a marker command's still-unreplaced original")
                expect(plan.state(selection: plan.replacementRange, originalText: nil, replacementText: after) == .collapse(plan.finalCaret),
                    "WebKit selected replacement authorizes exactly one collapse")
                expect(plan.state(selection: plan.finalCaret, originalText: nil, replacementText: after) == .complete,
                    "already collapsed marker replacement requires no cursor mutation")
                let edited = prefix + after + trailing
                let following = (edited as NSString).replacingCharacters(in: plan.finalCaret, with: " далее")
                expect(following == edited + " далее", "verified collapse preserves replacement and trailing separators")
                expect(plan.state(selection: NSRange(location: plan.finalCaret.location + 1, length: 0),
                    originalText: nil, replacementText: after) == .changed, "do not restore over subsequent typing")
                expect(plan.state(selection: NSRange(location: plan.replacementRange.location, length: plan.replacementRange.length + 1),
                    originalText: nil, replacementText: after) == .changed, "do not collapse an unrelated selection")
                expect(plan.state(selection: plan.replacementRange, originalText: "changed", replacementText: "changed") == .changed,
                    "matching selected offsets alone never authorize cursor movement")
            }
        }
    }
    // Explicit phrases retain their selection, including UTF-16 offsets after
    // emoji and a replacement whose length differs from the original.
    for (before, after) in [("ghbdtn vbh", "привет мир"), ("руддщ цщкдв", "hello world"), ("x", "длиннее"), ("longer", "я")] {
        for prefix in ["", "🙂 ", "prefix\n"] {
            let selected = NSRange(location: prefix.utf16.count, length: before.utf16.count)
            let plan = MarkerReplacementPlan(initialCaret: selected, target: selected, before: before, after: after)!
            expect(plan.finalSelection == NSRange(location: prefix.utf16.count, length: after.utf16.count),
                   "manual selected phrase retains exact replacement selection")
            expect(plan.state(selection: selected, originalText: before, replacementText: nil) == .waiting,
                   "unreplaced selected phrase is never collapsed")
            expect(plan.state(selection: plan.replacementRange, originalText: nil, replacementText: after) == .complete,
                   "WebKit selected result needs no selection mutation")
            expect(plan.state(selection: plan.finalCaret, originalText: nil, replacementText: after) == .collapse(plan.finalSelection),
                   "only verified result end-caret may restore the explicit selection")
            expect(plan.state(selection: NSRange(location: plan.finalCaret.location + 1, length: 0),
                              originalText: nil, replacementText: after) == .changed,
                   "selected marker conversion never overwrites a later cursor move")
            expect(plan.state(selection: NSRange(location: selected.location, length: after.utf16.count + 1),
                              originalText: nil, replacementText: after) == .changed,
                   "selected marker conversion rejects adjacent text in selection")
            expect(plan.state(selection: plan.finalCaret, originalText: "changed", replacementText: "changed") == .changed,
                   "matching end position without verified replacement never restores selection")
            let original = prefix + before + " / suffix"
            let changed = (original as NSString).replacingCharacters(in: selected, with: after)
            expect(changed == prefix + after + " / suffix" && (changed as NSString).substring(with: plan.finalSelection) == after,
                   "selected marker plan leaves prefix and suffix outside the converted phrase")
        }
    }
    expect(MarkerReplacementPlan(initialCaret: NSRange(location: 3, length: 1), target: NSRange(location: 0, length: 3),
        before: "lkz", after: "для") == nil, "selected marker completion cannot target a different range")
    for target in [NSRange(location: -1, length: 3), NSRange(location: NSNotFound, length: 3),
                   NSRange(location: Int.max - 1, length: 3), NSRange(location: 0, length: 4097)] {
        expect(MarkerReplacementPlan(initialCaret: target, target: target, before: "lkz", after: "для") == nil,
               "selected marker plan rejects invalid, overflowing or oversized ranges")
    }
    expect(MarkerReplacementPlan(initialCaret: NSRange(location: Int.max - 2, length: 1),
        target: NSRange(location: Int.max - 2, length: 1), before: "x", after: "longer") == nil,
        "selected replacement end may not overflow UTF-16 offsets")
    func selectedMarkers(_ selection: NSRange = NSRange(location: 3, length: 10),
                         target: NSRange = NSRange(location: 3, length: 10), start: Int = 3, end: Int = 13,
                         denied: Int? = nil, limit: Int = 128) -> (Int, Int)? {
        MarkerSelection.selectedRange(start: start, end: end, selection: selection, target: target,
            allowed: { $0 != denied }, same: ==, limit: limit)
    }
    expect(selectedMarkers().map { $0 == 3 && $1 == 13 } == true, "explicit markers keep both owned phrase endpoints")
    expect(selectedMarkers(denied: 3) == nil, "selected start marker outside editor refused")
    expect(selectedMarkers(denied: 13) == nil, "selected end marker outside editor refused")
    expect(selectedMarkers(end: 3) == nil, "nonempty selection cannot use collapsed marker endpoints")
    expect(selectedMarkers(NSRange(location: 4, length: 10)) == nil, "moved numeric selection rejects old marker endpoints")
    expect(selectedMarkers(limit: 9) == nil, "selected marker length remains bounded")
    let overflowing = NSRange(location: Int.max - 2, length: 10)
    expect(selectedMarkers(overflowing, target: overflowing) == nil, "selected marker UTF-16 range cannot overflow")
    for length in [129, 4096, 4097] {
        let before = String(repeating: "g", count: length), after = String(repeating: "п", count: length)
        let selected = NSRange(location: 3, length: length)
        let plan = MarkerReplacementPlan(initialCaret: selected, target: selected, before: before, after: after)
        expect((plan != nil) == (length <= 4096), "explicit manual phrase retains the 4096 UTF-16 limit, independent of 128-unit word bound")
        let endpoints = MarkerSelection.selectedRange(start: 3, end: 3 + length, selection: selected, target: selected,
            allowed: { _ in true }, same: ==)
        expect((endpoints != nil) == (length <= 4096), "selected endpoints accept 129 and 4096 but refuse 4097 without walking the field")
        if let plan {
            expect(plan.state(selection: selected, originalText: nil, replacementText: after) == .complete,
                   "long selected phrase remains selected after verified marker replacement")
        }
    }
    for length in [128, 129] {
        expect((MarkerReplacementPlan(initialCaret: NSRange(location: length, length: 0),
            target: NSRange(location: 0, length: length), before: String(repeating: "g", count: length),
            after: String(repeating: "п", count: length)) != nil) == (length == 128),
            "caret marker completion retains its bounded 128-unit traversal")
    }
    expect(MarkerReplacementPlan(initialCaret: NSRange(location: 0, length: 1), target: NSRange(location: 0, length: 1),
        before: "g", after: String(repeating: "п", count: 4097)) == nil, "selected replacement output above 4096 is rejected")
    expect(MarkerReplacementPlan(initialCaret: NSRange(location: 2, length: 0), target: NSRange(location: 0, length: 3),
        before: "lkz", after: "для") == nil, "marker target cannot extend beyond initial caret")
    for (before, after, length) in [("xlkz", "", 0), ("lkz", "x", 0), ("lkz", "", 1), ("lk", "", 0)] {
        expect(WordReplacementPlan(original: "lkz", replacement: "для", selection: NSRange(location: before.utf16.count, length: length),
            beforeCaret: before, afterCaret: after) == nil, "partial/stale/selected word never becomes a write")
    }
    expect(WordReplacementPlan(original: "x", replacement: "x", selection: NSRange(location: 1, length: 0),
        beforeCaret: "x", afterCaret: nil) == nil, "no-op never writes")
    print("Passed \(count) complete-word transaction checks")
    return count
}
