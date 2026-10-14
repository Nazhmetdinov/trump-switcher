import AppKit
import Carbon
import SwitcherCore

enum AccessFailure: Error {
    case refused(String)
    var message: String { switch self { case let .refused(text): return text } }
}

/// Bounded text access; no pasteboard, network, file logs, or saved text.
final class TextAccess {
    private let dictionary = LocalDictionary.shared
    private let keyboard = KeyboardLayouts()
    var settings = CorrectionSettings()
    var dictionariesAvailable: Bool { dictionary.available }
    var dictionaryStatus: String { dictionary.status }
    private var pollPosition: (element: AXUIElement, pid: pid_t, range: CFRange)?
    private var converting = false
    private(set) var automaticCorrections = 0
    private(set) var lastReplacement = "Замен пока не было."

    func pollAttempt(onResult: @escaping (String) -> Void) {
        guard !converting else { return }
        guard let (element, pid) = try? focused(), let position = try? range(element) else {
            pollPosition = nil
            return
        }
        let previous = pollPosition
        pollPosition = (element, pid, position)
        guard let previous, previous.pid == pid, CFEqual(previous.element, element),
              position.length == 0, previous.range.length == 0,
              position.location > previous.range.location,
              position.location - previous.range.location <= 128 else { return }
        autoAttempt(requiresTrailingSpace: true, onResult: onResult)?()
    }

    func resetPolling() { pollPosition = nil }

