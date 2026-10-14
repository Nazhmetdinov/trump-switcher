import AppKit
import Carbon
import SwitcherCore

/// The resolver must distinguish an absent API from an unanswered request.
/// This state machine is also exercised with in-process metadata replies; the
/// production adapter below is its only source of Accessibility observations.
enum FocusRead<Value> { case value(Value), missing, unavailable, unsafe, selection }
enum FocusFieldKind { case editable, container, unavailable, unsafe }
enum FocusResolution<Value> { case field(Value), opaque(Value), unavailable, unsafe, selection }
enum FocusResolutionTraversal {
    static func resolve<Element>(root: Element, same: (Element, Element) -> Bool,
        prepare: (Element) -> Bool, kind: (Element) -> FocusFieldKind,
        focused: (Element) -> FocusRead<Element>, markerOwner: (Element) -> FocusRead<Element>,
        bootstrap: (Element) -> Void = { _ in }) -> FocusResolution<Element> {
        guard prepare(root) else { return .unavailable }
        bootstrap(root)
        guard prepare(root) else { return .unavailable }
        let first: Element
        switch focused(root) {
        case .value(let element): first = element
        case .unsafe: return .unsafe
        case .selection: return .selection
        case .missing, .unavailable: return .unavailable
        }
        var field = first
        // A marker can belong to an AXStaticText child of a focused AXGroup.
        // That owner is useful for finding a real editable ancestor, but it is
        // not the keyboard-focus identity when no editable ancestor is exposed.
        var focusAnchor = first
        var followingMarkerOwner = false
        for _ in 0..<4 {
            guard prepare(field) else { return .unavailable }
            switch kind(field) {
            case .editable: return .field(field)
            case .unsafe: return .unsafe
            case .unavailable: return .unavailable
            case .container: break
            }
            guard prepare(field) else { return .unavailable }
            switch focused(field) {
            case .value(let child):
                if !same(field, child) {
                    if !followingMarkerOwner { focusAnchor = child }
                    field = child; continue
                }
            case .missing: break
            case .unavailable: return .unavailable
            case .unsafe: return .unsafe
            case .selection: return .selection
            }
            guard prepare(field) else { return .unavailable }
            switch markerOwner(field) {
            case .value(let owner):
                if same(field, owner) { return .opaque(focusAnchor) }
                followingMarkerOwner = true
                field = owner
            case .missing: return .opaque(focusAnchor)
            case .unavailable: return .unavailable
            case .unsafe: return .unsafe
            case .selection: return .selection
            }
        }
        return .unavailable
    }
}

