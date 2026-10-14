import AppKit

// Windowless AppKit experiment, not global input. Only explicit test strings
// enter these views. No NSWindow, AX, activation, CGEvent posting, input-source
// selection, clipboard or other application is used.
private final class ObservedTextView: NSTextView {
    var insertions: [String] = []
    override func insertText(_ value: Any, replacementRange: NSRange) {
        insertions.append((value as? NSAttributedString)?.string ?? (value as? String ?? ""))
        super.insertText(value, replacementRange: replacementRange)
    }
}

@main enum NativeSpaceAutorepeatChecks {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments["NSAutomaticPeriodSubstitutionEnabled"] = false
        arguments["NSAutomaticCapitalizationEnabled"] = false
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        let sequences: [(String, String, [(Bool, Bool)])] = [
            ("one-held-space", "lkz", [(true, false), (true, true), (false, false)]),
            ("balanced-space-then-repeat", "для", [(true, false), (false, false), (true, true), (false, false)]),
            ("two-separate-spaces", "для", [(true, false), (false, false), (true, false), (false, false)])
        ]
        var results: [[String: Any]] = []
        for rich in [false, true] {
            for (name, prefix, sequence) in sequences {
                let view = ObservedTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 120))
                view.isRichText = rich
                view.isAutomaticSpellingCorrectionEnabled = false
                view.isContinuousSpellCheckingEnabled = false
                view.isAutomaticTextReplacementEnabled = false
                view.isAutomaticTextCompletionEnabled = false
                view.string = prefix
                view.setSelectedRange(NSRange(location: prefix.utf16.count, length: 0))
                var delivered: [[String: Any]] = []
                for (down, repeated) in sequence {
                    guard let event = NSEvent.keyEvent(with: down ? .keyDown : .keyUp,
                        location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: 0, context: nil, characters: " ", charactersIgnoringModifiers: " ",
                        isARepeat: repeated, keyCode: 49) else { fatalError("Could not construct local Space event") }
                    delivered.append(["type": down ? "keyDown" : "keyUp", "isARepeat": repeated])
                    if down { view.keyDown(with: event) } else { view.keyUp(with: event) }
                }
                let expected = prefix + "  "
                let selection = view.selectedRange()
                let passed = view.string == expected && selection == NSRange(location: expected.utf16.count, length: 0) &&
                    view.insertions == [" ", " "] && view.window == nil
                results.append(["case": name, "rich": rich, "expected": expected, "actual": view.string,
                    "selection": ["location": selection.location, "length": selection.length],
                    "insertions": view.insertions, "deliveredMethodCalls": delivered, "windowAttached": view.window != nil,
                    "passed": passed])
            }
        }
        let passed = results.filter { $0["passed"] as? Bool == true }.count
        let report: [String: Any] = ["passed": passed, "planned": results.count, "failed": results.count - passed,
            "scope": "Windowless NSTextView.keyDown/keyUp called directly with self-created NSEvents",
            "limitations": "Does not execute AutoMonitor, CGEvent taps, process delivery, Qt/MAX, Telegram or hardware repeat timing",
            "eventsPosted": 0, "windowsCreated": 0, "sourceChanges": 0, "otherAppAccess": false, "results": results]
        let data = try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        exit(passed == results.count ? 0 : 1)
    }
}
