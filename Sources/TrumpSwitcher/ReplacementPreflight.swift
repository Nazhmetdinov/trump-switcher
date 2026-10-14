import AppKit
import Carbon
import SwitcherCore

enum ReplacementPreflight {
    /// Shared only by one pending boundary and its read-only worker. No lock is
    /// held across AX IPC, and the worker never reads AutoMonitor's main state.
    final class Cancellation {
        private let lock = NSLock()
        private var active = true
        var isActive: Bool {
            lock.lock(); defer { lock.unlock() }
            return active
        }
        func cancel() {
            lock.lock(); active = false; lock.unlock()
        }
    }
    struct Context {
        let element: AXUIElement
        let selection: NSRange
        let beforeCaret: String
        let afterCaret: String?
        var prefersSelectionReplacement = false
        var ownSelectionWaits = 0
        func plan(original: String, replacement: String) -> WordReplacementPlan? {
            WordReplacementPlan(original: original, replacement: replacement, selection: selection,
                                beforeCaret: beforeCaret, afterCaret: afterCaret)
        }
    }
    /// A recent keyboard selection owned by this monitor, not a general
    /// permission to wait through arbitrary selection changes in the editor.
    struct SelectionProgress {
        let element: AXUIElement
        let pid: pid_t
        let originalRange: NSRange
        let expiresAt: TimeInterval

