import AppKit
import WebKit
import LocalSafety

// Owned, disposable editors for an external test runner. No event synthesis,
// clipboard, other-app AX access, document loading, or network requests.
private final class Counts {
    private struct Origin: Hashable { let tag: Int64; let sourcePID: Int64 }
    private var observedOrigins = Set<Origin>()
    private var originsOverflowed = false
    var keyDown = 0, keyDownCompleted = 0, keyUp = 0, insertText = 0, textChanges = 0, enter = 0, tab = 0
    var repeatKeyDown = 0
    var lastKeyDownCompletedAt: TimeInterval = 0
    var editorCapitalizations = 0
    var keys: [Int] = []
    var eventLog: [[String: Any]] = []
    func observeOrigin(_ event: NSEvent) {
        let origin = Origin(tag: event.cgEvent?.getIntegerValueField(.eventSourceUserData) ?? 0,
                            sourcePID: event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) ?? -1)
        guard !observedOrigins.contains(origin) else { return }
        guard observedOrigins.count < 8 else { originsOverflowed = true; return }
        observedOrigins.insert(origin)
    }
    func record(_ event: [String: Any]) {
        guard eventLog.count < 2048 else { return }
        var event = event
        event["processingTime"] = ProcessInfo.processInfo.systemUptime
        eventLog.append(event)
    }
    func reset() {
        keyDown = 0; keyDownCompleted = 0; lastKeyDownCompletedAt = 0
        repeatKeyDown = 0
        editorCapitalizations = 0
        keyUp = 0; insertText = 0; textChanges = 0; enter = 0; tab = 0; keys = []; eventLog = []
        observedOrigins.removeAll(keepingCapacity: true); originsOverflowed = false
    }
    var json: [String: Any] {
        ["keyDown": keyDown, "keyDownCompleted": keyDownCompleted,
         "lastKeyDownCompletedAt": lastKeyDownCompletedAt, "keyUp": keyUp, "repeatKeyDown": repeatKeyDown, "insertText": insertText,
         "editorCapitalizations": editorCapitalizations,
         "textChanges": textChanges, "keyCodes": keys, "eventLog": eventLog, "enter": enter, "tab": tab,
         "observedOrigins": observedOrigins.sorted { $0.tag == $1.tag ? $0.sourcePID < $1.sourcePID : $0.tag < $1.tag }
            .map { ["tag": $0.tag, "sourcePID": $0.sourcePID] },
         "originsOverflowed": originsOverflowed]
    }
}

private final class FixtureApplication: NSApplication {
    let counts = Counts()
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            // This summary is independent of the bounded diagnostic event log.
            counts.observeOrigin(event)
            counts.keyDown += 1
            if event.isARepeat { counts.repeatKeyDown += 1 }
            if event.keyCode == 36 || event.keyCode == 76 { counts.enter += 1 }
            if event.keyCode == 48 { counts.tab += 1 }
            if counts.keys.count < 4096 { counts.keys.append(Int(event.keyCode)) }
            counts.record(["type": "keyDown", "code": Int(event.keyCode), "characters": event.characters ?? "",
                           "isARepeat": event.isARepeat,
                           "autorepeat": event.cgEvent?.getIntegerValueField(.keyboardEventAutorepeat) ?? -1,
                           "flags": event.modifierFlags.rawValue, "timestamp": event.timestamp,
                           "timestampNS": event.cgEvent?.timestamp ?? 0,
                           "inputSourceID": NSTextInputContext.current?.selectedKeyboardInputSource ?? "",
                           "sourcePID": event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) ?? -1,
                           "tag": event.cgEvent?.getIntegerValueField(.eventSourceUserData) ?? 0])
        } else if event.type == .keyUp {
            counts.keyUp += 1
            counts.record(["type": "keyUp", "code": Int(event.keyCode), "timestamp": event.timestamp,
                           "autorepeat": event.cgEvent?.getIntegerValueField(.keyboardEventAutorepeat) ?? -1,
                           "flags": event.modifierFlags.rawValue,
                           "timestampNS": event.cgEvent?.timestamp ?? 0,
                           "sourcePID": event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) ?? -1,
                           "tag": event.cgEvent?.getIntegerValueField(.eventSourceUserData) ?? 0])
        }
        super.sendEvent(event)
        if event.type == .keyDown {
            counts.keyDownCompleted += 1
            counts.lastKeyDownCompletedAt = ProcessInfo.processInfo.systemUptime
            counts.record(["type": "keyDownCompleted", "code": Int(event.keyCode),
                           "timestampNS": event.cgEvent?.timestamp ?? 0,
                           "tag": event.cgEvent?.getIntegerValueField(.eventSourceUserData) ?? 0])
        }
    }
}