    func autoAttempt(requiresTrailingSpace: Bool = false, onResult: @escaping (String) -> Void) -> (() -> Void)? {
        guard !converting else { return nil }
        guard let appID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              !["com.apple.dt.Xcode", "com.microsoft.VSCode", "com.jetbrains.", "com.todesktop."]
                .contains(where: { appID.hasPrefix($0) }),
              !Conversion.deniedApp(appID) else {
            onResult("Авто: приложение исключено из исправлений.")
            return nil
        }
        let element: AXUIElement
        let pid: pid_t
        let before: CFRange
        do {
            (element, pid) = try focused()
            before = try range(element)
            guard before.length == 0 else { return nil }
            if requiresTrailingSpace {
                guard before.location > 0,
                      AutoCorrection.isWordSeparator(try read(element, CFRange(location: before.location - 1, length: 1))) else { return nil }
            }
        } catch let failure as AccessFailure {
            onResult(failure.message)
            return nil
        } catch { return nil }
        return { [weak self] in
            guard let self, !self.converting, self.sameFocus(element, pid), let now = try? self.range(element),
                  now.length == 0, now.location == before.location || now.location == before.location + 1 else { return }
            do { onResult(try self.convert(automatic: true)) }
            catch let failure as AccessFailure { onResult(failure.message) }
            catch { onResult("Авто: редактор не поддерживается.") }
        }
    }
    private func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result
    }

    private func focused(expectedPID: pid_t? = nil) throws -> (AXUIElement, pid_t) {
        guard AXIsProcessTrusted() else { throw AccessFailure.refused("Разрешите «Универсальный доступ» в настройках macOS.") }
        guard !IsSecureEventInputEnabled() else { throw AccessFailure.refused("Защищённый ввод: исправление отключено.") }
        guard let app = NSWorkspace.shared.frontmostApplication,
              let id = app.bundleIdentifier, !Conversion.deniedApp(id),
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            throw AccessFailure.refused("В этом приложении исправление отключено.")
        }
        // A caller testing one owned process must never follow a focus race
        // into another app. Reject before creating its AX object or reading it.
        guard expectedPID == nil || app.processIdentifier == expectedPID else {
            throw AccessFailure.refused("Активное приложение изменилось; операция отменена.")
        }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        // A cold web accessibility tree may be initialized by this first
        // request, before it can report its already-focused DOM editor. Retry
        // only discovery, before reading any text or submitting a mutation.
        let focusDeadline = ProcessInfo.processInfo.systemUptime + 0.25
        var rawFocus: AXUIElement?
        repeat {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
                  !IsSecureEventInputEnabled() else {
                throw AccessFailure.refused("Активное приложение или защищённый ввод изменились; операция отменена.")
            }
            let remaining = focusDeadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { break }
            AXUIElementSetMessagingTimeout(root, Float(min(0.025, remaining)))
            var raw: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(root, kAXFocusedUIElementAttribute as CFString, &raw)
            if result == .success, let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() {
                rawFocus = raw as! AXUIElement; break
            }
            guard result == .success || result == .noValue || result == .cannotComplete || result == .failure else { break }
            let wait = min(0.002, focusDeadline - ProcessInfo.processInfo.systemUptime)
            guard wait > 0 else { break }
            Thread.sleep(forTimeInterval: wait)
        } while ProcessInfo.processInfo.systemUptime < focusDeadline
        guard var element = rawFocus else { throw AccessFailure.refused("Не удалось определить поле ввода.") }
        // Chromium/Electron can report the page wrapper as the focused object.
        // Resolve only an actual editable field; never read or replace page text.
        let containerRole = value(element, kAXRoleAttribute) as? String
        if (containerRole == "AXWebArea" || containerRole == kAXGroupRole),
           value(element, kAXSubroleAttribute) as? String != "AXSecureTextField" {
            // A contenteditable group may expose its caret through an owner
            // marker rather than a focused child. Reuse the bounded resolver,
            // which follows only explicit focus/marker ownership and checks PID.
            switch DirectWordReplacement.resolveFocus(pid: app.processIdentifier, budget: 0.05) {
            case .field(let field): element = field
            case .unsafe:
                throw AccessFailure.refused("Защищённое или недоступное поле: исправление отключено.")
            case .unavailable:
                if let field = FocusedFieldResolver.resolve(element,
                    same: { CFEqual($0, $1) },
                    editable: { self.allowed($0) },
                    focused: { self.value($0, kAXFocusedAttribute) as? Bool == true },
                    focusChild: { node in
                        guard let child = self.value(node, kAXFocusedUIElementAttribute),
                              CFGetTypeID(child) == AXUIElementGetTypeID() else { return nil }
                        return (child as! AXUIElement)
                    },
                    children: { self.value($0, kAXChildrenAttribute) as? [AXUIElement] ?? [] }) {
                    element = field
                }
            }
        }
        var fieldPID: pid_t = 0
        guard AXUIElementGetPid(element, &fieldPID) == .success, fieldPID == app.processIdentifier else {
            throw AccessFailure.refused("Активное поле относится к другому приложению.")
        }
        let role = value(element, kAXRoleAttribute) as? String
        guard allowed(element) else {
            let subrole = value(element, kAXSubroleAttribute) as? String ?? "нет"
            let enabled = value(element, kAXEnabledAttribute) as? Bool
            let diagnostic = expectedPID == nil ? "" : " " + capabilitySummary(element)
            throw AccessFailure.refused("Поле не поддерживается: \(role ?? "нет роли"), \(subrole), enabled=\(enabled.map(String.init) ?? "нет").\(diagnostic)")
        }
        return (element, app.processIdentifier)
    }

    private func allowed(_ element: AXUIElement) -> Bool {
        // A missing optional attribute is allowed; a failed AX transport is
        // never interpreted as unprotected/enabled. Read the safety fields as
        // one snapshot so later capability checks cannot weaken a timeout.
        AXUIElementSetMessagingTimeout(element, 0.05)
        let names = [kAXRoleAttribute, kAXSubroleAttribute, "AXProtectedContent", kAXEnabledAttribute] as CFArray
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, names, [], &values) == .success,
              let items = values as? [Any], items.count == 4,
              let role = items[0] as? String else { return false }
        for item in items.dropFirst() {
            let raw = item as CFTypeRef
            if CFGetTypeID(raw) == AXValueGetTypeID(), AXValueGetType(raw as! AXValue) == .axError {
                var error = AXError.failure
                guard AXValueGetValue(raw as! AXValue, .axError, &error),
                      error == .attributeUnsupported || error == .noValue || error == .notImplemented else { return false }
            }
        }
        let subrole = items[1] as? String
        let protected = items[2] as? Bool
        let enabled = items[3] as? Bool
        guard KeyboardSafety.allowed(role: role, subrole: subrole, protected: protected, enabled: enabled) else { return false }
        if Conversion.allowedField(role: role, subrole: subrole, enabled: enabled) { return true }
        let ancestor = value(element, "AXEditableAncestor")
        let editableRoot = ancestor.map { CFGetTypeID($0) == AXUIElementGetTypeID() && CFEqual($0, element) } ?? false
        // WebKit maps role=group contenteditable roots to AXApplicationGroup.
        // That semantic subrole is accepted only with the same positive proof
        // as ordinary editable groups: self owner, bounded reads and writable
        // selection. A group role/subrole alone never authorizes a mutation.
        if Conversion.allowedEditableGroup(role: role,
            subrole: subrole == "AXApplicationGroup" ? nil : subrole,
            enabled: enabled, editableRoot: editableRoot,
            boundedRead: parameterNames(element).contains(kAXStringForRangeParameterizedAttribute),
            selectionWritable: writable(element, kAXSelectedTextRangeAttribute)) { return true }
        // WebKit groups expose editability through the settable-value metadata,
        // but support selection writes only as opaque markers. Never read/write
        // AXValue: require owned selection markers and the bounded marker path.
        guard role == kAXGroupRole, subrole == nil || subrole == "AXUnknown" || subrole == "AXApplicationGroup",
              enabled == true, writable(element, kAXValueAttribute), markerSupported(element),
              writable(element, "AXSelectedTextMarkerRange"),
              parameterNames(element).contains(kAXStringForRangeParameterizedAttribute),
              let selected = value(element, "AXSelectedTextMarkerRange"),
              CFGetTypeID(selected) == AXTextMarkerRangeGetTypeID() else { return false }
        let markers = selected as! AXTextMarkerRange
        return markerOwned(AXTextMarkerRangeCopyStartMarker(markers), by: element) &&
               markerOwned(AXTextMarkerRangeCopyEndMarker(markers), by: element)
    }

    /// Only capability booleans, for the caller that pins an owned fixture PID.
    /// No text, AXValue, marker data or element descriptions enter the report.
    private func capabilitySummary(_ element: AXUIElement) -> String {
        AXUIElementSetMessagingTimeout(element, 0.015)
        let ancestor = value(element, "AXEditableAncestor")
        let selfOwner = ancestor.map { CFGetTypeID($0) == AXUIElementGetTypeID() && CFEqual($0, element) } ?? false
        let names = parameterNames(element)
        let markerNames: Set<String> = ["AXTextOperation", "AXPreviousTextMarkerForTextMarker",
                                       "AXUIElementForTextMarker", "AXStringForTextMarkerRange"]
        return "Capabilities: ancestorSelf=\(selfOwner), boundedRange=\(names.contains(kAXStringForRangeParameterizedAttribute)), " +
               "writableRange=\(writable(element, kAXSelectedTextRangeAttribute)), " +
               "markerAPI=\(markerNames.isSubset(of: names)), writableText=\(writable(element, kAXSelectedTextAttribute)), " +
               "writableValue=\(writable(element, kAXValueAttribute)), writableMarkerRange=\(writable(element, "AXSelectedTextMarkerRange"))."
    }

    private func writable(_ element: AXUIElement, _ name: String) -> Bool {
        var result: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, name as CFString, &result) == .success && result.boolValue
    }

    private func parameterNames(_ element: AXUIElement) -> Set<String> {
        var names: CFArray?
        guard AXUIElementCopyParameterizedAttributeNames(element, &names) == .success else { return [] }
        return Set(names as? [String] ?? [])
    }

    private func parameter(_ element: AXUIElement, _ name: String, _ input: CFTypeRef) -> CFTypeRef? {
        var output: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, name as CFString, input, &output) == .success else { return nil }
        return output
    }

    private func markerSupported(_ element: AXUIElement) -> Bool {
        let required: Set<String> = ["AXTextOperation", "AXPreviousTextMarkerForTextMarker",
            "AXUIElementForTextMarker", "AXStringForTextMarkerRange"]
        return required.isSubset(of: parameterNames(element))
    }

    /// Marker owners can be a static-text child. Follow only its explicit
    /// ancestor chain into this already captured editor, never page descendants.
    private func markerOwned(_ marker: AXTextMarker, by element: AXUIElement) -> Bool {
        guard let ownerValue = parameter(element, "AXUIElementForTextMarker", marker),
              CFGetTypeID(ownerValue) == AXUIElementGetTypeID() else { return false }
        var owner = ownerValue as! AXUIElement
        var expectedPID: pid_t = 0
        guard AXUIElementGetPid(element, &expectedPID) == .success else { return false }
        for _ in 0..<8 {
            var ownerPID: pid_t = 0
            guard AXUIElementGetPid(owner, &ownerPID) == .success, ownerPID == expectedPID else { return false }
            if CFEqual(owner, element) { return true }
            AXUIElementSetMessagingTimeout(owner, 0.01)
            let names = [kAXRoleAttribute, kAXSubroleAttribute, "AXProtectedContent", kAXEnabledAttribute] as CFArray
            var values: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(owner, names, [], &values) == .success,
                  let items = values as? [Any], items.count == 4, let role = items[0] as? String,
                  KeyboardSafety.allowed(role: role, subrole: items[1] as? String,
                                         protected: items[2] as? Bool, enabled: items[3] as? Bool),
                  ![kAXTextAreaRole, kAXTextFieldRole, kAXWindowRole, kAXApplicationRole, "AXWebArea"].contains(role) else { return false }
            for item in items.dropFirst() {
                let raw = item as CFTypeRef
                if CFGetTypeID(raw) == AXValueGetTypeID(), AXValueGetType(raw as! AXValue) == .axError {
                    var error = AXError.failure
                    guard AXValueGetValue(raw as! AXValue, .axError, &error),
                          error == .attributeUnsupported || error == .noValue || error == .notImplemented else { return false }
                }
            }
            var ancestor: CFTypeRef?
            let ancestorError = AXUIElementCopyAttributeValue(owner, "AXEditableAncestor" as CFString, &ancestor)
            if ancestorError == .success, let ancestor, CFGetTypeID(ancestor) == AXUIElementGetTypeID() {
                return CFEqual(ancestor, element)
            }
            guard ancestorError == .attributeUnsupported || ancestorError == .noValue || ancestorError == .notImplemented else { return false }
            if role == kAXGroupRole {
                var editable: DarwinBoolean = false
                let error = AXUIElementIsAttributeSettable(owner, kAXValueAttribute as CFString, &editable)
                guard error == .success && !editable.boolValue || error == .attributeUnsupported || error == .noValue else { return false }
            }
            guard let parent = value(owner, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID(),
                  !CFEqual(parent, owner) else { return false }
            owner = parent as! AXUIElement
        }
        return false
    }

    /// A direct Chromium/WebKit text operation, using field-owned opaque markers.
    /// No keystrokes, clipboard or whole-field AXValue replacement.
    private func replaceByMarkers(_ element: AXUIElement, _ pid: pid_t, _ initial: CFRange,
                                  _ target: CFRange, _ before: String, _ after: String) throws {
        guard let completion = MarkerReplacementPlan(initialCaret: NSRange(location: initial.location, length: initial.length),
                target: NSRange(location: target.location, length: target.length), before: before, after: after),
              let selected = value(element, "AXSelectedTextMarkerRange"),
              CFGetTypeID(selected) == AXTextMarkerRangeGetTypeID() else {
            throw AccessFailure.refused("Веб-редактор не предоставляет маркер курсора. Текст не изменён.")
        }
        let selection = selected as! AXTextMarkerRange
        let startMarker = AXTextMarkerRangeCopyStartMarker(selection)
        let endMarker = AXTextMarkerRangeCopyEndMarker(selection)
        let endpoints: (AXTextMarker, AXTextMarker)?
        if initial.length == 0 {
            guard CFEqual(startMarker, endMarker) else {
                throw AccessFailure.refused("Веб-редактор изменил выделение. Текст не изменён.")
            }
            endpoints = MarkerSelection.range(caret: startMarker, cursor: initial.location,
                target: NSRange(location: target.location, length: target.length),
                previous: { marker in
                    guard let previous = self.parameter(element, "AXPreviousTextMarkerForTextMarker", marker),
                          CFGetTypeID(previous) == AXTextMarkerGetTypeID() else { return nil }
                    return (previous as! AXTextMarker)
                }, allowed: { self.markerOwned($0, by: element) }, same: { CFEqual($0, $1) })
        } else {
            endpoints = MarkerSelection.selectedRange(start: startMarker, end: endMarker,
                selection: NSRange(location: initial.location, length: initial.length),
                target: NSRange(location: target.location, length: target.length),
                allowed: { self.markerOwned($0, by: element) }, same: { CFEqual($0, $1) })
        }
        guard let endpoints, sameFocus(element, pid), let current = try? range(element),
              current.location == initial.location, current.length == initial.length else {
            throw AccessFailure.refused("Веб-редактор не подтвердил границы слова. Текст не изменён.")
        }
        let markerRange = AXTextMarkerRangeCreate(kCFAllocatorDefault, endpoints.0, endpoints.1)
        guard parameter(element, "AXStringForTextMarkerRange", markerRange) as? String == before,
              sameFocus(element, pid), let current = try? range(element),
              current.location == initial.location, current.length == initial.length,
              (try? read(element, target)) == before else {
            throw AccessFailure.refused("Веб-редактор не подтвердил границы слова. Текст не изменён.")
        }
        let trailingLength = initial.length == 0 ? initial.location - target.location - target.length : 0
        let trailing = trailingLength == 0 ? "" : try read(element, CFRange(location: target.location + target.length, length: trailingLength))
        let operation = ["AXTextOperationType": "TextOperationReplacePreserveCase",
                         "AXTextOperationMarkerRanges": [markerRange],
                         "AXTextOperationReplacementString": after,
                         "AXTextOperationSmartReplace": false] as CFDictionary
        var reply: CFTypeRef?
        let request = AXUIElementCopyParameterizedAttributeValue(element, "AXTextOperation" as CFString, operation, &reply)
        if DirectWordReplacement.requestResult(request) == .rejected {
            throw AccessFailure.refused("Веб-редактор отклонил прямую замену.")
        }
        // WebKit selects its replacement; Chromium may already leave a caret.
        // Confirm the actual replacement first. Only collapse exactly its own
        // selected range in the same field, never an unrelated cursor/selection.
        // A timeout is not permission to submit the text operation a second time.
        let deadline = ProcessInfo.processInfo.systemUptime + 0.2
        var collapseSent = false
        repeat {
            guard sameFocus(element, pid), let cursor = try? range(element) else {
                throw AccessFailure.refused("Замена отправлена; курсор изменился. Проверьте текст.")
            }
            let replacementRange = CFRange(location: completion.replacementRange.location, length: completion.replacementRange.length)
            switch completion.state(selection: NSRange(location: cursor.location, length: cursor.length),
                originalText: try? read(element, target), replacementText: try? read(element, replacementRange)) {
            case .complete:
                guard sameFocus(element, pid), let final = try? range(element),
                      final.location == completion.finalSelection.location, final.length == completion.finalSelection.length,
                      (try? read(element, replacementRange)) == after else {
                    throw AccessFailure.refused("Курсор изменился после замены; повторной записи не было.")
                }
                return
            case .collapse(let caret):
                if !collapseSent {
                    // Recheck both the selected range and its contents directly
                    // before the single cursor request. The next observation,
                    // not the request return code, must acknowledge completion.
                    guard sameFocus(element, pid), let selected = try? range(element),
                          selected.location == cursor.location, selected.length == cursor.length,
                          (try? read(element, replacementRange)) == after else {
                        throw AccessFailure.refused("Выделение изменилось после замены; курсор не перемещён.")
                    }
                    collapseSent = true
                    let response: AXError
                    if writable(element, kAXSelectedTextRangeAttribute) {
                        var rangeToSet = CFRange(location: caret.location, length: caret.length)
                        guard let encoded = AXValueCreate(.cfRange, &rangeToSet) else {
                            throw AccessFailure.refused("Текст исправлен, но не удалось подготовить положение курсора.")
                        }
                        response = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, encoded)
                    } else {
                        response = try setVerifiedMarkerSelection(element, pid, current: cursor, desired: caret,
                                                                  replacement: replacementRange, text: after, trailing: trailing)
                    }
                    if DirectWordReplacement.requestResult(response) == .rejected {
                        throw AccessFailure.refused("Текст исправлен, но редактор не позволил снять выделение.")
                    }
                }
            case .waiting:
                if collapseSent { throw AccessFailure.refused("Редактор изменил текст после замены; повторной записи не было.") }
            case .changed:
                throw AccessFailure.refused("Замена отправлена; текст или выделение изменились. Повторной записи не было.")
            }
            // Pumping our run loop here re-enters the global keyboard filter and
            // permits new keys to race the pending selection acknowledgement.
            Thread.sleep(forTimeInterval: 0.002)
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw AccessFailure.refused("Веб-редактор не подтвердил замену. Повторной вставки не было.")
    }

    /// Change only the selection of an already verified replacement. This is
    /// the marker equivalent of setSelectedTextRange, never a second text write.
    private func setVerifiedMarkerSelection(_ element: AXUIElement, _ pid: pid_t, current: CFRange,
                                            desired: NSRange, replacement: CFRange, text: String, trailing: String) throws -> AXError {
        guard writable(element, "AXSelectedTextMarkerRange"), sameFocus(element, pid),
              let raw = value(element, "AXSelectedTextMarkerRange"), CFGetTypeID(raw) == AXTextMarkerRangeGetTypeID() else {
            throw AccessFailure.refused("Текст исправлен, но редактор не подтвердил маркеры выделения.")
        }
        let selected = raw as! AXTextMarkerRange
        let start = AXTextMarkerRangeCopyStartMarker(selected), end = AXTextMarkerRangeCopyEndMarker(selected)
        guard markerOwned(start, by: element), markerOwned(end, by: element) else {
            throw AccessFailure.refused("Маркеры выделения больше не принадлежат полю.")
        }
        let result: AXTextMarkerRange
        if desired.length == 0, current.location == replacement.location, current.length == replacement.length,
           desired.location == replacement.location + replacement.length + trailing.utf16.count,
           trailing.utf16.count <= 128, trailing.allSatisfy({ $0.isWhitespace }),
           parameter(element, "AXStringForTextMarkerRange", selected) as? String == text {
            var caret = end
            for _ in 0..<trailing.utf16.count {
                guard let next = parameter(element, "AXNextTextMarkerForTextMarker", caret),
                      CFGetTypeID(next) == AXTextMarkerGetTypeID(), !CFEqual(next, caret),
                      markerOwned(next as! AXTextMarker, by: element) else {
                    throw AccessFailure.refused("Разделитель после слова изменился; курсор не перемещён.")
                }
                caret = next as! AXTextMarker
            }
            let separatorRange = AXTextMarkerRangeCreate(kCFAllocatorDefault, end, caret)
            guard trailing.isEmpty || parameter(element, "AXStringForTextMarkerRange", separatorRange) as? String == trailing else {
                throw AccessFailure.refused("Разделитель после слова изменился; курсор не перемещён.")
            }
            result = AXTextMarkerRangeCreate(kCFAllocatorDefault, caret, caret)
        } else if desired.location == replacement.location, desired.length == replacement.length,
                  current.location == replacement.location + replacement.length, current.length == 0,
                  CFEqual(start, end),
                  let endpoints = MarkerSelection.range(caret: start, cursor: current.location, target: desired,
                    previous: { marker in
                        guard let previous = self.parameter(element, "AXPreviousTextMarkerForTextMarker", marker),
                              CFGetTypeID(previous) == AXTextMarkerGetTypeID() else { return nil }
                        return previous as! AXTextMarker
                    }, allowed: { self.markerOwned($0, by: element) }, same: { CFEqual($0, $1) }) {
            result = AXTextMarkerRangeCreate(kCFAllocatorDefault, endpoints.0, endpoints.1)
            guard parameter(element, "AXStringForTextMarkerRange", result) as? String == text else {
                throw AccessFailure.refused("Текст выделения изменился; курсор не перемещён.")
            }
        } else {
            throw AccessFailure.refused("Текст исправлен, но требуемый диапазон маркеров не подтверждён.")
        }
        guard sameFocus(element, pid), let verified = try? range(element),
              verified.location == current.location, verified.length == current.length,
              (try? read(element, replacement)) == text else {
            throw AccessFailure.refused("Выделение изменилось; курсор не перемещён.")
        }
        return AXUIElementSetAttributeValue(element, "AXSelectedTextMarkerRange" as CFString, result)
    }

    /// Some WebKit contenteditable groups have no numeric selection getter.
    /// Resolve only the captured field's own marker span; never translate a
    /// page-global offset or read AXValue. One text request, then readback.
    private func convertMarkerOnly(_ element: AXUIElement, _ pid: pid_t, diagnostics: Bool = false) throws -> Layout {
        guard value(element, kAXRoleAttribute) as? String == kAXGroupRole,
              markerSupported(element), writable(element, "AXSelectedTextMarkerRange"),
              sameFocus(element, pid) else {
            throw AccessFailure.refused("Редактор не предоставляет безопасные границы текста.")
        }
        let names = parameterNames(element)
        let hasLength = names.contains("AXLengthForTextMarkerRange")
        var stepStage = "none"
        var lengthStage = "none"
        func selected() -> AXTextMarkerRange? {
            guard let raw = value(element, "AXSelectedTextMarkerRange"),
                  CFGetTypeID(raw) == AXTextMarkerRangeGetTypeID() else { return nil }
            let span = raw as! AXTextMarkerRange
            guard markerOwned(AXTextMarkerRangeCopyStartMarker(span), by: element),
                  markerOwned(AXTextMarkerRangeCopyEndMarker(span), by: element) else { return nil }
            return span
        }
        func same(_ lhs: AXTextMarkerRange, _ rhs: AXTextMarkerRange) -> Bool {
            CFEqual(AXTextMarkerRangeCopyStartMarker(lhs), AXTextMarkerRangeCopyStartMarker(rhs)) &&
            CFEqual(AXTextMarkerRangeCopyEndMarker(lhs), AXTextMarkerRangeCopyEndMarker(rhs))
        }
        func length(_ span: AXTextMarkerRange) -> Int? {
            guard hasLength else { lengthStage = "unsupported"; return nil }
            var raw: CFTypeRef?
            let result = AXUIElementCopyParameterizedAttributeValue(element, "AXLengthForTextMarkerRange" as CFString, span, &raw)
            guard result == .success else { lengthStage = "error-\(result.rawValue)"; return nil }
            guard let number = raw as? NSNumber, number.doubleValue >= 0, number.doubleValue <= 4096,
                  number.doubleValue == Double(number.intValue) else { lengthStage = "invalid"; return nil }
            lengthStage = "ok-\(number.intValue)"
            return number.intValue
        }
        func step(_ marker: AXTextMarker, forward: Bool = false) -> AXTextMarker? {
            var raw: CFTypeRef?
            let name = forward ? "AXNextTextMarkerForTextMarker" : "AXPreviousTextMarkerForTextMarker"
            let result = AXUIElementCopyParameterizedAttributeValue(element, name as CFString, marker, &raw)
            guard result == .success else { stepStage = "error-\(result.rawValue)"; return nil }
            guard let raw, CFGetTypeID(raw) == AXTextMarkerGetTypeID() else { stepStage = "invalid"; return nil }
            guard !CFEqual(raw, marker) else { stepStage = "same"; return nil }
            guard markerOwned(raw as! AXTextMarker, by: element) else { stepStage = "owner"; return nil }
            stepStage = "ok"
            return raw as! AXTextMarker
        }
        func text(_ span: AXTextMarkerRange, limit: Int, adjacent: Bool = false) -> String? {
            let measured = length(span)
            if hasLength {
                guard let measured, measured <= limit else { return nil }
            } else if !adjacent {
                // No length API: prove a bounded span by previous-character
                // traversal before requesting any string, never by reading it.
                let start = AXTextMarkerRangeCopyStartMarker(span)
                var cursor = AXTextMarkerRangeCopyEndMarker(span)
                var count = 0
                while !CFEqual(start, cursor), count < min(limit, 128) {
                    guard let previous = step(cursor) else { return nil }
                    cursor = previous; count += 1
                }
                guard CFEqual(start, cursor) else { return nil }
            }
            guard let result = parameter(element, "AXStringForTextMarkerRange", span) as? String,
                  result.utf16.count <= limit,
                  measured == nil || result.utf16.count == measured else { return nil }
            return result
        }
        func samePosition(_ first: AXTextMarker, _ second: AXTextMarker) -> Bool {
            if CFEqual(first, second) { return true }
            // WebKit reports zero for a reversed marker span as well as an
            // empty one. A one-way zero would treat the end caret as the field
            // start, or accept a different post-write selection start. Require
            // both directed spans to be confirmed empty before equating them.
            return length(AXTextMarkerRangeCreate(kCFAllocatorDefault, first, second)) == 0 &&
                   length(AXTextMarkerRangeCreate(kCFAllocatorDefault, second, first)) == 0
        }
        guard let initial = selected() else {
            throw AccessFailure.refused("Редактор не подтвердил маркеры курсора.")
        }
        let originalStart = AXTextMarkerRangeCopyStartMarker(initial)
        let originalEnd = AXTextMarkerRangeCopyEndMarker(initial)
        let wasSelection = !CFEqual(originalStart, originalEnd)
        let target: AXTextMarkerRange
        let before: String
        let trailing: String
        if wasSelection {
            // A selected phrase can be much longer than one word, so its
            // length must be available without first reading that phrase.
            guard hasLength, let count = length(initial), count > 0, count <= 4096,
                  let captured = text(initial, limit: 4096) else {
                throw AccessFailure.refused("Редактор не подтверждает ограниченную длину выделения.")
            }
            target = initial; before = captured; trailing = ""
        } else {
            var fieldStart: AXTextMarker?
            var fieldRaw: CFTypeRef?
            let fieldRangeResult = AXUIElementCopyParameterizedAttributeValue(element,
                "AXTextMarkerRangeForUIElement" as CFString, element, &fieldRaw)
            if fieldRangeResult == .success, let raw = fieldRaw,
               CFGetTypeID(raw) == AXTextMarkerRangeGetTypeID() {
                let start = AXTextMarkerRangeCopyStartMarker(raw as! AXTextMarkerRange)
                if markerOwned(start, by: element) { fieldStart = start }
            }
            var cursor = originalStart
            var prefix = ""
            var offsets: [Int: AXTextMarker] = [0: originalStart]
            var sawWord = false
            var completeBoundary = false
            var steps = 0
            var stopped = "limit"
            for _ in 0..<128 {
                steps += 1
                if let fieldStart, samePosition(cursor, fieldStart) { completeBoundary = true; break }
                guard let previous = step(cursor) else { stopped = "step"; break }
                let pieceRange = AXTextMarkerRangeCreate(kCFAllocatorDefault, previous, cursor)
                guard let piece = text(pieceRange, limit: 2, adjacent: true),
                      prefix.utf16.count + piece.utf16.count <= 128 else { stopped = "piece"; break }
                prefix = piece + prefix
                cursor = previous
                offsets[prefix.utf16.count] = cursor
                if !piece.isEmpty, piece.allSatisfy({ $0.isWhitespace }) {
                    if sawWord { completeBoundary = true; break }
                } else if !piece.isEmpty { sawWord = true }
            }
            if let fieldStart, samePosition(cursor, fieldStart) { completeBoundary = true }
            guard completeBoundary, let token = Conversion.lastToken(in: prefix),
                  let start = offsets[prefix.utf16.count - token.location],
                  let end = offsets[prefix.utf16.count - NSMaxRange(token)] else {
                let details = diagnostics ? " MarkerBoundary: fieldRange=\(fieldRangeResult.rawValue), fieldStartOwned=\(fieldStart != nil), lengthAPI=\(hasLength), steps=\(steps), units=\(prefix.utf16.count), sawWord=\(sawWord), stopped=\(stopped), step=\(stepStage), length=\(lengthStage)." : ""
                throw AccessFailure.refused("Редактор не подтвердил начало целого слова." + details)
            }
            target = AXTextMarkerRangeCreate(kCFAllocatorDefault, start, end)
            before = (prefix as NSString).substring(with: token)
            trailing = (prefix as NSString).substring(from: NSMaxRange(token))
        }
        guard let destination = Conversion.direction(before) else {
            throw AccessFailure.refused("Нужен текст на одном алфавите: русском или английском.")
        }
        let after = keyboard.convert(before, to: destination)
        let readLimit = wasSelection ? 4096 : 128
        guard after != before, after.utf16.count <= readLimit,
              sameFocus(element, pid), let current = selected(), same(current, initial),
              text(target, limit: readLimit) == before else {
            throw AccessFailure.refused("Фокус, выделение или текст изменились; операция отменена.")
        }
        let targetStart = AXTextMarkerRangeCopyStartMarker(target)
        let operation = ["AXTextOperationType": "TextOperationReplacePreserveCase",
                         "AXTextOperationMarkerRanges": [target],
                         "AXTextOperationReplacementString": after,
                         "AXTextOperationSmartReplace": false] as CFDictionary
        var reply: CFTypeRef?
        let response = AXUIElementCopyParameterizedAttributeValue(element, "AXTextOperation" as CFString, operation, &reply)
        if DirectWordReplacement.requestResult(response) == .rejected {
            throw AccessFailure.refused("Веб-редактор отклонил замену.")
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.2
        var replacement: AXTextMarkerRange?
        var desiredCaret: AXTextMarker?
        repeat {
            guard sameFocus(element, pid), let current = selected() else {
                throw AccessFailure.refused("Замена отправлена; фокус или маркеры изменились. Повторной записи не было.")
            }
            if let replacement, let desiredCaret {
                let start = AXTextMarkerRangeCopyStartMarker(current)
                let end = AXTextMarkerRangeCopyEndMarker(current)
                if CFEqual(start, end), CFEqual(start, desiredCaret), text(replacement, limit: readLimit) == after {
                    return destination
                }
                guard same(current, replacement), text(replacement, limit: readLimit) == after else {
                    throw AccessFailure.refused("Выделение изменилось после замены; курсор повторно не перемещён.")
                }
            } else if samePosition(AXTextMarkerRangeCopyStartMarker(current), targetStart),
                      text(current, limit: readLimit) == after {
                if wasSelection { return destination }
                var caret = AXTextMarkerRangeCopyEndMarker(current)
                let replacementEnd = caret
                var capturedTrailing = ""
                for _ in 0..<128 where capturedTrailing.utf16.count < trailing.utf16.count {
                    guard let next = step(caret, forward: true),
                          let piece = text(AXTextMarkerRangeCreate(kCFAllocatorDefault, caret, next), limit: 2, adjacent: true),
                          !piece.isEmpty, trailing.hasPrefix(capturedTrailing + piece) else {
                        throw AccessFailure.refused("Разделитель изменился; курсор не перемещён.")
                    }
                    capturedTrailing += piece; caret = next
                }
                guard capturedTrailing == trailing, sameFocus(element, pid),
                      let verified = selected(), same(verified, current),
                      text(current, limit: readLimit) == after,
                      trailing.isEmpty || text(AXTextMarkerRangeCreate(kCFAllocatorDefault, replacementEnd, caret), limit: 128) == trailing else {
                    throw AccessFailure.refused("Текст или выделение изменились; курсор не перемещён.")
                }
                replacement = current; desiredCaret = caret
                let collapsed = AXTextMarkerRangeCreate(kCFAllocatorDefault, caret, caret)
                let result = AXUIElementSetAttributeValue(element, "AXSelectedTextMarkerRange" as CFString, collapsed)
                if DirectWordReplacement.requestResult(result) == .rejected {
                    throw AccessFailure.refused("Текст исправлен, но редактор отклонил положение курсора.")
                }
            } else {
                guard same(current, initial), text(target, limit: readLimit) == before else {
                    throw AccessFailure.refused("Замена отправлена; текст или выделение изменились. Повторной записи не было.")
                }
            }
            Thread.sleep(forTimeInterval: 0.002)
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw AccessFailure.refused("Редактор не подтвердил замену и курсор. Повторной записи не было.")
    }

    private func range(_ element: AXUIElement) throws -> CFRange {
        guard let raw = value(element, kAXSelectedTextRangeAttribute), CFGetTypeID(raw) == AXValueGetTypeID() else {
            throw AccessFailure.refused("Редактор не предоставляет положение курсора.")
        }
        let ax = raw as! AXValue
        var result = CFRange()
        guard AXValueGetType(ax) == .cfRange, AXValueGetValue(ax, .cfRange, &result),
              result.location >= 0, result.length >= 0, result.length <= 4096,
              result.location <= Int.max - result.length else {
            throw AccessFailure.refused("Выделение недоступно или длиннее 4096 символов.")
        }
        return result
    }

    private func read(_ element: AXUIElement, _ input: CFRange) throws -> String {
        var input = input
        guard let parameter = AXValueCreate(.cfRange, &input) else { throw AccessFailure.refused("Ошибка диапазона.") }
        var output: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString,
                                                         parameter, &output) == .success,
              let text = output as? String, text.utf16.count == input.length else {
            throw AccessFailure.refused("Редактор не поддерживает ограниченное чтение текста.")
        }
        return text
    }

    private func setRange(_ element: AXUIElement, _ input: CFRange) -> Bool {
        var input = input
        guard let encoded = AXValueCreate(.cfRange, &input) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, encoded) == .success
    }

    private func sameFocus(_ element: AXUIElement, _ pid: pid_t) -> Bool {
        guard let (now, nowPID) = try? focused(expectedPID: pid) else { return false }
        return pid == nowPID && CFEqual(now, element)
    }

    func convert(automatic: Bool = false, expectedPID: pid_t? = nil) throws -> String {
        guard !converting else { throw AccessFailure.refused("Замена уже выполняется.") }
        converting = true
        defer { converting = false }
        let (element, pid) = try focused(expectedPID: expectedPID)
        let initial: CFRange
        do { initial = try range(element) }
        catch {
            guard !automatic, value(element, kAXRoleAttribute) as? String == kAXGroupRole else { throw error }
            return completed(try convertMarkerOnly(element, pid, diagnostics: expectedPID != nil), automatic: false)
        }
        let directWrite = writable(element, kAXSelectedTextAttribute)
        // WebKit advertises SelectedText as writable but dispatches its setter
        // asynchronously. Prefer one field-owned marker operation for a caret
        // or exact selection; never retry an uncertain write with another transport.
        let markerWrite = markerSupported(element) &&
            (writable(element, kAXSelectedTextRangeAttribute) || writable(element, "AXSelectedTextMarkerRange"))
        guard markerWrite || (writable(element, kAXSelectedTextRangeAttribute) && directWrite) else {
            throw AccessFailure.refused("Редактор не поддерживает прямую замену. Текст не изменён.")
        }
        var target = initial
        if initial.length == 0 {
            let window = CFRange(location: max(0, initial.location - 128), length: min(128, initial.location))
            let prefix = try read(element, window)
            if automatic {
                guard let last = prefix.last, AutoCorrection.isWordSeparator(String(last)) else {
                    throw AccessFailure.refused("Авто: ожидаю завершения слова пробелом.")
                }
            }
            guard let token = Conversion.lastToken(in: prefix) else { throw AccessFailure.refused("Нет подходящего слова перед курсором.") }
            target = CFRange(location: window.location + token.location, length: token.length)
        }
        let before = try read(element, target)
        guard let destination = Conversion.direction(before) else {
            throw AccessFailure.refused("Нужен текст на одном алфавите: русском или английском.")
        }
        let after: String
        if automatic {
            guard initial.length == 0,
                  let correction = AutoCorrection.detect(before, recognizes: dictionary.recognizes, recognizesFragment: dictionary.recognizesCommon, settings: settings, convert: keyboard.convert) else {
                throw AccessFailure.refused("Авто включено · слово оставлено без изменений.")
            }
            guard InputSources.available(destination) else {
                throw AccessFailure.refused("Нет включённой стандартной раскладки для исправленного слова.")
            }
            after = correction.text
        } else { after = keyboard.convert(before, to: destination) }
        guard after != before else { throw AccessFailure.refused("Нет символов для исправления.") }
        // Check both content and cursor again immediately before mutation.
        guard sameFocus(element, pid), let current = try? range(element),
              current.location == initial.location, current.length == initial.length,
              try read(element, target) == before else {
            throw AccessFailure.refused("Фокус или текст изменился; операция отменена.")
        }
        if markerWrite {
            try replaceByMarkers(element, pid, initial, target, before, after)
            return completed(destination, automatic: automatic)
        }
        if initial.location != target.location || initial.length != target.length {
            guard setRange(element, target) else { throw AccessFailure.refused("Не удалось выделить слово.") }
        }
        let focusMatches = sameFocus(element, pid)
        let selected = try? range(element)
        let selectionMatches = selected?.location == target.location && selected?.length == target.length
        let textMatches = (try? read(element, target)) == before
        guard focusMatches, selectionMatches, textMatches else {
            // Never restore selection into a different field after a focus change.
            if focusMatches && selectionMatches && textMatches { _ = setRange(element, initial) }
            let reason = !focusMatches ? "фокус" : (!selectionMatches ? "диапазон выделения" : "содержимое")
            throw AccessFailure.refused("Замена отменена: изменился \(reason).")
        }
        let result = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, after as CFString)
        if DirectWordReplacement.requestResult(result) == .rejected {
            // A definitive rejection is the only write failure that permits
            // restoring a still-unmodified selection. A timed-out setter can
            // arrive late and would otherwise insert at that restored caret.
            if sameFocus(element, pid), let selected = try? range(element),
               selected.location == target.location, selected.length == target.length,
               (try? read(element, target)) == before { _ = setRange(element, initial) }
            throw AccessFailure.refused("Редактор отклонил замену.")
        }
        try confirmDirectReplacement(element, pid, initial, target, before, after)
        return completed(destination, automatic: automatic)
    }

    /// SelectedText setters may return before the editor has applied the text.
    /// Observe one request; never resend or move its selection while unconfirmed.
    /// WebKit dispatches accessibilitySetValue onto the main thread:
    /// https://github.com/WebKit/WebKit/blob/main/Source/WebCore/accessibility/mac/WebAccessibilityObjectWrapperMac.mm
    private func confirmDirectReplacement(_ element: AXUIElement, _ pid: pid_t, _ initial: CFRange,
                                          _ target: CFRange, _ before: String, _ after: String) throws {
        let replaced = CFRange(location: target.location, length: after.utf16.count)
        let endCaret = CFRange(location: replaced.location + replaced.length, length: 0)
        let desired = initial.length == 0 ?
            CFRange(location: initial.location - target.length + after.utf16.count, length: 0) : replaced
        func same(_ a: CFRange, _ b: CFRange) -> Bool { a.location == b.location && a.length == b.length }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.2
        var restoreSent = false
        var selectionBeforeRestore: CFRange?
        repeat {
            guard sameFocus(element, pid), let cursor = try? range(element) else {
                throw AccessFailure.refused("Замена отправлена; фокус или курсор изменился. Повторной записи не было.")
            }
            let actual = try? read(element, replaced)
            if actual == after {
                if same(cursor, desired) {
                    guard sameFocus(element, pid), let final = try? range(element), same(final, desired),
                          (try? read(element, replaced)) == after else {
                        throw AccessFailure.refused("Текст или выделение изменились после замены. Повторной записи не было.")
                    }
                    return
                }
                if restoreSent {
                    guard let previous = selectionBeforeRestore, same(cursor, previous) else {
                        throw AccessFailure.refused("Выделение изменилось после замены; курсор не перемещён повторно.")
                    }
                } else {
                    // Only a verified replacement's own range or end caret may
                    // be restored to the caller's original caret/selection shape.
                    guard same(cursor, replaced) || same(cursor, endCaret),
                          sameFocus(element, pid), let verified = try? range(element), same(verified, cursor),
                          (try? read(element, replaced)) == after else {
                        throw AccessFailure.refused("Выделение изменилось после замены; курсор не перемещён.")
                    }
                    selectionBeforeRestore = cursor
                    restoreSent = true
                    var value = desired
                    guard let encoded = AXValueCreate(.cfRange, &value) else {
                        throw AccessFailure.refused("Текст исправлен, но положение курсора не подготовлено.")
                    }
                    let result = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, encoded)
                    if DirectWordReplacement.requestResult(result) == .rejected {
                        throw AccessFailure.refused("Текст исправлен, но редактор отклонил положение курсора.")
                    }
                }
            } else {
                guard !restoreSent, same(cursor, target), (try? read(element, target)) == before else {
                    throw AccessFailure.refused("Текст или выделение изменились после запроса. Повторной записи не было.")
                }
            }
            Thread.sleep(forTimeInterval: 0.002)
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw AccessFailure.refused("Редактор не подтвердил замену или положение курсора. Повторной записи не было.")
    }

    private func completed(_ destination: Layout, automatic: Bool) -> String {
        let switched = InputSources.select(destination)
        if automatic { automaticCorrections += 1 }
        lastReplacement = "\(automatic ? "Авто" : "Вручную"): \(destination == .russian ? "EN → RU" : "RU → EN") · раскладка \(switched ? "переключена" : "не переключена")"
        return switched ? "Исправлено. Повторное ⌃⌥Пробел преобразует обратно." : "Текст исправлен. Раскладку переключите вручную."
    }
}