        func contains(_ selection: CFRange, in field: AXUIElement) -> Bool {
            guard ProcessInfo.processInfo.systemUptime < expiresAt, CFEqual(element, field),
                  originalRange.location >= 0, originalRange.length > 0,
                  originalRange.location <= Int.max - originalRange.length,
                  selection.length > 0, selection.length <= originalRange.length else { return false }
            let end = originalRange.location + originalRange.length
            return selection.location == end - selection.length
        }
    }
    struct OpaqueContext {
        let element: AXUIElement
        // A known editor with unsupported range APIs is different from an
        // opaque focused group. Never weaken the former into an unknown focus.
        let resolvedField: Bool
    }
    enum Result { case matches(Context), changed(String), unavailable(OpaqueContext) }
    enum OpaqueIdentityStatus { case current, unavailable, changed }
    private enum FocusIdentity { case allowed(AXUIElement), unsafe, unavailable }
    private enum MetadataSafety { case allowed, unsafe, unavailable }
    private enum KeyboardReplacementMode { case selection, backspace, retry, reject }
    private enum CheckResult {
        case matches(Context), unavailable, retry(String), ownSelectionInProgress, reject(String)
    }
    /// No AXValue/document reads. At most 130 UTF-16 units around the caret,
    /// only immediately before a proposed replacement in an allowed field.
    static func check(original: String, pid: pid_t, expectedField: AXUIElement? = nil,
                      expectedOpaqueFocus: AXUIElement? = nil, cancellation: Cancellation? = nil,
                      deadline absoluteDeadline: TimeInterval? = nil,
                      pinnedOpaqueContext: OpaqueContext? = nil,
                      previousSelection: SelectionProgress? = nil) -> Result {
        // Read the current focus again at a proposed edit. Background metadata
        // can be one key/field behind; never act on that stale element.
        var element = pinnedOpaqueContext?.resolvedField == true ? pinnedOpaqueContext?.element : expectedField
        var opaqueFocus = pinnedOpaqueContext?.resolvedField == false ? pinnedOpaqueContext?.element : expectedOpaqueFocus
        // The tap can receive Space before the target app has dispatched the
        // preceding keyDown. AX then exposes a genuine but older caret suffix.
        // Wait only for that same editor, without pumping our event loop or
        // changing text/selection. Never turn a mismatch into blind deletion.
        // AppKit may briefly stop its editor queue while closing its input
        // indicator UI. Even a fully different suffix can be the PREVIOUS word:
        // a transport fence does not acknowledge an editor mutation. Retry only
        // in the same safe field; selection/focus changes still reject at once.
        // No write is authorized until the exact captured word is observed.
        let graceDeadline = ProcessInfo.processInfo.systemUptime + 0.75
        let deadline = min(graceDeadline, absoluteDeadline ?? graceDeadline)
        var lastFailure = Result.changed("Редактор не подтвердил слово до срока ожидания")
        var ownSelectionWaits = 0
        let ownedSelection = previousSelection?.pid == pid ? previousSelection : nil
        repeat {
            guard cancellation?.isActive != false else { return .changed("Проверка отменена") }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
                return .changed("Активное приложение изменилось")
            }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return lastFailure }
            if element == nil {
                // Capture before resolveFocus: following a marker owner can
                // itself yield while the app moves focus to another editor.
                switch focusedIdentity(pid: pid, budget: min(0.025, remaining), cancellation: cancellation) {
                case .allowed(let current):
                    if let opaqueFocus, !CFEqual(current, opaqueFocus) {
                        return .changed("Фокус перешёл в другое поле")
                    }
                    opaqueFocus = current
                case .unsafe: return .changed("Поле защищено или недоступно для ввода")
                case .unavailable:
                    // A busy opaque editor can miss a focus/safety reply just
                    // like a normal text field. Preserve the pinned identity
                    // while retrying; absence never grants keyboard mutation.
                    lastFailure = .changed("Редактор не подтвердил принадлежность поля до срока ожидания")
                    let wait = min(0.002, deadline - ProcessInfo.processInfo.systemUptime)
                    guard wait > 0 else { return lastFailure }
                    Thread.sleep(forTimeInterval: wait)
                    continue
                }
            }
            guard cancellation?.isActive != false else { return .changed("Проверка отменена") }
            switch DirectWordReplacement.detailedFocusResolution(pid: pid, budget: min(0.035, deadline - ProcessInfo.processInfo.systemUptime)) {
            case .field(let current):
                // Initial discovery may resolve a wrapper into its editor. A
                // retry already owns one exact opaque object and cannot upgrade
                // it into a different marker owner before reading that text.
                if let pinnedOpaqueContext, !CFEqual(current, pinnedOpaqueContext.element) {
                    return .changed("Фокус перешёл в другое поле")
                }
                if let element, !CFEqual(current, element) { return .changed("Фокус перешёл в другое поле") }
                element = current
            case .unsafe:
                return .changed("Поле защищено или недоступно для ввода")
            case .selection:
                return .changed("Фокус контейнера сообщает выделение")
            case .opaque(let current):
                guard element == nil, let opaqueFocus, CFEqual(current, opaqueFocus) else {
                    return .changed("Известный редактор больше не подтвердил доступ к полю")
                }
                return .unavailable(OpaqueContext(element: opaqueFocus, resolvedField: false))
            case .unavailable:
                // An editor processing queued keys may temporarily miss an AX
                // reply. It is not proof of a different field, nor permission
                // to fall back to unverified deletion of a previously known one.
                lastFailure = .changed("Фокус не ответил до срока ожидания")
                let wait = min(0.001, deadline - ProcessInfo.processInfo.systemUptime)
                guard wait > 0 else { return lastFailure }
                Thread.sleep(forTimeInterval: wait)
                continue
            }
            guard cancellation?.isActive != false else { return .changed("Проверка отменена") }
            guard let element else { return .changed("Редактор не предоставил поле ввода") }
            let result = checkCurrent(original: original, element: element,
                                      budget: deadline - ProcessInfo.processInfo.systemUptime, cancellation: cancellation,
                                      probeSelectionReplacement: true, previousSelection: ownedSelection)
            switch result {
            case .matches(var context):
                context.ownSelectionWaits = ownSelectionWaits
                return .matches(context)
            case .unavailable:
                guard ownSelectionWaits == 0 else { return .changed("Редактор не подтвердил текст после собственного выделения") }
                guard cancellation?.isActive != false else { return .changed("Проверка отменена") }
                let markerSelection = DirectWordReplacement.markerSelection(element,
                    budget: deadline - ProcessInfo.processInfo.systemUptime)
                guard cancellation?.isActive != false else { return .changed("Проверка отменена") }
                switch markerSelection {
                case .collapsed, .absent:
                    return .unavailable(OpaqueContext(element: element, resolvedField: true))
                case .selected: return .changed("Маркеры непрозрачного редактора сообщают выделение")
                case .unsafe: return .changed("Поле больше не разрешает безопасную замену")
                case .unavailable:
                    lastFailure = .changed("Редактор не подтвердил отсутствие выделения до срока ожидания")
                    let wait = min(0.002, deadline - ProcessInfo.processInfo.systemUptime)
                    guard wait > 0 else { return lastFailure }
                    Thread.sleep(forTimeInterval: wait)
                    continue
                }
            case .ownSelectionInProgress:
                ownSelectionWaits += 1
                lastFailure = .changed("Редактор не завершил собственное выделение до срока ожидания")
                let wait = min(0.002, deadline - ProcessInfo.processInfo.systemUptime)
                guard wait > 0 else { return lastFailure }
                Thread.sleep(forTimeInterval: wait)
            case .reject(let reason): return .changed(reason)
            case .retry(let reason):
                lastFailure = .changed(reason)
                let wait = min(0.002, deadline - ProcessInfo.processInfo.systemUptime)
                guard wait > 0 else { return lastFailure }
                Thread.sleep(forTimeInterval: wait)
            }
        } while ProcessInfo.processInfo.systemUptime < deadline
        return lastFailure
    }

    /// A worker result is only a proposal. Recheck the actual focus and caret
    /// immediately before posting deletion, with no retry or delayed mutation.
    static func isCurrent(_ context: Context, original: String, pid: pid_t) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              case .field(let current) = DirectWordReplacement.resolveFocus(pid: pid, budget: 0.025),
              CFEqual(current, context.element),
              case .matches(let fresh) = checkCurrent(original: original, element: current) else { return false }
        return fresh.selection == context.selection && fresh.beforeCaret == context.beforeCaret &&
               fresh.afterCaret == context.afterCaret
    }

    /// A missing range API never discards field ownership. Both the resolved
    /// editor and genuinely opaque focused group must still be the same object.
    static func isCurrentOpaque(_ context: OpaqueContext, pid: pid_t) -> Bool {
        if case .current = opaqueIdentityStatus(context, pid: pid) { return true }
        return false
    }

    /// A timeout is neither a matching identity nor proof that focus changed.
    /// The caller may retry only .unavailable, with this same pinned context and
    /// the original transaction deadline. No text or selection mutation occurs.
    static func opaqueIdentityStatus(_ context: OpaqueContext, pid: pid_t,
                                     budget: TimeInterval = 0.025,
                                     previousSelection: SelectionProgress? = nil,
                                     expectedCaretBounds: ClosedRange<Int>? = nil) -> OpaqueIdentityStatus {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return .changed }
        guard budget.isFinite, budget > 0 else { return .unavailable }
        let deadline = ProcessInfo.processInfo.systemUptime + budget
        // Leave time for raw-focus/safety verification after the resolver. This
        // is one short write-edge read, not another 750 ms worker grace period.
        switch DirectWordReplacement.detailedFocusResolution(pid: pid, budget: min(0.025, budget / 2)) {
        case .unsafe: return .changed
        case .selection: return .changed
        case .field(let current):
            guard context.resolvedField, CFEqual(current, context.element) else { return .changed }
            switch safeMetadata(current, pid: pid, budget: deadline - ProcessInfo.processInfo.systemUptime) {
            case .allowed:
                switch DirectWordReplacement.markerSelection(current, budget: deadline - ProcessInfo.processInfo.systemUptime) {
                case .collapsed, .absent: return .current
                case .selected:
                    // A marker snapshot may still expose our preceding keyboard
                    // selection while the same editor applies that batch. This
                    // grants only a retry, never permission to insert into it.
                    guard let previousSelection, previousSelection.pid == pid,
                          CFEqual(previousSelection.element, current),
                          ProcessInfo.processInfo.systemUptime < previousSelection.expiresAt else { return .changed }
                    let remaining = deadline - ProcessInfo.processInfo.systemUptime
                    guard remaining > 0,
                          AXUIElementSetMessagingTimeout(current, Float(min(0.005, remaining))) == .success else { return .unavailable }
                    var raw: CFTypeRef?
                    let error = AXUIElementCopyAttributeValue(current, kAXSelectedTextRangeAttribute as CFString, &raw)
                    if error == .cannotComplete || error == .failure { return .unavailable }
                    guard error == .success, let raw, CFGetTypeID(raw) == AXValueGetTypeID(),
                          AXValueGetType(raw as! AXValue) == .cfRange else { return .changed }
                    var selection = CFRange()
                    guard AXValueGetValue(raw as! AXValue, .cfRange, &selection), selection.location >= 0 else { return .changed }
                    if previousSelection.contains(selection, in: current) { return .unavailable }
                    // Numeric and marker metadata can be updated separately.
                    // A collapsed caret may advance only within our already
                    // posted output range; still wait for collapsed markers.
                    if selection.length == 0, expectedCaretBounds?.contains(selection.location) == true,
                       ProcessInfo.processInfo.systemUptime < previousSelection.expiresAt { return .unavailable }
                    return .changed
                case .unsafe: return .changed
                case .unavailable: return .unavailable
                }
            case .unsafe: return .changed
            case .unavailable: return .unavailable
            }
        case .opaque(let current):
            guard !context.resolvedField else { return .unavailable }
            guard CFEqual(current, context.element) else { return .changed }
            switch focusedIdentity(pid: pid, budget: deadline - ProcessInfo.processInfo.systemUptime) {
            case .allowed(let current): return CFEqual(current, context.element) ? .current : .changed
            case .unsafe: return .changed
            case .unavailable: return .unavailable
            }
        case .unavailable: return .unavailable
        }
    }

    /// Only focus and safety metadata. Follow explicit focused children, never
    /// guessed descendants, text, values, or selected-marker ownership.
    private static func focusedIdentity(pid: pid_t, budget: TimeInterval, cancellation: Cancellation? = nil) -> FocusIdentity {
        let deadline = ProcessInfo.processInfo.systemUptime + budget
        func prepare(_ element: AXUIElement) -> Bool {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0, cancellation?.isActive != false else { return false }
            AXUIElementSetMessagingTimeout(element, Float(min(0.005, remaining)))
            return true
        }
        func child(_ element: AXUIElement) -> (AXError, AXUIElement?) {
            guard prepare(element) else { return (.cannotComplete, nil) }
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, kAXFocusedUIElementAttribute as CFString, &value)
            guard error == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return (error, nil) }
            return (.success, value as! AXUIElement)
        }
        let root = AXUIElementCreateApplication(pid)
        ApplicationFocusBootstrap.prepare(root, budget: deadline - ProcessInfo.processInfo.systemUptime)
        guard let first = child(root).1 else { return .unavailable }
        var current = first
        for _ in 0..<4 {
            let (error, next) = child(current)
            if let next, !CFEqual(current, next) { current = next; continue }
            guard error == .success || error == .attributeUnsupported || error == .noValue || error == .notImplemented else {
                return .unavailable
            }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            switch safeMetadata(current, pid: pid, budget: remaining, cancellation: cancellation) {
            case .allowed: return .allowed(current)
            case .unsafe: return .unsafe
            case .unavailable: return .unavailable
            }
        }
        return .unavailable
    }

    private static func safeMetadata(_ element: AXUIElement, pid: pid_t, budget: TimeInterval,
                                     cancellation: Cancellation? = nil) -> MetadataSafety {
        guard budget > 0, cancellation?.isActive != false else { return .unavailable }
        var actualPID: pid_t = 0
        guard AXUIElementGetPid(element, &actualPID) == .success else { return .unavailable }
        guard actualPID == pid else { return .unsafe }
        AXUIElementSetMessagingTimeout(element, Float(min(0.015, budget)))
        let names = [kAXRoleAttribute, kAXSubroleAttribute, "AXProtectedContent", kAXEnabledAttribute] as CFArray
        var values: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(element, names, [], &values)
        guard error == .success else {
            return error == .invalidUIElement || error == .apiDisabled ? .unsafe : .unavailable
        }
        guard let items = values as? [Any] else { return .unavailable }
        switch FocusSafetyMetadata.decode(items) {
        case .allowed: return .allowed
        case .unsafe: return .unsafe
        case .unavailable: return .unavailable
        }
    }

    /// Unsupported capability may justify the opaque keyboard path. A failed
    /// transport does not: the editor may simply be busy delivering earlier keys.
    private static func readFailure(_ error: AXError, allowUnsupported: Bool = true) -> CheckResult {
        switch error {
        case .attributeUnsupported, .parameterizedAttributeUnsupported, .notImplemented:
            return allowUnsupported ? .unavailable : .reject("Редактор не предоставляет обязательные метаданные поля")
        case .cannotComplete, .failure, .noValue:
            return .retry("Редактор не подтвердил данные поля до срока ожидания")
        default:
            return .reject("Поле больше не предоставляет безопасный доступ к тексту")
        }
    }

    private static func embeddedError(_ value: Any) -> AXError? {
        let raw = value as CFTypeRef
        guard CFGetTypeID(raw) == AXValueGetTypeID(), AXValueGetType(raw as! AXValue) == .axError else { return nil }
        var error = AXError.failure
        return AXValueGetValue(raw as! AXValue, .axError, &error) ? error : .failure
    }

    /// A verified editable marker field can replace a keyboard selection in
    /// one insertion. Avoid deleting rich editable content down to an empty
    /// paragraph: WebKit may retain placeholder BRs and rebalance its spaces.
    /// This is capability discovery on the worker, never an AX mutation.
    private static func keyboardReplacementMode(_ element: AXUIElement, deadline: TimeInterval,
                                                cancellation: Cancellation?) -> KeyboardReplacementMode {
        func prepare() -> Bool {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0, cancellation?.isActive != false else { return false }
            AXUIElementSetMessagingTimeout(element, Float(min(0.015, remaining)))
            return true
        }
        func failure(_ error: AXError) -> KeyboardReplacementMode {
            switch error {
            case .attributeUnsupported, .parameterizedAttributeUnsupported, .notImplemented: return .backspace
            case .cannotComplete, .failure, .noValue: return .retry
            default: return .reject
            }
        }
        guard prepare() else { return .retry }
        var names: CFArray?
        let nameError = AXUIElementCopyParameterizedAttributeNames(element, &names)
        guard nameError == .success else { return failure(nameError) }
        guard let names = names as? [String] else { return .retry }
        let required: Set<String> = ["AXTextOperation", "AXStringForTextMarkerRange"]
        guard required.isSubset(of: Set(names)) else { return .backspace }
        for name in [kAXSelectedTextAttribute, kAXSelectedTextRangeAttribute] {
            guard prepare() else { return .retry }
            var settable: DarwinBoolean = false
            let error = AXUIElementIsAttributeSettable(element, name as CFString, &settable)
            guard error == .success else { return failure(error) }
            guard settable.boolValue else { return .backspace }
        }
        guard prepare() else { return .retry }
        var raw: CFTypeRef?
        let markerError = AXUIElementCopyAttributeValue(element, "AXSelectedTextMarkerRange" as CFString, &raw)
        guard markerError == .success else { return failure(markerError) }
        guard let raw, CFGetTypeID(raw) == AXTextMarkerRangeGetTypeID() else { return .retry }
        let markers = raw as! AXTextMarkerRange
        guard CFEqual(AXTextMarkerRangeCopyStartMarker(markers), AXTextMarkerRangeCopyEndMarker(markers)) else { return .reject }
        return .selection
    }

    private static func checkCurrent(original: String, element: AXUIElement, budget: TimeInterval = 0.03,
                                     cancellation: Cancellation? = nil,
                                     probeSelectionReplacement: Bool = false,
                                     previousSelection: SelectionProgress? = nil) -> CheckResult {
        guard cancellation?.isActive != false else { return .reject("Проверка отменена") }
        guard !original.isEmpty, original.utf16.count <= 128 else { return .reject("Недопустимая длина проверяемого слова") }
        guard budget > 0 else { return .retry("Истёк срок проверки слова") }
        let deadline = ProcessInfo.processInfo.systemUptime + budget
        AXUIElementSetMessagingTimeout(element, Float(min(0.015, budget)))
        var values: CFArray?
        let attributes = [kAXSelectedTextRangeAttribute, kAXNumberOfCharactersAttribute,
                          kAXRoleAttribute, kAXSubroleAttribute, "AXProtectedContent", kAXEnabledAttribute] as CFArray
        let metadataError = AXUIElementCopyMultipleAttributeValues(element, attributes, [], &values)
        guard cancellation?.isActive != false else { return .reject("Проверка отменена") }
        guard metadataError == .success else { return readFailure(metadataError, allowUnsupported: false) }
        guard let items = values as? [Any], items.count == 6 else {
            return .reject("Редактор вернул неполные данные поля")
        }
        // AXCopyMultiple can succeed while individual entries contain AXError.
        // Never interpret a timeout in safety metadata as an absent/false flag.
        for index in 1...5 {
            if let error = embeddedError(items[index]) {
                switch error {
                case .attributeUnsupported, .noValue, .notImplemented: break
                default: return readFailure(error, allowUnsupported: false)
                }
            }
        }
        switch FocusSafetyMetadata.decode(Array(items[2...5])) {
        case .allowed: break
        case .unsafe: return .reject("Поле больше не разрешает ввод")
        case .unavailable: return .retry("Редактор не подтвердил безопасность поля")
        }
        // resolveFocus already identified an editor. Missing/changing metadata
        // must not turn that known editor into an opaque fallback mid-transaction.
        guard [kAXTextFieldRole, kAXTextAreaRole, kAXGroupRole].contains(items[2] as? String ?? "") else {
            return .reject("Редактор не подтвердил роль поля")
        }
        if let error = embeddedError(items[0]) { return readFailure(error) }
        let selectionValue = items[0] as CFTypeRef
        guard CFGetTypeID(selectionValue) == AXValueGetTypeID() else { return .reject("Редактор не подтвердил положение курсора") }
        var selection = CFRange()
        guard AXValueGetValue(selectionValue as! AXValue, .cfRange, &selection), selection.location >= 0 else { return .reject("Редактор вернул неверное положение курсора") }
        guard selection.length == 0 else {
            // A process-tail ACK can arrive while the editor still applies our
            // preceding Shift+Left batch. Only that exact, short-lived range
            // progression may wait; no text is read or modified while selected.
            if let previousSelection, previousSelection.contains(selection, in: element) {
                return .ownSelectionInProgress
            }
            return .reject("В известном поле появилось постороннее выделение")
        }
        let start = max(0, selection.location - original.utf16.count - 1)
        let extra = (items[1] as? Int).map { $0 > selection.location ? 1 : 0 } ?? 0
        var range = CFRange(location: start, length: selection.location - start + extra)
        guard let parameter = AXValueCreate(.cfRange, &range) else { return .reject("Не удалось создать диапазон проверки") }
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { return .retry("Истёк срок проверки слова") }
        guard cancellation?.isActive != false else { return .reject("Проверка отменена") }
        AXUIElementSetMessagingTimeout(element, Float(min(0.015, remaining)))
        var raw: CFTypeRef?
        let textError = AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString,
                                                                  parameter, &raw)
        guard cancellation?.isActive != false else { return .reject("Проверка отменена") }
        guard textError == .success else { return readFailure(textError) }
        guard let text = raw as? String else { return .reject("Редактор не вернул текст проверяемого диапазона") }
        // Some web/Qt wrappers expose a dummy zero range but no string API.
        // That is "unavailable", not proof that a real word disappeared.
        guard text.utf16.count == range.length else {
            return text.utf16.count < range.length ? .retry("Редактор ещё не доставил весь диапазон") :
                .reject("Редактор вернул текст за пределами проверяемого диапазона")
        }
        let ns = text as NSString
        let offset = selection.location - start
        var context = Context(element: element, selection: NSRange(location: selection.location, length: selection.length),
            beforeCaret: ns.substring(to: offset), afterCaret: extra == 1 ? ns.substring(from: offset) : nil)
        let textMatches = ReplacementContext.matches(original: original, beforeCaret: context.beforeCaret,
            afterCaret: context.afterCaret, selectionLength: selection.length) ||
            EditorCapitalizationAdjustment.verifiedOriginal(original: original, beforeCaret: context.beforeCaret,
                afterCaret: context.afterCaret, selectionLength: selection.length) != nil
        guard textMatches else { return .retry("Редактор не подтвердил набранное слово до срока ожидания") }
        if probeSelectionReplacement {
            switch keyboardReplacementMode(element, deadline: deadline, cancellation: cancellation) {
            case .selection: context.prefersSelectionReplacement = true
            case .backspace: break
            case .retry: return .retry("Редактор ещё не подтвердил способ клавиатурной замены")
            case .reject: return .reject("Редактор изменил доступность или выделение перед заменой")
            }
        }
        return .matches(context)
    }
}