private class CountingTextView: NSTextView {
    var counts: Counts?
    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        counts?.insertText += 1
        let text = (insertString as? NSAttributedString)?.string ?? (insertString as? String) ?? ""
        counts?.record(["type": "insertText", "text": String(text.prefix(128)),
                        "inputSourceID": inputContext?.selectedKeyboardInputSource ?? "",
                        "selection": [selectedRange().location, selectedRange().length]])
        super.insertText(insertString, replacementRange: replacementRange)
    }
    override func didChangeText() {
        counts?.textChanges += 1
        super.didChangeText()
    }
}

/// An editor-side mutation that is deterministic regardless of the system's
/// language model, spelling preferences, and asynchronous capitalization UI.
/// Apply once to the original first keystroke only: capitalizing a later
/// replacement as well would hide a production failure to preserve the case.
private final class CapitalizingTextView: CountingTextView {
    private var transformedFirstLetter = false
    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        let text = (insertString as? NSAttributedString)?.string ?? (insertString as? String) ?? ""
        let uppercase = text.uppercased()
        guard !transformedFirstLetter, string.isEmpty, selectedRange() == NSRange(location: 0, length: 0),
              text.count == 1, text.first?.isLowercase == true, uppercase != text,
              uppercase.utf16.count == text.utf16.count else {
            super.insertText(insertString, replacementRange: replacementRange)
            return
        }
        transformedFirstLetter = true
        counts?.editorCapitalizations += 1
        counts?.record(["type": "editorCapitalization", "original": text, "inserted": uppercase])
        let transformed: Any
        if let attributed = insertString as? NSAttributedString {
            transformed = NSAttributedString(string: uppercase, attributes: attributed.attributes(at: 0, effectiveRange: nil))
        } else { transformed = uppercase }
        super.insertText(transformed, replacementRange: replacementRange)
    }
}

/// Makes an AX read stale deterministically, in this disposable app only.
/// The returned string still belongs to A; focus already belongs to B.
private final class FocusRaceTextView: CountingTextView {
    var afterRangeRead: (() -> Void)?
    private func didRead(_ value: String?) {
        guard let value, value == "lkz", selectedRange() == NSRange(location: 3, length: 0),
              let action = afterRangeRead else { return }
        afterRangeRead = nil
        action()
    }
    override func accessibilityString(for range: NSRange) -> String? {
        let result = super.accessibilityString(for: range)
        didRead(result)
        return result
    }
    override func accessibilityAttributeValue(_ attribute: NSAccessibility.ParameterizedAttribute, forParameter parameter: Any?) -> Any? {
        let result = super.accessibilityAttributeValue(attribute, forParameter: parameter)
        if attribute.rawValue == "AXStringForRange" { didRead(result as? String) }
        return result
    }
}

