import AppKit
import SwitcherCore

/// Integration check against real NSTextView editing/Accessibility methods in
/// this process. No event posting, other apps, permission grants or clipboard.
enum EditorReplacementChecks {
    static func run() -> Int {
        _ = NSApplication.shared
        var count = focusResolutionChecks()
        for rich in [false, true] {
            for spelling in [false, true] {
                for (original, corrected) in [("lkz", "для"), ("Lkz", "Для"), ("b[", "их"), ("B[", "Их"),
                                             ("руддщ", "hello"), ("hf,jnftn", "работает"), ("ghbdtn", "привет!"),
                                             ("нфтвучюкг", "yandex.ru"), ("x", "слово длиннее")] {
                    for prefix in ["", "prefix ", "🙂\n"] {
                        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 150))
                        view.isRichText = rich
                        view.isContinuousSpellCheckingEnabled = spelling
                        view.isAutomaticSpellingCorrectionEnabled = spelling
                        view.isAutomaticTextReplacementEnabled = spelling
                        let suffix = " следующий текст"
                        view.string = prefix + original + suffix
                        let initial = NSRange(location: prefix.utf16.count + original.utf16.count, length: 0)
                        view.setSelectedRange(initial)
                        let plan = WordReplacementPlan(original: original, replacement: corrected, selection: initial,
                            beforeCaret: prefix + original, afterCaret: suffix)!
                        func read(_ range: NSRange) -> String? {
                            guard NSMaxRange(range) <= view.string.utf16.count else { return nil }
                            return (view.string as NSString).substring(with: range)
                        }
                        let result = WordReplacement.perform(plan, needsSelection: true,
                            isCurrent: { true }, selection: { view.selectedRange() }, read: read,
                            select: { view.setAccessibilitySelectedTextRange($0); return .accepted },
                            write: { view.setAccessibilitySelectedText(corrected); return .accepted },
                            awaitSelection: { view.selectedRange() == $0 },
                            awaitResult: { read(plan.resultRange) == corrected })
                        guard result == .confirmed, view.string == prefix + corrected + suffix else {
                            fputs("NSTextView replacement failed: \(original), result \(result)\n", stderr); exit(1)
                        }
                        // Deliver normal text input after the atomic edit. This
                        // catches a stale selection deleting the last letter.
                        view.insertText(" ", replacementRange: view.selectedRange())
                        view.insertText("далее", replacementRange: view.selectedRange())
                        guard view.string == prefix + corrected + " далее" + suffix else {
                            fputs("NSTextView following input damaged the correction\n", stderr); exit(1)
                        }
                        count += 1
                    }
                }
            }
        }
        for fault in ["budget-after-selection", "write-rejected", "restore-rejected"] {
            let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 150))
            view.string = "prefix lkz"
            let initial = NSRange(location: 10, length: 0)
            view.setSelectedRange(initial)
            let plan = WordReplacementPlan(original: "lkz", replacement: "для", selection: initial,
                beforeCaret: view.string, afterCaret: "")!
            var budget = true
            var writes = 0
            func read(_ range: NSRange) -> String? {
                guard NSMaxRange(range) <= view.string.utf16.count else { return nil }
                return (view.string as NSString).substring(with: range)
            }
            let result = WordReplacement.perform(plan, needsSelection: true,
                isCurrent: { true }, selection: { view.selectedRange() }, read: read,
                select: { range in
                    if fault == "restore-rejected" && range == initial { return .rejected }
                    view.setAccessibilitySelectedTextRange(range); return .accepted
                }, write: { writes += 1; return .rejected },
                awaitSelection: { expected in
                    if fault != "write-rejected" { budget = false }
                    return view.selectedRange() == expected
                }, awaitResult: { false }, mayContinue: { budget },
                awaitRestoration: { view.selectedRange() == $0 })
            if fault == "restore-rejected" {
                guard result == .unsafeSelection, view.string == "prefix lkz", writes == 0 else {
                    fputs("An unsafe NSTextView selection was released as ordinary input\n", stderr); exit(1)
                }
            } else {
                guard result == .refused, view.selectedRange() == initial,
                      writes == (fault == "write-rejected" ? 1 : 0) else {
                    fputs("A refused NSTextView edit left the word selected\n", stderr); exit(1)
                }
                view.insertText(" ", replacementRange: view.selectedRange())
                guard view.string == "prefix lkz " else {
                    fputs("A boundary erased text after a refused NSTextView edit\n", stderr); exit(1)
                }
            }
            count += 1
        }
        // These are in-process setter/transaction checks. Directly setting
        // view.string and insertText does not exercise pending macOS spelling
        // corrections or the application's physical keyboard event pipeline.
        for (error, expected) in [(AXError.success, WordReplacementRequestResult.accepted),
                                  (.attributeUnsupported, .rejected), (.illegalArgument, .rejected),
                                  (.cannotComplete, .uncertain), (.failure, .uncertain)] {
            guard DirectWordReplacement.requestResult(error) == expected else {
                fputs("AX mutation error classified unsafely\n", stderr); exit(1)
            }
            count += 1
        }
        print("Passed \(count) in-process NSTextView/setter checks (not physical-input or delayed-spelling verification)")
        return count
    }

    /// Exercises the production traversal with synthetic metadata only. No AX
    /// requests, UI, events or permission grants are made by these cases.
    static func focusResolutionChecks() -> Int {
        var count = 0
        func expect(_ condition: Bool, _ message: String) {
            guard condition else { fputs("Focus resolution regression: \(message)\n", stderr); exit(1) }
            count += 1
        }
        func result(_ value: FocusResolution<Int>) -> String {
            switch value {
            case .field(let value): return "field:\(value)"
            case .opaque(let value): return "opaque:\(value)"
            case .unsafe: return "unsafe"
            case .unavailable: return "unavailable"
            case .selection: return "selection"
            }
        }
        // Chromium's native API remains absent until the application role is
        // requested. Exercise the production traversal against that lifecycle,
        // with an independent fake provider and no cross-process AX calls.
        var nativeEnabled = false
        var requests: [String] = []
        let coldBrowser = FocusResolutionTraversal.resolve(root: 0, same: ==, prepare: { _ in true },
            kind: { _ in .editable },
            focused: { _ in nativeEnabled ? .value(1) : .unavailable }, markerOwner: { _ in .missing })
        expect(result(coldBrowser) == "unavailable", "focus-first browser reproduces absent native APIs")
        let bootstrapped = FocusResolutionTraversal.resolve(root: 0, same: ==, prepare: { _ in true },
            kind: { _ in .editable },
            focused: { _ in requests.append("focus"); return nativeEnabled ? .value(1) : .unavailable },
            markerOwner: { _ in .missing }, bootstrap: { root in
                requests.append("role:\(root)"); nativeEnabled = true
            })
        expect(result(bootstrapped) == "field:1" && requests == ["role:0", "focus"],
            "application role enables native focus before the first field request")
        let otherFramework = FocusResolutionTraversal.resolve(root: 0, same: ==, prepare: { _ in true },
            kind: { _ in .editable }, focused: { _ in .value(1) }, markerOwner: { _ in .missing },
            bootstrap: { _ in })
        expect(result(otherFramework) == "field:1", "unsupported bootstrap cannot disable another framework")
        let protectedBrowser = FocusResolutionTraversal.resolve(root: 0, same: ==, prepare: { _ in true },
            kind: { _ in .unsafe }, focused: { _ in .value(1) }, markerOwner: { _ in .missing },
            bootstrap: { _ in })
        expect(result(protectedBrowser) == "unsafe", "bootstrap never bypasses field protection")
        var expiredBootstrap = false
        let expiredBrowser = FocusResolutionTraversal.resolve(root: 0, same: ==, prepare: { _ in false },
            kind: { _ in .editable }, focused: { _ in .value(1) }, markerOwner: { _ in .missing },
            bootstrap: { _ in expiredBootstrap = true })
        expect(result(expiredBrowser) == "unavailable" && !expiredBootstrap,
            "expired budget performs no application bootstrap")
        var budgetOpen = true
        var queriedAfterDeadline = false
        let bootstrapTimeout = FocusResolutionTraversal.resolve(root: 0, same: ==, prepare: { _ in budgetOpen },
            kind: { _ in .editable }, focused: { _ in queriedAfterDeadline = true; return .value(1) },
            markerOwner: { _ in .missing }, bootstrap: { _ in budgetOpen = false })
        expect(result(bootstrapTimeout) == "unavailable" && !queriedAfterDeadline,
            "bootstrap cannot permit a focus read after the overall deadline")
        // The first probe has no cached expectedField. A busy child's metadata
        // must not turn a known text editor into permission for blind deletion.
        var metadataReplies: [FocusFieldKind] = [.unavailable, .editable]
        for expected in ["unavailable", "field:1"] {
            let resolved = FocusResolutionTraversal.resolve(root: 0, same: ==, prepare: { _ in true },
                kind: { _ in metadataReplies.removeFirst() }, focused: { _ in .value(1) },
                markerOwner: { _ in fatalError("Busy/typed metadata must not inspect fallback markers") })
            expect(result(resolved) == expected, "transient metadata should retry and retain the typed route")
        }
        for failure in [FocusRead<Int>.unavailable, .unsafe] {
            let expected = { if case .unsafe = failure { return "unsafe" }; return "unavailable" }()
            let child = FocusResolutionTraversal.resolve(root: 0, same: ==, prepare: { _ in true },
                kind: { _ in .container }, focused: { $0 == 0 ? .value(1) : failure },
                markerOwner: { _ in fatalError("A failed focused-child request must not inspect fallback markers") })
            expect(result(child) == expected, "child transport failure must not grant opaque fallback")
            let marker = FocusResolutionTraversal.resolve(root: 0, same: ==, prepare: { _ in true },
                kind: { _ in .container }, focused: { $0 == 0 ? .value(1) : .missing },
                markerOwner: { _ in failure })
            expect(result(marker) == expected, "marker timeout/positive selection must not grant opaque fallback")
        }
        let opaque = FocusResolutionTraversal.resolve(root: 0, same: ==, prepare: { _ in true },
            kind: { _ in .container }, focused: { $0 == 0 ? .value(1) : .missing }, markerOwner: { _ in .missing })
        expect(result(opaque) == "opaque:1", "explicitly absent optional APIs preserve a pinned opaque editor")
        let selected = FocusResolutionTraversal.resolve(root: 0, same: ==, prepare: { _ in true },
            kind: { _ in .container }, focused: { $0 == 0 ? .value(1) : .missing }, markerOwner: { _ in .selection })
        expect(result(selected) == "selection", "a positive marker selection is distinct from unsupported caret APIs")
        let nested = FocusResolutionTraversal.resolve(root: 0, same: ==, prepare: { _ in true },
            kind: { $0 == 2 ? .editable : .container }, focused: { $0 == 0 ? .value(1) : .missing },
            markerOwner: { _ in .value(2) })
        expect(result(nested) == "field:2", "explicit marker owner resolves to its verified editable field")
        let staticTextOwner = FocusResolutionTraversal.resolve(root: 0, same: ==, prepare: { _ in true },
            kind: { _ in .container }, focused: { $0 == 0 ? .value(1) : .missing },
            markerOwner: { $0 == 1 ? .value(2) : .missing })
        expect(result(staticTextOwner) == "opaque:1",
            "a WebKit static-text marker owner does not replace the focused group's opaque identity")
        let explicitChildThenMarker = FocusResolutionTraversal.resolve(root: 0, same: ==, prepare: { _ in true },
            kind: { _ in .container }, focused: { $0 == 0 ? .value(1) : ($0 == 1 ? .value(2) : .missing) },
            markerOwner: { $0 == 2 ? .value(3) : .missing })
        expect(result(explicitChildThenMarker) == "opaque:2",
            "the last explicit focused child is pinned before following a marker owner")
        let busyStaticOwner = FocusResolutionTraversal.resolve(root: 0, same: ==, prepare: { _ in true },
            kind: { $0 == 2 ? .unavailable : .container }, focused: { $0 == 0 ? .value(1) : .missing },
            markerOwner: { $0 == 1 ? .value(2) : .missing })
        expect(result(busyStaticOwner) == "unavailable",
            "preserving the focus anchor never turns a marker-owner timeout into opaque permission")
        let protectedOwner = FocusResolutionTraversal.resolve(root: 0, same: ==, prepare: { _ in true },
            kind: { $0 == 2 ? .unsafe : .container }, focused: { $0 == 0 ? .value(1) : .missing },
            markerOwner: { _ in .value(2) })
        expect(result(protectedOwner) == "unsafe", "a protected marker owner cannot be bypassed")
        let cycle = FocusResolutionTraversal.resolve(root: 0, same: ==, prepare: { _ in true },
            kind: { _ in .container }, focused: { .value($0 == 1 ? 2 : 1) },
            markerOwner: { _ in fatalError("Focus cycles never reach marker discovery") })
        expect(result(cycle) == "unavailable", "a focus cycle never becomes permission to edit")
        var remaining = 1
        let expired = FocusResolutionTraversal.resolve(root: 0, same: ==,
            prepare: { _ in defer { remaining -= 1 }; return remaining > 0 }, kind: { _ in .editable },
            focused: { _ in .value(1) }, markerOwner: { _ in .missing })
        expect(result(expired) == "unavailable", "expired focus budget cannot return an editable field")
        func axError(_ error: AXError) -> AXValue { var value = error; return AXValueCreate(.axError, &value)! }
        func safety(_ items: [Any]) -> String {
            switch FocusSafetyMetadata.decode(items) {
            case .allowed: return "allowed"
            case .unsafe: return "unsafe"
            case .unavailable: return "unavailable"
            }
        }
        let absent = axError(.attributeUnsupported)
        for role in [kAXTextFieldRole, kAXTextAreaRole, kAXGroupRole, kAXWindowRole] {
            expect(safety([role, absent, absent, true]) == "allowed", "ordinary optional metadata remains supported")
            for index in 1...3 {
                var fields: [Any] = [role, absent, false, true]
                fields[index] = axError(.cannotComplete)
                expect(safety(fields) == "unavailable", "an embedded safety timeout must not cast to absent")
                fields[index] = "malformed"
                if index == 1 { fields[index] = NSNumber(value: 7) }
                expect(safety(fields) == "unavailable", "wrong safety attribute types fail closed")
            }
        }
        expect(safety([kAXTextFieldRole, "AXSecureTextField", absent, true]) == "unsafe", "secure subroles remain excluded")
        expect(safety([kAXTextFieldRole, absent, true, true]) == "unsafe", "protected fields remain excluded")
        expect(safety([kAXTextFieldRole, absent, false, false]) == "unsafe", "disabled fields remain excluded")
        expect(safety([kAXTextFieldRole, axError(.apiDisabled), false, true]) == "unsafe", "revoked Accessibility access remains excluded")
        expect(safety([absent, absent, absent, absent]) == "unavailable", "a missing role cannot establish editable safety")
        expect(safety([kAXTextFieldRole, absent, NSNumber(value: 2), true]) == "unavailable", "numeric flags are not CFBooleans")
        // The known-TextField opaque route must still honor markers when its
        // numeric AXSelectedTextRange API is unsupported. These local opaque
        // CF values have no owner/editor and never cause an Accessibility read.
        func marker(_ byte: UInt8) -> AXTextMarker {
            var value = byte
            return AXTextMarkerCreate(kCFAllocatorDefault, &value, 1)
        }
        let first = marker(1), samePosition = marker(1), last = marker(2)
        let collapsed = AXTextMarkerRangeCreate(kCFAllocatorDefault, first, samePosition)
        let nonempty = AXTextMarkerRangeCreate(kCFAllocatorDefault, first, last)
        expect(DirectWordReplacement.markerSelectionReply(error: .success, value: collapsed) == .collapsed,
            "known field may use an explicitly collapsed marker selection")
        expect(DirectWordReplacement.markerSelectionReply(error: .success, value: nonempty) == .selected,
            "known field must reject a positive marker selection even without numeric ranges")
        for error in [AXError.attributeUnsupported, .notImplemented, .noValue] {
            expect(DirectWordReplacement.markerSelectionReply(error: error, value: nil) == .absent,
                "an explicitly absent marker API preserves ordinary opaque compatibility")
        }
        for error in [AXError.cannotComplete, .failure] {
            expect(DirectWordReplacement.markerSelectionReply(error: error, value: nil) == .unavailable,
                "marker transport failure requires a bounded retry, never fallback")
        }
        for error in [AXError.apiDisabled, .invalidUIElement] {
            expect(DirectWordReplacement.markerSelectionReply(error: error, value: nil) == .unsafe,
                "revoked or invalid marker access forbids a replacement")
        }
        expect(DirectWordReplacement.markerSelectionReply(error: .success, value: nil) == .unavailable,
            "a successful but empty marker reply is not a supported absence")
        expect(DirectWordReplacement.markerSelectionReply(error: .success, value: "malformed" as CFString) == .unavailable,
            "a malformed marker type cannot permit keyboard replacement")
        return count
    }
}