/// Read-only AX context for automatic correction. Selection-changing AX writes,
/// including AXTextOperation, are excluded: a delayed or selected replacement
/// can be erased by the user's next key. No app-name list or whole-field reads.
enum DirectWordReplacement {
    enum FieldResolution { case field(AXUIElement), unavailable, unsafe }
    enum MarkerSelection: Equatable { case collapsed, absent, selected, unavailable, unsafe }
    private static func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var output: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &output) == .success ? output : nil
    }
    private static func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    private static func parameter(_ element: AXUIElement, _ name: String, _ input: CFTypeRef) -> CFTypeRef? {
        var output: CFTypeRef?
        return AXUIElementCopyParameterizedAttributeValue(element, name as CFString, input, &output) == .success ? output : nil
    }
    private static func kind(_ field: AXUIElement, pid: pid_t, prepare: (AXUIElement) -> Bool) -> FocusFieldKind {
        var actual: pid_t = 0
        guard AXUIElementGetPid(field, &actual) == .success, actual == pid else { return .unsafe }
        var values: CFArray?
        let names = [kAXRoleAttribute, kAXSubroleAttribute, "AXProtectedContent", kAXEnabledAttribute] as CFArray
        let error = AXUIElementCopyMultipleAttributeValues(field, names, [], &values)
        guard error == .success, let items = values as? [Any], items.count == 4 else {
            return error == .apiDisabled || error == .invalidUIElement ? .unsafe : .unavailable
        }
        let metadata: FocusSafetyMetadata
        switch FocusSafetyMetadata.decode(items) {
        case .allowed(let value): metadata = value
        case .unsafe: return .unsafe
        case .unavailable: return .unavailable
        }
        let role = metadata.role
        if role == kAXTextAreaRole || role == kAXTextFieldRole { return .editable }
        guard role == kAXGroupRole else { return .container }
        guard prepare(field) else { return .unavailable }
        switch readElement(field, "AXEditableAncestor") {
        case .value(let ancestor): return CFEqual(ancestor, field) ? .editable : .container
        case .missing: return .container
        case .unavailable: return .unavailable
        case .unsafe: return .unsafe
        case .selection: return .unsafe
        }
    }

    private static func failure<Value>(_ error: AXError) -> FocusRead<Value> {
        switch error {
        case .attributeUnsupported, .parameterizedAttributeUnsupported, .notImplemented, .noValue: return .missing
        case .apiDisabled, .invalidUIElement: return .unsafe
        default: return .unavailable
        }
    }
    private static func readElement(_ source: AXUIElement, _ attribute: String) -> FocusRead<AXUIElement> {
        var raw: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(source, attribute as CFString, &raw)
        guard error == .success else { return failure(error) }
        guard let field = element(raw) else { return .unavailable }
        return .value(field)
    }

    /// A known editable field can lack numeric ranges while still exposing an
    /// actual selection through markers. Unsupported numeric ranges do not give
    /// permission to ignore that positive selection or a marker transport error.
    static func markerSelectionReply(error: AXError, value: CFTypeRef?) -> MarkerSelection {
        guard error == .success else {
            switch error {
            case .attributeUnsupported, .notImplemented, .noValue: return .absent
            case .apiDisabled, .invalidUIElement: return .unsafe
            default: return .unavailable
            }
        }
        guard let value, CFGetTypeID(value) == AXTextMarkerRangeGetTypeID() else { return .unavailable }
        let range = value as! AXTextMarkerRange
        return CFEqual(AXTextMarkerRangeCopyStartMarker(range), AXTextMarkerRangeCopyEndMarker(range)) ? .collapsed : .selected
    }
    static func markerSelection(_ field: AXUIElement, budget: TimeInterval) -> MarkerSelection {
        guard budget.isFinite, budget > 0,
              AXUIElementSetMessagingTimeout(field, Float(min(0.015, budget))) == .success else { return .unavailable }
        var raw: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(field, "AXSelectedTextMarkerRange" as CFString, &raw)
        return markerSelectionReply(error: error, value: raw)
    }

    /// Follow only explicit focus/selected-marker ownership. No page-tree text,
    /// no document AXValue, and no guessed first text field in a window.
    static func resolveFocus(pid: pid_t, budget: TimeInterval = 0.018) -> FieldResolution {
        switch detailedFocusResolution(pid: pid, budget: budget) {
        case .field(let field): return .field(field)
        // The manual action intentionally supports selected text and performs
        // its own bounded selection verification. Preserve its prior fallback.
        case .opaque, .unavailable, .selection: return .unavailable
        case .unsafe: return .unsafe
        }
    }

    static func detailedFocusResolution(pid: pid_t, budget: TimeInterval = 0.018) -> FocusResolution<AXUIElement> {
        guard !IsSecureEventInputEnabled() else { return .unsafe }
        guard budget.isFinite, budget > 0 else { return .unavailable }
        // A background replacement probe may wait for an editor processing a
        // burst. Existing synchronous callers keep their original 3 ms IPCs.
        let end = ProcessInfo.processInfo.systemUptime + budget
        let perMessage = budget <= 0.018 ? 0.003 : 0.015
        func prepare(_ element: AXUIElement) -> Bool {
            let remaining = end - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return false }
            return AXUIElementSetMessagingTimeout(element, Float(min(perMessage, remaining))) == .success
        }
        let root = AXUIElementCreateApplication(pid)
        return FocusResolutionTraversal.resolve(root: root, same: { CFEqual($0, $1) }, prepare: prepare,
            kind: { kind($0, pid: pid, prepare: prepare) },
            focused: { readElement($0, kAXFocusedUIElementAttribute) }, markerOwner: { field in
            var raw: CFTypeRef?
            let markerError = AXUIElementCopyAttributeValue(field, "AXSelectedTextMarkerRange" as CFString, &raw)
            // A positive selection is not an unsupported caret API. Blind
            // Backspace would replace that selection and delete earlier text.
            switch markerSelectionReply(error: markerError, value: raw) {
            case .collapsed: break
            case .absent: return .missing
            case .selected: return .selection
            case .unavailable: return .unavailable
            case .unsafe: return .unsafe
            }
            guard let raw else { return .unavailable }
            let selected = raw as! AXTextMarkerRange
            let marker = AXTextMarkerRangeCopyStartMarker(selected)
            guard prepare(field) else { return .unavailable }
            var ownerValue: CFTypeRef?
            let ownerError = AXUIElementCopyParameterizedAttributeValue(field, "AXUIElementForTextMarker" as CFString, marker, &ownerValue)
            guard ownerError == .success else { return failure(ownerError) }
            guard let owner = element(ownerValue), prepare(owner) else { return .unavailable }
            // Do not skip protection metadata on a marker's intermediate owner
            // merely because it points to an editable ancestor.
            switch kind(owner, pid: pid, prepare: prepare) {
            case .unsafe: return .unsafe
            case .unavailable: return .unavailable
            case .editable: return .value(owner)
            case .container: break
            }
            guard prepare(owner) else { return .unavailable }
            switch readElement(owner, "AXEditableAncestor") {
            case .value(let editable): return .value(editable)
            case .missing: return .value(owner)
            case .unavailable: return .unavailable
            case .unsafe: return .unsafe
            case .selection: return .selection
            }
        }, bootstrap: { ApplicationFocusBootstrap.prepare($0, budget: end - ProcessInfo.processInfo.systemUptime) })
    }

    private static func selection(_ field: AXUIElement) -> NSRange? {
        guard let raw = value(field, kAXSelectedTextRangeAttribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(raw as! AXValue, .cfRange, &range), range.location >= 0,
              range.length >= 0, range.location <= Int.max - range.length else { return nil }
        return NSRange(location: range.location, length: range.length)
    }
    private static func encoded(_ range: NSRange) -> AXValue? {
        var range = CFRange(location: range.location, length: range.length)
        return AXValueCreate(.cfRange, &range)
    }
    private static func read(_ field: AXUIElement, _ range: NSRange) -> String? {
        guard range.length <= 130, let input = encoded(range),
              let text = parameter(field, kAXStringForRangeParameterizedAttribute, input) as? String,
              text.utf16.count == range.length else { return nil }
        return text
    }
    static func requestResult(_ error: AXError) -> WordReplacementRequestResult {
        switch error {
        case .success: return .accepted
        case .illegalArgument, .invalidUIElement, .invalidUIElementObserver,
             .attributeUnsupported, .actionUnsupported, .notificationUnsupported,
             .notImplemented, .apiDisabled, .noValue, .parameterizedAttributeUnsupported:
            return .rejected
        default:
            // In particular, cannotComplete/failure may mean that the target
            // has not replied yet. Never interpret those as permission to retry.
            return .uncertain
        }
    }

    enum Observation { case matches, changed, unavailable }
    /// Read-only acknowledgement after delivery. No repair retry, cursor move,
    /// whole-field access or storage of typed text follows this observation.
    static func observe(_ context: ReplacementPreflight.Context, original: String,
                        replacement: String, boundary: String, pid: pid_t) -> Observation {
        guard !IsSecureEventInputEnabled(), NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              case .field(let now) = resolveFocus(pid: pid), CFEqual(now, context.element),
              let plan = context.plan(original: original, replacement: replacement),
              let caret = selection(now), caret.length == 0 else { return .unavailable }
        let expected = replacement + boundary
        let end = plan.target.location + expected.utf16.count
        // Enter/Tab may already have moved to a new line/field or submitted.
        // A moved caret is not permission to revisit or repair previous text.
        guard caret.location <= end, caret.location >= plan.target.location else { return .unavailable }
        guard let actual = read(now, NSRange(location: plan.target.location, length: caret.location - plan.target.location)) else { return .unavailable }
        return caret.location == end && actual == expected ? .matches : .changed
    }

    /// AXTextOperation is a replacement command, not a selection-free edit.
    /// WebKit deliberately calls replaceSelectionWithText(..., SelectReplacement::Yes).
    /// Leaving its replacement selected lets the physical Space/Enter erase it;
    /// collapsing through another AX request reintroduces the delayed-selection
    /// race. Automatic input therefore uses the ordered keyboard stream for all
    /// editors. AX remains read-only for focus/preflight/result verification.
    /// Source: WebKit AccessibilityObject::performTextOperation (SelectReplacement::Yes).
    static func attempt(_ context: ReplacementPreflight.Context, original: String,
                        replacement: String, pid: pid_t) -> WordReplacementResult {
        .unsupported
    }
}