// Deliberately opaque accessibility transport, while retaining real NSTextView
// keyboard handling. The runner must assert that keyboard fallback was used.
private class OpaqueTextView: CountingTextView {
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityAttributeNames() -> [NSAccessibility.Attribute] {
        super.accessibilityAttributeNames().filter {
            !$0.rawValue.contains("Text") && $0 != .value && $0.rawValue != "AXEditableAncestor"
        }
    }
    override func accessibilityAttributeValue(_ attribute: NSAccessibility.Attribute) -> Any? {
        if attribute.rawValue.contains("Text") || attribute == .value || attribute.rawValue == "AXEditableAncestor" { return nil }
        return super.accessibilityAttributeValue(attribute)
    }
    override func accessibilityParameterizedAttributeNames() -> [NSAccessibility.ParameterizedAttribute] { [] }
    override func accessibilityAttributeValue(_ attribute: NSAccessibility.ParameterizedAttribute, forParameter parameter: Any?) -> Any? { nil }
    override func accessibilityIsAttributeSettable(_ attribute: NSAccessibility.Attribute) -> Bool { false }
    override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool {
        let name = NSStringFromSelector(selector)
        if name.localizedCaseInsensitiveContains("text") || name.localizedCaseInsensitiveContains("value") { return false }
        return super.isAccessibilitySelectorAllowed(selector)
    }
}

/// Return an unsupported marker range from A after focus has moved to B.
/// Unlike FocusRaceTextView, A remains an opaque group, with no editable
/// ancestor or readable range. This exercises the raw-focus identity guard.
private final class OpaqueFocusRaceTextView: OpaqueTextView {
    var afterMarkerRead: (() -> Void)?
    private func unsupportedMarkerRange() -> Any? {
        counts?.record(["type": "opaqueMarkerRead", "sourceReady": string == "lkz"])
        if string == "lkz", selectedRange() == NSRange(location: 3, length: 0), let action = afterMarkerRead {
            afterMarkerRead = nil
            counts?.record(["type": "opaqueFocusRace", "attribute": "AXSelectedTextMarkerRange"])
            action()
        }
        return nil
    }
    // AppKit may route the attribute through its selector bridge before the
    // legacy getter. Both paths deliberately return no marker capability.
    @objc func accessibilitySelectedTextMarkerRange() -> Any? { unsupportedMarkerRange() }
    override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool {
        if NSStringFromSelector(selector) == "accessibilitySelectedTextMarkerRange" { return true }
        return super.isAccessibilitySelectorAllowed(selector)
    }
    override func accessibilityAttributeNames() -> [NSAccessibility.Attribute] {
        super.accessibilityAttributeNames() + [NSAccessibility.Attribute(rawValue: "AXSelectedTextMarkerRange")]
    }
    override func accessibilityAttributeValue(_ attribute: NSAccessibility.Attribute) -> Any? {
        if attribute.rawValue == "AXSelectedTextMarkerRange" {
            return unsupportedMarkerRange()
        }
        return super.accessibilityAttributeValue(attribute)
    }
}

