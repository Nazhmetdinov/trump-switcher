import AppKit
import Carbon
import SwitcherCore

/// Explicit diagnostic only. Accepts no arbitrary text, target, URL or key.
/// Only the signed bundle's disposable local page may receive the fixed input.
enum ChromeInputChecks {
    struct Failure: Error { let reason: String }
    static func run(_ name: String) throws {
        let samples: [String: (String, String, Layout)] = [
            "first-word": ("lkz ", "для ", .english),
            "two-spaces": ("lkz  ", "для  ", .english),
            "bracket-letter": ("b[ ", "их ", .english),
            "english": ("руддщ ", "hello ", .russian),
            "domain": ("нфтвучюкг ", "yandex.ru ", .russian)
        ]
        guard let sample = samples[name], AXIsProcessTrusted(), !IsSecureEventInputEnabled(),
              let page = Bundle.main.url(forResource: "ChromeInputCheck", withExtension: "html"),
              let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == "com.google.Chrome",
              app.executableURL?.path == "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" else {
            throw Failure(reason: "Preflight: fixed case, permission, installed Chrome and local page required")
        }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.08)
        func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
            return value
        }
        func element(_ owner: AXUIElement, _ key: String) -> AXUIElement? {
            guard let value = attribute(owner, key), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! AXUIElement)
        }
        guard let window = element(root, kAXFocusedWindowAttribute),
              let field = element(root, kAXFocusedUIElementAttribute) else { throw Failure(reason: "No focused window/field") }
        func sameTarget() -> Bool {
            guard !IsSecureEventInputEnabled(), AXIsProcessTrusted(), !app.isTerminated,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
                  let nowWindow = element(root, kAXFocusedWindowAttribute), CFEqual(nowWindow, window),
                  let nowField = element(root, kAXFocusedUIElementAttribute), CFEqual(nowField, field),
                  let document = attribute(window, kAXDocumentAttribute) as? String,
                  URL(string: document)?.standardizedFileURL == page.standardizedFileURL,
                  attribute(field, kAXRoleAttribute) as? String == kAXTextAreaRole else { return false }
            var owner: pid_t = 0
            return AXUIElementGetPid(field, &owner) == .success && owner == app.processIdentifier
        }
        func text() -> String? { attribute(field, kAXValueAttribute) as? String }
        guard sameTarget(), text() == "" else { throw Failure(reason: "Own local page must have an empty focused editor") }
        let originalSource = InputSources.currentID()
        guard InputSources.select(sample.2) else { throw Failure(reason: "Required input source unavailable") }
        defer {
            if sameTarget(), let originalSource { _ = InputSources.selectID(originalSource) }
        }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.08))
        let layouts = KeyboardLayouts()
        guard let source = CGEventSource(stateID: .hidSystemState) else { throw Failure(reason: "Cannot construct event source") }
        func pair(code: UInt16, text: String?, flags: CGEventFlags = []) throws {
            guard sameTarget(),
                  let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else {
                throw Failure(reason: "Target changed; stopped before next key")
            }
            for event in [down, up] {
                event.flags = flags
                if let text {
                    let units = Array(text.utf16)
                    event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                }
            }
            down.post(tap: .cgSessionEventTap); up.post(tap: .cgSessionEventTap)
        }
        for character in sample.0 {
            guard let key = layouts.replacement(String(character), layout: sample.2) else {
                throw Failure(reason: "Fixed key unavailable")
            }
            try pair(code: key.code, text: String(character), flags: key.shift ? .maskShift : [])
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.012))
        }
        // Observe after the full decision/delivery deadline, so a temporary
        // correct string followed by a disappearing letter cannot pass.
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.3))
        guard sameTarget(), let actual = text() else { throw Failure(reason: "Target changed; no cleanup attempted") }
        let passed = actual == sample.1
        // Delete only the complete fixed input or its exact expected result.
        // Unexpected/partial text is preserved for review, never selected away.
        var cleaned = false
        if actual == sample.0 || passed {
            try pair(code: UInt16(kVK_ANSI_A), text: nil, flags: .maskCommand)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.08))
            guard sameTarget(), text() == actual else { throw Failure(reason: "Field changed before cleanup") }
            guard let rawSelection = attribute(field, kAXSelectedTextRangeAttribute),
                  CFGetTypeID(rawSelection) == AXValueGetTypeID() else { throw Failure(reason: "Selection unreadable; no deletion") }
            var selected = CFRange()
            guard AXValueGetValue(rawSelection as! AXValue, .cfRange, &selected),
                  selected.location == 0, selected.length == actual.utf16.count else {
                throw Failure(reason: "Whole fixed test text not selected; no deletion")
            }
            try pair(code: UInt16(kVK_Delete), text: nil)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.15))
            cleaned = sameTarget() && text() == ""
        }
        print("Chrome case=\(name) corrected=\(passed) cleaned=\(cleaned) observedLength=\(actual.count)")
        guard passed, cleaned else { throw Failure(reason: "Fixed Chrome case did not pass; no retry") }
    }
}