private final class FixtureDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, WKNavigationDelegate {
    private var window: NSWindow!
    private var textView: CountingTextView?
    private var field: NSTextField?
    private var fieldEditor: CountingTextView?
    private var web: WKWebView?
    private var raceTarget: CountingTextView?
    private var raceSecureTarget: NSSecureTextField?
    private var raceHookCount = 0
    private var mode = "plain"
    private var pendingWebReset: [String: Any]?
    private var generation = 0
    private var requestedInitialActivation = false
    private var startupParentVerified: Bool?
    private var startupActivationAllowed: Bool?
    private var app: FixtureApplication { NSApplication.shared as! FixtureApplication }
    private let modes = ["plain", "rich", "plain-autocorrect", "rich-autocorrect", "field", "opaque",
                         "web-textarea", "web-input", "web-contenteditable", "web-group", "web-rich"]

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 440),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Trump Switcher — изолированный тест ввода"
        window.delegate = self
        window.center()
        reset(["mode": "plain", "text": ""], response: "ready")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            while let line = readLine() {
                guard let data = line.data(using: .utf8) else { continue }
                DispatchQueue.main.async { self?.command(data) }
            }
            DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
        }
    }

    private func emit(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([10]))
    }
    private func respond(_ request: [String: Any], event: String, values: [String: Any] = [:]) {
        var result = values
        result["event"] = event; result["pid"] = ProcessInfo.processInfo.processIdentifier
        result["active"] = app.isActive
        result["keyWindow"] = window?.isKeyWindow ?? false
        if let startupParentVerified { result["parentVerified"] = startupParentVerified }
        if let startupActivationAllowed { result["activationAllowed"] = startupActivationAllowed }
        result["automaticCapitalizationEnabled"] = NSSpellChecker.isAutomaticCapitalizationEnabled
        result["automaticPeriodSubstitutionEnabled"] = NSSpellChecker.isAutomaticPeriodSubstitutionEnabled
        var traits: [String: Any] = ["globalAutomaticTextCompletionEnabled": NSSpellChecker.isAutomaticTextCompletionEnabled]
        let activeEditor: NSTextView? = textView ?? (field?.currentEditor() as? NSTextView)
        if let field {
            traits["fieldAutomaticTextCompletionEnabled"] = field.isAutomaticTextCompletionEnabled
            traits["usesOwnedFieldEditor"] = field.currentEditor() === fieldEditor
        }
        if let activeEditor {
            traits["editorAutomaticTextCompletionEnabled"] = activeEditor.isAutomaticTextCompletionEnabled
            traits["editorSpellingCorrectionEnabled"] = activeEditor.isAutomaticSpellingCorrectionEnabled
            if #available(macOS 14.0, *) { traits["editorInlinePredictionType"] = activeEditor.inlinePredictionType.rawValue }
        }
        if #available(macOS 14.0, *) { traits["globalAutomaticInlinePredictionEnabled"] = NSSpellChecker.isAutomaticInlinePredictionEnabled }
        result["inputTraits"] = traits
        if mode == "editor-capitalization" { result["simulatedEditorBehavior"] = "Capitalize only the first original lowercase letter, once per reset" }
        if let id = request["id"] { result["id"] = id }
        emit(result)
    }
    private func command(_ data: Data) {
        guard let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            emit(["event": "error", "error": "Expected a JSON object"]); return
        }
        switch request["command"] as? String ?? request["cmd"] as? String {
        case "reset": reset(request)
        case "snapshot": snapshot(request, event: "snapshot")
        case "arm-focus-race":
            guard textView is FocusRaceTextView || textView is OpaqueFocusRaceTextView,
                  raceTarget != nil || raceSecureTarget != nil else {
                respond(request, event: "error", values: ["error": "Focus race requires a pair of owned fields"]); return
            }
            let moveToSecondField: () -> Void = { [weak self] in
                guard let self else { return }
                self.raceHookCount += 1
                if let target = self.raceTarget {
                    self.window.makeFirstResponder(target)
                    target.setSelectedRange(NSRange(location: target.string.utf16.count, length: 0))
                } else if let target = self.raceSecureTarget {
                    self.window.makeFirstResponder(target)
                    (target.currentEditor() as? NSTextView)?.setSelectedRange(NSRange(location: target.stringValue.utf16.count, length: 0))
                }
            }
            (textView as? FocusRaceTextView)?.afterRangeRead = moveToSecondField
            (textView as? OpaqueFocusRaceTextView)?.afterMarkerRead = moveToSecondField
            respond(request, event: "armed")
        case "quit": respond(request, event: "quit"); app.terminate(nil)
        default: respond(request, event: "error", values: ["error": "Unknown command"])
        }
    }
    private func requestedSelection(_ request: [String: Any], text: String) -> NSRange? {
        let length = text.utf16.count
        guard let raw = request["selection"] else { return NSRange(location: length, length: 0) }
        let location: Int?, selected: Int?
        if let values = raw as? [Int], values.count == 2 { location = values[0]; selected = values[1] }
        else if let values = raw as? [String: Int] { location = values["location"]; selected = values["length"] }
        else { return nil }
        guard let location, let selected, location >= 0, selected >= 0,
              location <= length, selected <= length - location else { return nil }
        return NSRange(location: location, length: selected)
    }

    private func activateOwnedWindow() {
        window.makeKeyAndOrderFront(nil)
        guard !requestedInitialActivation else { return }
        requestedInitialActivation = true
        if #available(macOS 14.0, *) {
            // Transfer only from the verified parent that yielded to us. Do
            // this once at launch; subsequent resets never reacquire activation.
            if let parent = NSRunningApplication(processIdentifier: getppid()), parent.bundleIdentifier == "local.trumpswitcher.mac" {
                startupParentVerified = true
                startupActivationAllowed = NSRunningApplication.current.activate(from: parent, options: [])
            } else {
                startupParentVerified = false
                startupActivationAllowed = false
            }
        } else {
            app.activate(ignoringOtherApps: true)
        }
    }

    /// App activation is asynchronous. A ready response is a foreground/key
    /// window handshake, never merely evidence that activate() was requested.
    /// Do not repeatedly steal focus if the user changes applications.
    private func finishReset(_ request: [String: Any], event: String) {
        let expectedGeneration = generation
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        func check() {
            guard self.generation == expectedGeneration else {
                self.respond(request, event: "error", values: ["error": "Reset superseded while awaiting activation"])
                return
            }
            let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
            if frontmost && self.app.isActive && self.window.isKeyWindow {
                self.snapshot(request, event: event)
                return
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                self.respond(request, event: "error", values: [
                    "error": "Owned fixture did not become frontmost with a key window within 2 seconds",
                    "frontmost": frontmost, "active": self.app.isActive, "keyWindow": self.window.isKeyWindow])
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: check)
        }
        DispatchQueue.main.async(execute: check)
    }
    private func reset(_ request: [String: Any], response: String = "reset") {
        guard let newMode = request["mode"] as? String, (modes + ["focus-race", "focus-race-protected", "focus-race-opaque", "editor-capitalization"]).contains(newMode),
              let text = request["text"] as? String, text.utf16.count <= 16384,
              let selection = requestedSelection(request, text: text) else {
            respond(request, event: "error", values: ["error": "Invalid mode, text, or UTF-16 selection", "modes": modes]); return
        }
        if let pending = pendingWebReset {
            respond(pending, event: "error", values: ["error": "Reset superseded"])
        }
        generation += 1; pendingWebReset = nil
        web?.navigationDelegate = nil; web?.stopLoading()
        window.makeFirstResponder(nil)
        window.contentView?.subviews.forEach { $0.removeFromSuperview() }
        textView = nil; field = nil; fieldEditor = nil; web = nil; mode = newMode
        raceTarget = nil; raceSecureTarget = nil; raceHookCount = 0
        window.title = "Trump Switcher — изолированный тест: \(mode)"
        let frame = NSRect(x: 20, y: 20, width: 720, height: 390)
        activateOwnedWindow()
        if mode.hasPrefix("focus-race") {
            let source: CountingTextView = mode == "focus-race-opaque" ?
                OpaqueFocusRaceTextView(frame: frame) : FocusRaceTextView(frame: frame)
            source.counts = app.counts; source.isRichText = false
            source.isAutomaticSpellingCorrectionEnabled = false
            source.isAutomaticTextReplacementEnabled = false
            source.isAutomaticTextCompletionEnabled = false
            source.string = text
            source.setAccessibilityIdentifier("same-owned-race-field")
            if mode == "focus-race-protected" {
                let target = NSSecureTextField(frame: frame)
                target.stringValue = "SENTINEL"
                window.contentView?.addSubview(target); raceSecureTarget = target
            } else {
                // Equal geometry and identifiers deliberately defeat geometry-
                // based identity shortcuts. These are distinct AX elements.
                let target = CountingTextView(frame: frame)
                target.counts = app.counts; target.isRichText = false
                target.isAutomaticSpellingCorrectionEnabled = false
                target.isAutomaticTextReplacementEnabled = false
                target.isAutomaticTextCompletionEnabled = false
                target.string = "SENTINEL"
                target.setAccessibilityIdentifier("same-owned-race-field")
                window.contentView?.addSubview(target); raceTarget = target
            }
            window.contentView?.addSubview(source); textView = source
            window.makeFirstResponder(source); source.setSelectedRange(selection)
            app.counts.reset(); finishReset(request, event: response)
            return
        }
        if mode.hasPrefix("web-") {
            var pending = request; pending["responseEvent"] = response
            pending["selection"] = [selection.location, selection.length]
            pendingWebReset = pending
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let view = WKWebView(frame: frame, configuration: configuration)
            view.navigationDelegate = self
            window.contentView?.addSubview(view); web = view
            view.loadHTMLString(Self.html, baseURL: nil)
            return
        }
        if mode == "field" {
            let editor = CountingTextView(frame: frame)
            editor.counts = app.counts; editor.isFieldEditor = true
            editor.isAutomaticSpellingCorrectionEnabled = false
            editor.isAutomaticTextReplacementEnabled = false
            editor.isAutomaticTextCompletionEnabled = false
            fieldEditor = editor
            let control = NSTextField(frame: NSRect(x: 20, y: 310, width: 720, height: 40))
            control.font = .systemFont(ofSize: 22); control.stringValue = text
            window.contentView?.addSubview(control); field = control
            window.makeFirstResponder(control)
            (control.currentEditor() as? NSTextView)?.setSelectedRange(selection)
        } else {
            let scroll = NSScrollView(frame: frame); scroll.hasVerticalScroller = true
            let editor: CountingTextView
            if mode == "opaque" { editor = OpaqueTextView(frame: scroll.bounds) }
            else if mode == "editor-capitalization" { editor = CapitalizingTextView(frame: scroll.bounds) }
            else { editor = CountingTextView(frame: scroll.bounds) }
            editor.counts = app.counts
            editor.isRichText = mode.hasPrefix("rich")
            let spelling = mode.hasSuffix("-autocorrect")
            editor.isContinuousSpellCheckingEnabled = spelling
            editor.isAutomaticSpellingCorrectionEnabled = spelling
            editor.isAutomaticTextReplacementEnabled = spelling
            editor.isAutomaticQuoteSubstitutionEnabled = spelling
            editor.isAutomaticDashSubstitutionEnabled = spelling
            editor.isAutomaticTextCompletionEnabled = false
            editor.font = .systemFont(ofSize: 22)
            editor.isVerticallyResizable = true
            editor.textContainer?.widthTracksTextView = true
            editor.autoresizingMask = [.width]
            editor.string = text
            scroll.documentView = editor
            window.contentView?.addSubview(scroll); textView = editor
            window.makeFirstResponder(editor); editor.setSelectedRange(selection)
        }
        app.counts.reset()
        finishReset(request, event: response)
    }

    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        if let control = client as? NSTextField, control === field { return fieldEditor }
        return nil
    }
    private func snapshot(_ request: [String: Any], event: String) {
        let thisGeneration = generation
        let snapshotTime = ProcessInfo.processInfo.systemUptime
        if mode.hasPrefix("focus-race") {
            let targetText = raceTarget?.string ?? raceSecureTarget?.stringValue ?? ""
            let targetEditor = (raceTarget as NSTextView?) ?? (raceSecureTarget?.currentEditor() as? NSTextView)
            let active = window.firstResponder === textView ? "A" :
                (targetEditor != nil && window.firstResponder === targetEditor ? "B" : "other")
            respond(request, event: event, values: ["mode": mode, "text": textView?.string ?? "", "snapshotTime": snapshotTime,
                "activeField": active, "hookCount": raceHookCount,
                "raceTrigger": mode == "focus-race-opaque" ? "unsupported-marker-range" : "readable-word-range",
                "targetUnchanged": targetText == "SENTINEL", "targetHasOnlyBoundary": targetText == "SENTINEL ",
                "targetSelectionLength": targetEditor?.selectedRange().length ?? 0,
                "counts": app.counts.json,
                "frontmost": NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
                "modes": modes])
            return
        }
        if let web {
            guard pendingWebReset == nil else {
                respond(request, event: "error", values: ["error": "Web reset not ready"]); return
            }
            web.evaluateJavaScript("fixtureSnapshot()") { [weak self] value, error in
                guard let self else { return }
                guard self.generation == thisGeneration else {
                    self.respond(request, event: "error", values: ["error": "Snapshot superseded"]); return
                }
                guard var result = value as? [String: Any], error == nil else {
                    self.respond(request, event: "error", values: ["error": error?.localizedDescription ?? "Missing web result"]); return
                }
                result["counts"] = self.app.counts.json
                result["snapshotTime"] = ProcessInfo.processInfo.systemUptime
                result["mode"] = self.mode; result["selectionUnit"] = "UTF16"
                result["frontmost"] = NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
                result["modes"] = self.modes
                self.respond(request, event: event, values: result)
            }
            return
        }
        let editor = textView ?? (field?.currentEditor() as? CountingTextView)
        let text = editor?.string ?? field?.stringValue ?? ""
        let range = editor?.selectedRange() ?? NSRange(location: text.utf16.count, length: 0)
        respond(request, event: event, values: ["mode": mode, "text": text, "snapshotTime": snapshotTime,
            "caret": range.location, "selection": ["location": range.location, "length": range.length],
            "selectionUnit": "UTF16", "counts": app.counts.json,
            "focused": editor != nil && window.firstResponder === editor,
            "frontmost": NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
            "modes": modes])
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // loadHTMLString uses about:blank. No external/file/document navigation.
        decisionHandler(navigationAction.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let request = pendingWebReset, webView === web else { return }
        let thisGeneration = generation
        let configuration: [String: Any] = ["mode": mode, "text": request["text"] ?? "",
                                            "selection": request["selection"] ?? [0, 0]]
        guard let data = try? JSONSerialization.data(withJSONObject: configuration),
              let argument = String(data: data, encoding: .utf8) else { return }
        window.makeFirstResponder(webView)
        webView.evaluateJavaScript("fixtureReset(\(argument))") { [weak self] _, error in
            guard let self, self.generation == thisGeneration else { return }
            self.pendingWebReset = nil
            guard error == nil else {
                self.respond(request, event: "error", values: ["error": error!.localizedDescription]); return
            }
            self.app.counts.reset()
            self.finishReset(request, event: request["responseEvent"] as? String ?? "reset")
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { webFailed(webView, error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { webFailed(webView, error) }
    private func webFailed(_ view: WKWebView, _ error: Error) {
        guard view === web, let request = pendingWebReset else { return }
        pendingWebReset = nil
        respond(request, event: "error", values: ["error": error.localizedDescription])
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private static let html = #"""
    <!doctype html><meta charset="utf-8">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'none'; img-src 'none'; frame-src 'none'; form-action 'none'">
    <style>body{font:22px system-ui;background:#f7f7f7;color:#111;margin:12px}input,textarea,[contenteditable]{box-sizing:border-box;width:100%;min-height:250px;border:1px solid #888;padding:12px;font:inherit;white-space:pre-wrap}</style>
    <div id="host"></div>
    <script>
    let target, mode, events, initialText;
    function textOf(){return target.matches('input,textarea') ? target.value : target.textContent;}
    function fixtureReset(config){
      mode=config.mode; initialText=config.text; events={keyDown:0,keyUp:0,insertText:0,beforeInput:0,input:0,enter:0,tab:0};
      const tag=mode==='web-input'?'input':mode==='web-textarea'?'textarea':'div';
      target=document.createElement(tag); target.id='fixture-editor';
      target.setAttribute('aria-label','Owned test editor'); target.spellcheck=false;
      target.setAttribute('autocorrect','off'); target.setAttribute('autocomplete','off');
      if(tag==='div'){target.contentEditable='true';if(mode==='web-group')target.setAttribute('role','group');}
      document.getElementById('host').replaceChildren(target);
      if(tag==='div'){
        if(mode==='web-rich'){const b=document.createElement('b');b.textContent=config.text;target.appendChild(b);}
        else target.textContent=config.text;
      } else target.value=config.text;
      target.addEventListener('keydown',e=>{events.keyDown++;if(e.key==='Enter')events.enter++;if(e.key==='Tab')events.tab++;});
      target.addEventListener('keyup',()=>events.keyUp++);
      target.addEventListener('beforeinput',e=>{events.beforeInput++;if(e.inputType==='insertText')events.insertText++;});
      target.addEventListener('input',()=>events.input++);
      target.focus(); const [start,length]=config.selection;
      if(tag!=='div')target.setSelectionRange(start,start+length);
      else {
        const walker=document.createTreeWalker(target,NodeFilter.SHOW_TEXT);let nodes=[],node;
        while(node=walker.nextNode())nodes.push(node);
        if(!nodes.length){node=document.createTextNode('');target.appendChild(node);nodes=[node];}
        function endpoint(offset){for(const n of nodes){if(offset<=n.length)return [n,offset];offset-=n.length;}return [nodes[nodes.length-1],nodes[nodes.length-1].length];}
        const a=endpoint(start),b=endpoint(start+length),range=document.createRange();
        range.setStart(a[0],a[1]);range.setEnd(b[0],b[1]);const selection=getSelection();selection.removeAllRanges();selection.addRange(range);
      }
      return true;
    }
    function fixtureSnapshot(){
      let start=null,length=null,selectionWithinTarget=false,selectionState='absent';
      if(target.matches('input,textarea')){
        start=target.selectionStart;length=target.selectionEnd-start;
        selectionWithinTarget=true;selectionState='control-local';
      }
      else {
        const selection=getSelection();
        if(selection.rangeCount){
          const range=selection.getRangeAt(0);
          selectionWithinTarget=target.contains(range.startContainer)&&target.contains(range.endContainer);
          selectionState=selectionWithinTarget?'inside-target':'outside-target';
          if(selectionWithinTarget){
            const prefix=range.cloneRange();prefix.selectNodeContents(target);
            prefix.setEnd(range.startContainer,range.startOffset);
            start=prefix.toString().length;length=range.toString().length;
          }
        }
      }
      return {text:textOf(),renderedText:target.matches('input,textarea')?target.value:target.innerText,
        ownedHTML:target.innerHTML,
        formattedPrefixPreserved:mode==='web-rich'&&initialText.length>0?
          Array.from(target.querySelectorAll('b')).some(node=>node.textContent.startsWith(initialText)):null,
        caret:start,selection:selectionWithinTarget?{location:start,length}:null,
        selectionWithinTarget,selectionState,focused:document.activeElement===target,domCounts:events};
    }
    </script>
    """#
}

guard trump_deny_internet() == 0, trump_network_is_denied() == 1 else {
    fputs("InputFixture refused to start without OS network restriction\n", stderr)
    exit(1)
}
// Test determinism, in this process's volatile defaults only. Never write the
// user's application/global preferences; spelling modes remain independently
// configured on each owned editor above.
private var fixtureArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
fixtureArguments["NSAutomaticCapitalizationEnabled"] = false
fixtureArguments["NSAutomaticPeriodSubstitutionEnabled"] = false
UserDefaults.standard.setVolatileDomain(fixtureArguments, forName: UserDefaults.argumentDomain)
guard !NSSpellChecker.isAutomaticCapitalizationEnabled else {
    fputs("InputFixture could not disable capitalization in its own volatile defaults\n", stderr)
    exit(1)
}
guard !NSSpellChecker.isAutomaticPeriodSubstitutionEnabled else {
    fputs("InputFixture could not disable period substitution in its own volatile defaults\n", stderr)
    exit(1)
}
private let fixtureApplication = FixtureApplication.shared
private let fixtureDelegate = FixtureDelegate()
fixtureApplication.setActivationPolicy(.regular)
fixtureApplication.delegate = fixtureDelegate
fixtureApplication.run()
