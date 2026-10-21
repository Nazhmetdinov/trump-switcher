import AppKit
import Carbon
import SwitcherCore

/// An owned child editor used only by the explicit input-pipeline check. The
/// normal app has no target and never admits tagged/private input.
struct InputPipelineTarget {
    let process: Process
    let nonce: Int64
    var alive: Bool { process.isRunning && process.processIdentifier > 0 }
    func admits(_ event: CGEvent) -> Bool {
        alive && event.getIntegerValueField(.eventSourceUserData) == nonce &&
        event.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid())
    }
}

/// Active session filter. Hold a word boundary while its preceding keystrokes
/// reach the editor, then deliver replacement and queued typing in order.
/// Automatic correction never changes AX selection or schedules field writes.
final class AutoMonitor {
    private let fixture: InputPipelineTarget?
    init(fixture: InputPipelineTarget? = nil, browserAccessibility: BrowserAccessibilitySupport? = nil) {
        self.fixture = fixture; self.browserAccessibility = browserAccessibility
    }
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var activation: NSObjectProtocol?
    private let activationReceipts = ApplicationActivationReceipts()
    private var adoptedActivationReceipt: UInt64?
    private var monitorSession: UInt64 = 0
    private let browserAccessibility: BrowserAccessibilitySupport?
    private var contextTimer: Timer?
    private var application: AXUIElement?
    private let replacementProbeQueue = DispatchQueue(label: "local.trumpswitcher.replacement-probe", qos: .userInitiated)
    private let focusQueue = DispatchQueue(label: "local.trumpswitcher.focus", qos: .userInitiated)
    private var probeBusy = false
    private var probeAgain = false
    private var contextGeneration: UInt64 = 0
    private var focusResetPending = false
    private var settlingSnapshots = 0
    private var focusedRole: String?
    private var focusedIdentity: String?
    private var transition: QueuedLayoutTransition?
    private var recentSelectionProgress: ReplacementPreflight.SelectionProgress?
    private struct PeriodContinuation {
        let id: UInt64
        var sequence: EllipsisContinuation
        let context: ReplacementPreflight.OpaqueContext
        let selectionProgress: ReplacementPreflight.SelectionProgress?
        var expectedCaretBounds: ClosedRange<Int>?
    }
    private var periodContinuation: PeriodContinuation?
    private var periodSerial: UInt64 = 0
    private static func periodModifiers(_ event: CGEvent) -> UInt64 {
        event.flags.intersection([.maskShift, .maskAlphaShift, .maskAlternate,
                                  .maskCommand, .maskControl, .maskSecondaryFn]).rawValue
    }
    private var focused: AXUIElement?
    private var observer: AXObserver?
    private var pid: pid_t = 0
    private var permission = FocusPermission()
    private var permitted: Bool { permission.permitted }
    private var awaitingContext: Bool { permission.awaiting }
    private var buffer = TypingBuffer()
    private var layout: Layout?
    private var sourceID: String?
    private var physicalKeyReleases = PhysicalKeyReleaseTracker()
    private var restoredRepeatPresses = 0
    private func isOriginalInput(_ event: CGEvent) -> Bool {
        guard event.getIntegerValueField(.eventSourceUserData) != Self.ownEvent else { return false }
        return fixture?.admits(event) == true || KeyboardEventOrigin.isSystem(
            stateID: event.getIntegerValueField(.eventSourceStateID),
            userData: event.getIntegerValueField(.eventSourceUserData))
    }
    private func noteForwardedOriginalKeyDown(_ event: CGEvent) {
        guard event.type == .keyDown else { return }
        physicalKeyReleases.forwardedKeyDown(event.getIntegerValueField(.keyboardEventKeycode),
                                            isOriginal: isOriginalInput(event))
    }
    private func restoreRepeatPress(_ delivered: CGEvent, original: CGEvent) {
        guard original.type == .keyDown,
              physicalKeyReleases.needsRestoredPress(original.getIntegerValueField(.keyboardEventKeycode),
                isOriginal: isOriginalInput(original), isRepeat: original.getIntegerValueField(.keyboardEventAutorepeat) != 0) else { return }
        delivered.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
        restoredRepeatPresses += 1
    }
    private func consumeOriginalKeyUp(_ event: CGEvent) -> Bool {
        guard event.type == .keyUp else { return false }
        return physicalKeyReleases.consumeKeyUp(event.getIntegerValueField(.keyboardEventKeycode),
                                               isOriginal: isOriginalInput(event))
    }
    private enum BoundaryCompletion {
        case pass, committed, retryOpaque(ReplacementPreflight.OpaqueContext)
    }
    private struct HeldBoundary {
        let id: UInt64
        let pid: pid_t
        let event: CGEvent
        let read: (ReplacementPreflight.Cancellation, TimeInterval, ReplacementPreflight.OpaqueContext?) -> ReplacementPreflight.Result
        var cancellation: ReplacementPreflight.Cancellation
        let complete: (ReplacementPreflight.Result) -> BoundaryCompletion
        let decisionDeadline: TimeInterval
        var pinnedOpaqueContext: ReplacementPreflight.OpaqueContext?
        var probeStarted = false
    }
    /// A postToPid call only queues input. Keep the original-input gate closed
    /// until the last event crosses the destination's tail tap. This is a
    /// transport fence, not an assertion that an editor has applied the text.
    private struct DeliveryFence {
        let id: UInt64
        let pid: pid_t
        let timestamp: CGEventTimestamp
        let type: CGEventType
        let key: Int64
        let state: Int64

        func matches(_ event: CGEvent) -> Bool {
            event.timestamp == timestamp && event.type == type &&
            event.getIntegerValueField(.keyboardEventKeycode) == key &&
            event.getIntegerValueField(.eventSourceStateID) == state &&
            event.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid()) &&
            event.getIntegerValueField(.eventSourceUserData) == AutoMonitor.ownEvent
        }
    }
    private var pendingBoundary: HeldBoundary?
    private var deliveryFence: DeliveryFence?
    private struct PendingSourceReturn {
        let fenceID: UInt64
        let ticket: InputSourceRollback
        let previous: KeyboardLayoutTable
    }
    private var pendingSourceReturn: PendingSourceReturn?
    private var deliveryTap: CFMachPort?
    private var deliverySource: CFRunLoopSource?
    private var deliveryPID: pid_t?
    private var deliverySerial: UInt64 = 0
    private var lastDeliveryTimestamp: CGEventTimestamp = 0
    private lazy var replaySource: CGEventSource? = {
        let source = CGEventSource(stateID: .privateState)
        source?.userData = Self.ownEvent
        return source
    }()
    private var replayPID: pid_t?
    private var heldEvents = InputDeliveryQueue<CGEvent>(capacity: 1024)
    private var replayLease: InputDeliveryQueue<CGEvent>.Lease?
    private struct CancelledInput {
        let id: UInt64
        let pid: pid_t
        var queue: OrderedInputCancellation<CGEvent>
    }
    private var cancelledInput: CancelledInput?
    private var sessionFence: DeliveryFence?
    private var sessionReplayBoundary = SessionReplayBoundary()
    private var cancellationSerial: UInt64 = 0
    private var manualConversionGate = ManualConversionGate()
    private var pendingSerial: UInt64 = 0
    private(set) var inputTrace: [[String: Any]] = []
    private func trace(_ step: String, type: CGEventType, event: CGEvent) {
        guard fixture != nil, inputTrace.count < 2048,
              fixture?.admits(event) == true || event.getIntegerValueField(.eventSourceUserData) == Self.ownEvent else { return }
        inputTrace.append(["step": step, "type": type.rawValue, "eventType": event.type.rawValue,
            "code": event.getIntegerValueField(.keyboardEventKeycode), "tag": event.getIntegerValueField(.eventSourceUserData),
            "pending": pendingBoundary?.id ?? 0, "delivery": deliveryFence?.id ?? 0,
            "queued": heldEvents.count, "decision": decisionStatus,
            "eventTimestamp": event.timestamp, "time": ProcessInfo.processInfo.systemUptime, "generation": pendingSerial])
    }
    private let dictionary = LocalDictionary.shared
    private let addresses = AddressRecognizer()
    private let keyboard = KeyboardLayouts()
    var settings = CorrectionSettings() { didSet { cancel() } }
    private static let ownEvent: Int64 = 0x5452554d505357
    // Native input-context/cursor UI can temporarily stall an editor for about
    // half a second. The read runs off the tap thread; keep its boundary owned
    // while the same verified field catches up, with one fixed total bound.
    private static let pendingDecisionTimeout: TimeInterval = 1.0
    private static let pendingReadTimeout: TimeInterval = 0.75
    private(set) var receivedSpaces = 0
    private(set) var receivedKeys = 0
    private(set) var receivedCharacters = 0
    private(set) var contextStatus = "Фокус ещё не определён"
    private(set) var decisionStatus = "Ожидание ввода"
    private(set) var focusHints = 0
    private(set) var focusChanges = 0
    private(set) var appKeys = 0
    private(set) var appSpaces = 0
    private(set) var appCorrections = 0
    var typingStatus: String { "Слово: \(buffer.token.count) символов · \(buffer.isAccepting ? "готов" : "до следующей границы")" }
    var appStatus: String { "В приложении: клавиши \(appKeys) · пробелы \(appSpaces) · замены \(appCorrections) · фокус \(focusHints)/\(focusChanges)" }
    private(set) var receivedEvents = 0
    private(set) var automaticCorrections = 0
    private(set) var lastReplacement = "—"
    private(set) var lastError = ""
    private(set) var longestDecisionMS: Double = 0
    private(set) var longestCallbackMS: Double = 0
    private(set) var longestFocusMS: Double = 0
    private(set) var interruptedTaps = 0
    private(set) var reconciledKeys = 0
    private(set) var returnedInputSources = 0
    private(set) var skippedInputSourceReturns = 0
    private(set) var firstKeyFocusChecks = 0
    private(set) var rejectedContextKeys = 0
    private(set) var incompleteWords = 0
    private(set) var unchangedWords = 0
    private(set) var punctuationCorrections = 0
    private(set) var changedEditorWords = 0
    private(set) var verifiedEditorWords = 0
    private(set) var foreignInputEvents = 0
    private(set) var directCorrections = 0
    private(set) var unconfirmedWrites = 0
    private(set) var keyboardFallbacks = 0
    private(set) var selectionKeyboardReplacements = 0
    private(set) var ownSelectionWaits = 0
    private(set) var confirmedKeyboardWrites = 0
    private(set) var lateEditorChanges = 0
    private(set) var deliveryAcks = 0
    private(set) var deliveryTimeouts = 0
    private(set) var orderedCancellations = 0
    // Test-only delivery counts at the owned process's actual head tap. Replay
    // evaluation is not delivery; only events returned by receive are counted.
    private(set) var forwardedKeyDowns = 0
    private(set) var forwardedKeyUps = 0
    // Independent test-only process-tail counts distinguish transport delivery
    // from keys AppKit may consume before NSApplication.sendEvent.
    private(set) var tailKeyDowns = 0
    private(set) var tailKeyUps = 0
    private var recentBoundaryResults: [String] = []
    private var finalBoundaryResults = BoundaryDecisionHistory()
    var boundaryStatus: String {
        let final = finalBoundaryResults.entries.map {
            "#\($0.transactionID) · PID \($0.processID) · \($0.characterCount) симв. · \($0.outcome.rawValue): \($0.reason)"
        }
        return "Последние синхронные решения (без текста, только в памяти):\n" + recentBoundaryResults.joined(separator: "\n") +
            "\nИтоги отложенных проверок (отправка не подтверждает результат в редакторе):\n" + final.joined(separator: "\n")
    }
    var reliabilityStatus: String {
        (browserAccessibility.map { $0.status + "\n" } ?? "") + "Повторов с восстановленным нажатием: \(restoredRepeatPresses)\n" +
        "Проверок нового поля на первой клавише: \(firstKeyFocusChecks) · исключённых клавиш: \(rejectedContextKeys)\nГраниц без полного слова: \(incompleteWords) · слов без нужды в замене / неоднозначных: \(unchangedWords) · замен на пунктуации: \(punctuationCorrections)\nТекст перед заменой проверен: \(verifiedEditorWords) · изменён редактором: \(changedEditorWords) · внешний ввод: \(foreignInputEvents)\nЗамены целым словом подтверждены: \(directCorrections) · без подтверждения: \(unconfirmedWrites)\nКлавиатурный способ: отправлено \(keyboardFallbacks) · подтверждено \(confirmedKeyboardWrites) · последующих изменений редактором: \(lateEditorChanges)\nВозврат раскладки: \(returnedInputSources) · пропущено при смене контекста: \(skippedInputSourceReturns)"
    }
    var hasPendingInput: Bool { cancelledInput != nil || pendingBoundary != nil || deliveryFence != nil || replayPID != nil || !heldEvents.isEmpty }
    var running: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }
    var onResult: ((String) -> Void)?

    func start() -> Bool {
        stop()
        guard AXIsProcessTrusted() else { lastError = "Нет универсального доступа"; return false }
        guard dictionary.bundledAvailable else { lastError = "Не загрузились встроенные словари"; return false }
        InputSources.refreshEnabledSources()
        refreshContext()
        let mask = [CGEventType.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown,
                    .leftMouseUp, .rightMouseUp, .otherMouseUp, .leftMouseDragged, .rightMouseDragged,
                    .otherMouseDragged, .mouseMoved, .scrollWheel].reduce(CGEventMask(0)) {
            $0 | (CGEventMask(1) << $1.rawValue)
        }
        let callback: CGEventTapCallBack = { proxy, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let owner = Unmanaged<AutoMonitor>.fromOpaque(context).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    owner.interruptedTaps += 1
                    owner.releaseCancelledInputAfterFailure()
                    owner.cancel()
                    owner.physicalKeyReleases.reset()
                    owner.report("Фильтр ввода был прерван; текущее слово сброшено")
                    if let tap = owner.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                    return Unmanaged.passUnretained(event)
                }
                return owner.receive(proxy: proxy, type: type, event: event) ? Unmanaged.passUnretained(event) : nil
            }
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let fixture {
            guard fixture.alive else { lastError = "Тестовый редактор завершён"; return false }
            tap = CGEvent.tapCreateForPid(pid: fixture.process.processIdentifier, place: .headInsertEventTap,
                options: .defaultTap, eventsOfInterest: mask, callback: callback, userInfo: context)
        } else {
            tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                options: .defaultTap, eventsOfInterest: mask, callback: callback, userInfo: context)
        }
        guard let tap else {
            lastError = "Не подключён системный фильтр: проверьте доступ Trump Switcher в macOS"
            return false
        }
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        guard let source else { stop(); lastError = "Не удалось создать источник событий"; return false }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        if let fixture, !ensureDeliveryTap(to: fixture.process.processIdentifier) {
            stop()
            lastError = "Не подключён тестовый контроль доставки событий"
            return false
        }
        let listenerSession = monitorSession
        activation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil
        ) { [weak self] notification in
            guard let self else { return }
            let notifiedPID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            let receipt = notifiedPID.map { self.activationReceipts.record(processID: $0) }
            DispatchQueue.main.async { [weak self] in
            guard let self, self.tap != nil, self.monitorSession == listenerSession else { return }
            let action = ApplicationActivationPolicy.decision(notifiedPID: notifiedPID,
                frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                buffer: self.buffer, hasPendingInput: self.hasPendingInput || self.sessionFence != nil,
                trackedPID: self.pid, receiptAlreadyApplied: receipt != nil && receipt?.sequence == self.adoptedActivationReceipt)
            switch action {
            case .ignoreStale: return
            case .refreshOnly: self.refreshContext()
            case .invalidate(let startOfWord):
                self.cancel(); self.invalidateFocus()
                self.buffer.reset(startOfWord: startOfWord)
            case .verifyWholeWord:
                var candidate = self.buffer
                candidate.requireVerifiedText()
                self.cancel(); self.invalidateFocus()
                self.buffer = candidate
            }
            }
        }
        // Poll only metadata. A proposed correction additionally checks a bounded
        // caret suffix where the editor exposes that API; never the document.
        contextTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.refreshContext() }
        lastError = ""
        return running
    }

    private func receive(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Bool {
        var pass = true
        defer {
            if pass { restoreRepeatPress(event, original: event); noteForwardedOriginalKeyDown(event) }
            if fixture != nil, pass {
                if type == .keyDown { forwardedKeyDowns += 1 }
                else if type == .keyUp { forwardedKeyUps += 1 }
            }
        }
        trace("tap", type: type, event: event)
        if event.getIntegerValueField(.eventSourceUserData) == Self.ownEvent {
            observeReplayedFocusChange(event)
            acknowledgeSessionDelivery(event)
            return true
        }
        if cancelledInput != nil {
            if let copy = event.copy(), cancelledInput?.queue.enqueueInterrupt(copy) == true {
                pass = false
                return false
            }
            releaseCancelledInputAfterFailure()
            decisionStatus = "Очередь ввода переполнена; автоматическая замена отменена"
        }
        if [.mouseMoved, .leftMouseUp, .rightMouseUp, .otherMouseUp,
            .leftMouseDragged, .rightMouseDragged, .otherMouseDragged].contains(type) { return true }
        if let destination = pendingBoundary?.pid ?? deliveryFence?.pid ?? replayPID {
            if [.keyDown, .keyUp, .flagsChanged].contains(type),
               NSWorkspace.shared.frontmostApplication?.processIdentifier == destination,
               !event.flags.contains(.maskCommand), !event.flags.contains(.maskControl),
               fixture?.admits(event) == true || KeyboardEventOrigin.isSystem(
                   stateID: event.getIntegerValueField(.eventSourceStateID), userData: event.getIntegerValueField(.eventSourceUserData)),
               let copy = event.copy(), heldEvents.enqueue(copy) {
                pass = false
                return false
            }
            // A shortcut/click must stay behind already-posted characters, but
            // retain session routing (Cmd+Tab and clicks may change the app).
            if let copy = event.copy() {
                flushHeldInput(interrupt: copy)
                pass = false
                return false
            }
            releaseCancelledInputAfterFailure()
        }
        pass = process(type: type, event: event)
        return pass
    }

    private func process(type: CGEventType, event: CGEvent) -> Bool {
        if let fixture, !fixture.alive || NSWorkspace.shared.frontmostApplication?.processIdentifier != fixture.process.processIdentifier {
            cancel(); return true
        }
        guard event.getIntegerValueField(.eventSourceUserData) != Self.ownEvent else { return true }
        defer {
            if type == .keyDown || [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(type) {
                sessionReplayBoundary.observeProcessedBuffer(buffer)
            }
        }
        let callbackStarted = ProcessInfo.processInfo.systemUptime
        defer { longestCallbackMS = max(longestCallbackMS, (ProcessInfo.processInfo.systemUptime - callbackStarted) * 1000) }
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .keyUp {
            if consumeOriginalKeyUp(event) { return false }
            return true
        }
        receivedEvents += 1
        if type == .flagsChanged {
            // A modifier alone inserts no text. Handle actual shortcuts below;
            // clearing here lost the first word after Control+Space and Cmd+A.
            periodContinuation = nil
            return true
        }
        guard type == .keyDown else {
            if [.scrollWheel, .mouseMoved, .leftMouseUp, .rightMouseUp, .otherMouseUp,
                .leftMouseDragged, .rightMouseDragged, .otherMouseDragged].contains(type) { return true }
            buffer.reset()
            invalidateFocus()
            return true
        }
        receivedKeys += 1
        let isRecordedBoundary = [kVK_Space, kVK_Return, kVK_ANSI_KeypadEnter, kVK_Tab].contains(Int(key)) &&
            !event.flags.contains(.maskCommand) && !event.flags.contains(.maskControl)
        let boundaryApp = isRecordedBoundary ? NSWorkspace.shared.frontmostApplication : nil
        let boundaryLength = buffer.token.count
        var asynchronousBoundary = false
        defer {
            if !asynchronousBoundary, let app = boundaryApp, app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
               !IsSecureEventInputEnabled(), !KeyboardSafety.passwordApp(app.bundleIdentifier ?? ""),
               !settings.excludesApp(app.bundleIdentifier ?? "") {
                // Fixed reason strings and a length only; never store the token.
                let entry = "\(app.localizedName ?? "Приложение"): \(boundaryLength) симв. · \(decisionStatus)"
                recentBoundaryResults.append(entry)
                if recentBoundaryResults.count > 6 { recentBoundaryResults.removeFirst() }
            }
        }
        if key == Int64(kVK_Space) { receivedSpaces += 1 }
        appKeys += 1
        if key == Int64(kVK_Space) { appSpaces += 1 }
        if fixture?.admits(event) != true && !KeyboardEventOrigin.isSystem(
            stateID: event.getIntegerValueField(.eventSourceStateID), userData: event.getIntegerValueField(.eventSourceUserData)) {
            // A text expander/another switcher is not physical typing. Its
            // generated characters must not trigger a second replacement.
            foreignInputEvents += 1; buffer.reset(startOfWord: false); transition = nil; recentSelectionProgress = nil; periodContinuation = nil
            decisionStatus = "Ввод другой программой; автозамена пропущена"
            return true
        }
        guard eligibleApplication() != nil else {
            contextGeneration &+= 1; permission.exclude(); cancel()
            rejectedContextKeys += 1; decisionStatus = "Приложение исключено"
            return true
        }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid { refreshContext() }
        var secure = IsSecureEventInputEnabled()
        if !secure, permission.requiresKeyProbe, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
            // Usually the background probe finishes before typing. If a first
            // key beats it, resolve safety once instead of dropping a whole word.
            // Invalidate the older in-flight result so it cannot overwrite this one.
            contextGeneration &+= 1
            firstKeyFocusChecks += 1
            apply(FocusSnapshot.read(pid: pid))
            secure = IsSecureEventInputEnabled()
        }
        guard !secure, permitted, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            buffer.reset(startOfWord: false)
            periodContinuation = nil
            rejectedContextKeys += 1
            decisionStatus = secure ? "Secure Input" : (!permitted ? "Фокус пока исключён / не готов" :
                (NSWorkspace.shared.frontmostApplication?.processIdentifier != pid ? "Смена приложения" : "Сочетание с модификатором"))
            return true
        }
        if let shortcut = TypingShortcut.action(code: UInt16(clamping: key), command: event.flags.contains(.maskCommand),
            control: event.flags.contains(.maskControl), option: event.flags.contains(.maskAlternate), shift: event.flags.contains(.maskShift),
            function: event.flags.contains(.maskSecondaryFn)) {
            shortcut.apply(to: &buffer)
            if shortcut == .invalidate, key == Int64(kVK_Tab), event.flags.contains(.maskCommand),
               !event.flags.contains(.maskControl), !event.flags.contains(.maskAlternate) {
                // A subsequent ordinary Cmd+Tab starts a different input
                // context; replay provenance must not follow it indefinitely.
                sessionReplayBoundary.record(.focusNavigation)
            }
            transition = nil; recentSelectionProgress = nil; periodContinuation = nil
            decisionStatus = "Сочетание клавиш"
            return true
        }
        let currentID = InputSources.currentID()
        let currentLayout = InputSources.layout(forID: currentID)
        guard let currentLayout, let currentID, let currentTable = keyboard.table(currentID) else {
            periodContinuation = nil
            buffer.reset(startOfWord: false); decisionStatus = "Нестандартная раскладка"; return true
        }
        if let sourceID, sourceID != currentID {
            transition = nil; recentSelectionProgress = nil; periodContinuation = nil; InputSources.refreshEnabledSources()
            // Keep the actually typed characters across a manual source change.
            // The detector can resolve a complete mixed-script word at its boundary.
        }
        if let transition, transition.target.id != currentID || event.timestamp > transition.deadline { self.transition = nil }
        sourceID = currentID
        layout = currentLayout
        buffer.noteKey(at: ProcessInfo.processInfo.systemUptime)
        // The same physical key can mean ю after an EN → RU correction. Keep
        // a confirmed punctuation run literal before normalizing stale payloads.
        if var continuation = periodContinuation {
            if continuation.sequence.consume(code: UInt16(clamping: key), modifierBits: Self.periodModifiers(event),
                                             sourceID: currentID, destinationPID: pid) {
                periodContinuation = continuation
                return continuePeriods(event, continuation: continuation, table: currentTable)
            }
            periodContinuation = nil
        }
        let isSpace = key == Int64(kVK_Space)
        let isAddressBoundary = [kVK_Return, kVK_ANSI_KeypadEnter, kVK_Tab].contains(Int(key))
        let text = printableText(event, key: key, currentTable: currentTable, currentID: currentID)
        let targetLayout: Layout = currentLayout == .russian ? .english : .russian
        let punctuationTable = settings.punctuation && text?.contains(where: { !$0.isLetter && !$0.isNumber }) == true
            ? InputSources.sourceID(for: targetLayout).flatMap { keyboard.table($0) } : nil
        let ordinaryPunctuation = text.flatMap { value in punctuationTable.map {
            WordBoundary.isImmediate(value, mapped: currentTable.convert(value, to: $0),
                                     token: buffer.token, mappedToken: currentTable.convert(buffer.token, to: $0))
        }} ?? false
        func detect(_ token: String, otherTable: KeyboardLayoutTable?) -> AutoCorrection? {
            AutoCorrection.detect(token, recognizes: dictionary.recognizes, recognizesFragment: dictionary.recognizesCommon,
                isAddress: addresses.recognizes, settings: settings, convert: { value, target in
                    guard let to = target == currentLayout ? currentTable : otherTable else { return value }
                    let from = target == currentLayout ? otherTable : currentTable
                    return from?.convert(value, to: to) ?? value
                })
        }
        var ellipsisCorrection: AutoCorrection?
        if settings.punctuation, buffer.isAccepting, let text,
           EllipsisBoundary.isCandidate(original: buffer.token, incoming: text),
           event.getIntegerValueField(.keyboardEventAutorepeat) == 0,
           let full = detect(buffer.token + text, otherTable: punctuationTable),
           let stem = detect(String(buffer.token.dropLast(2)), otherTable: punctuationTable),
           full.layout == stem.layout,
           EllipsisBoundary.permits(original: buffer.token, correctionText: full.text, correctedStem: stem.text) {
            // Hold the third period BEFORE the editor can collapse "...". The
            // existing preflight still verifies/deletes only the original "..".
            ellipsisCorrection = full
        }
        let isEllipsis = ellipsisCorrection != nil
        let isPunctuation = ordinaryPunctuation || isEllipsis
        if isSpace || isAddressBoundary || isPunctuation {
            guard isSpace || isPunctuation || !event.flags.contains(.maskAlternate) else { buffer.reset(); return true }
            var boundaryHeld = false
            let replayingBoundary = replayLease != nil
            defer {
                // A held/replayed Tab has not reached the editor yet. Its
                // eventual post, rather than this proposal, invalidates focus.
                if key == Int64(kVK_Tab), !boundaryHeld, !replayingBoundary {
                    buffer.reset(); invalidateFocus()
                }
            }
            guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { buffer.reset(); return true }
            let requiresCompleteWordVerification = buffer.requiresVerifiedText
            guard let original = buffer.finishWord() else {
                incompleteWords += 1; decisionStatus = "Граница: нет полностью набранного слова"; return true
            }
            let token = original + (isPunctuation ? text! : "")
            guard !awaitingContext else { decisionStatus = "Проверка безопасности нового поля ещё не завершена"; return true }
            let started = ProcessInfo.processInfo.systemUptime
            // Resolve target/source tables once per word, not once per character.
            let otherTable = InputSources.sourceID(for: targetLayout).flatMap { keyboard.table($0) }
            guard let correction = ellipsisCorrection ?? detect(token, otherTable: otherTable) else {
                unchangedWords += 1
                decisionStatus = "Словарь: исправление не требуется / неоднозначно · \(token.count) символов"
                return true
            }
            guard isSpace || isPunctuation || (key == Int64(kVK_Tab) ? settings.onTab : settings.onEnter) else {
                decisionStatus = "Исправление на Enter/Tab отключено"
                return true
            }
            guard let replacementTable = correction.layout == currentLayout ? currentTable : otherTable,
                  var keys = KeyboardReplacement.keys(original: original, corrected: correction.text, layout: correction.layout, appendSpace: false,
                                                     keyProvider: { text, _ in replacementTable.replacement(text) }) else {
                decisionStatus = "Не созданы клавиши замены"; return true
            }
            var boundaryText = ""
            if isSpace {
                // Preserve an actual Option+Space/NBSP instead of replacing it
                // with ordinary ASCII Space. Read both layouts' real key data.
                guard let sourceSpace = currentTable.character(code: UInt16(kVK_Space),
                      shift: event.flags.contains(.maskShift), capsLock: false, option: event.flags.contains(.maskAlternate)),
                      AutoCorrection.isWordSeparator(sourceSpace),
                      let boundary = replacementTable.replacement(sourceSpace) else {
                    decisionStatus = "Не создан исходный разделитель"; return true
                }
                boundaryText = sourceSpace
                keys.append(boundary)
            }
            guard let boundaryEvent = event.copy() else { return true }
            let destinationPID = pid
            let expectedField = [kAXTextAreaRole, kAXTextFieldRole].contains(focusedRole ?? "") ? focused : nil
            // A group can be an opaque editor or a wrapper around one. Pin its
            // raw focus identity separately from the resolved editable field.
            let expectedOpaqueFocus = focusedRole == kAXGroupRole ? focused : nil
            let previousSelection = recentSelectionProgress
            let passBoundary = holdBoundary(boundaryEvent, pid: destinationPID, wordLength: original.count, read: { cancellation, deadline, pinnedOpaque in
                // Only immutable target data crosses to this read-only worker.
                // The tap's runloop stays free to collect subsequent input.
                let field: AXUIElement?
                let opaque: AXUIElement?
                if let pinnedOpaque {
                    field = pinnedOpaque.resolvedField ? pinnedOpaque.element : nil
                    opaque = pinnedOpaque.resolvedField ? nil : pinnedOpaque.element
                } else {
                    field = expectedField
                    opaque = expectedOpaqueFocus
                }
                return ReplacementPreflight.check(original: original, pid: destinationPID, expectedField: field,
                                                  expectedOpaqueFocus: opaque, cancellation: cancellation, deadline: deadline,
                                                  pinnedOpaqueContext: pinnedOpaque, previousSelection: previousSelection)
            }) { [self] preflight in
            defer { longestDecisionMS = max(longestDecisionMS, (ProcessInfo.processInfo.systemUptime - started) * 1000) }
            let transactionID = pendingBoundary?.id
            guard transactionID != nil, permitted, !awaitingContext, !IsSecureEventInputEnabled(), eligibleApplication()?.processIdentifier == destinationPID,
                  self.pid == destinationPID, InputSources.currentID() == currentID else {
                decisionStatus = "Контекст, раскладка или разрешение изменились перед заменой"
                return .pass
            }
            var replacementContext: ReplacementPreflight.Context?
            var opaqueContext: ReplacementPreflight.OpaqueContext?
            var observedOriginal = original
            var replacementText = correction.text
            switch preflight {
            case .matches(let context):
                replacementContext = context
                ownSelectionWaits += context.ownSelectionWaits
                if let observed = EditorCapitalizationAdjustment.verifiedOriginal(original: original,
                    beforeCaret: context.beforeCaret, afterCaret: context.afterCaret,
                    selectionLength: context.selection.length) {
                    observedOriginal = observed
                    if !correction.preservesExactCase {
                        guard let adjustment = EditorCapitalizationAdjustment.verified(original: original,
                            replacement: correction.text, beforeCaret: context.beforeCaret,
                            afterCaret: context.afterCaret, selectionLength: context.selection.length),
                              var adjustedKeys = KeyboardReplacement.keys(original: observed, corrected: adjustment.replacement,
                                layout: correction.layout, appendSpace: false,
                                keyProvider: { text, _ in replacementTable.replacement(text) }) else {
                            decisionStatus = "Редактор изменил регистр; безопасная замена не подготовлена"; return .pass
                        }
                        if isSpace, let boundary = keys.last { adjustedKeys.append(boundary) }
                        keys = adjustedKeys
                        replacementText = adjustment.replacement
                    }
                }
                verifiedEditorWords += 1

            case .changed(let reason):
                changedEditorWords += 1; decisionStatus = reason; return .pass
            case .unavailable(let context):
                guard !requiresCompleteWordVerification else {
                    decisionStatus = "После смены окна редактор не подтвердил целое слово; замена пропущена"
                    return .pass
                }
                if let pinned = pendingBoundary?.pinnedOpaqueContext,
                   pinned.resolvedField != context.resolvedField || !CFEqual(pinned.element, context.element) {
                    changedEditorWords += 1
                    decisionStatus = "При повторной проверке изменилось поле редактора"
                    return .pass
                }
                opaqueContext = context
                guard !ReplacementContext.needsVerifiedText(original) else {
                    changedEditorWords += 1; decisionStatus = "Нельзя проверить умное тире / многоточие; замена отменена"; return .pass
                }
            }
            let replacesSelection = replacementContext?.prefersSelectionReplacement == true
            if replacesSelection {
                // Keep the existing word present until the first replacement
                // character replaces its keyboard selection. Standalone final
                // Backspace creates placeholder paragraphs in rich web editors.
                // No AX selection write and no yield inside the outgoing batch.
                let count = observedOriginal.utf16.count
                guard count == observedOriginal.count, count > 0, keys.count > count,
                      keys.prefix(count).allSatisfy({ $0.code == UInt16(kVK_Delete) && !$0.shift && !$0.option && $0.text == nil }) else {
                    decisionStatus = "Не подготовлено выделение проверенного слова"; return .pass
                }
                keys.replaceSubrange(0..<count, with: Array(repeating:
                    ReplacementKey(code: UInt16(kVK_LeftArrow), shift: true, text: nil), count: count))
            }
            guard (ProcessInfo.processInfo.systemUptime - started) < Self.pendingDecisionTimeout else { decisionStatus = "Слишком долгая проверка слова"; return .pass }
            guard !IsSecureEventInputEnabled(), NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
                decisionStatus = "Ввод / приложение изменилось перед заменой"; return .pass
            }
            if let opaqueContext {
                switch ReplacementPreflight.opaqueIdentityStatus(opaqueContext, pid: destinationPID) {
                case .current: break
                case .unavailable:
                    decisionStatus = "Ожидается подтверждение прежнего поля"
                    return .retryOpaque(opaqueContext)
                case .changed:
                    changedEditorWords += 1
                    decisionStatus = "Фокус непрозрачного редактора изменился перед заменой"; return .pass
                }
            }
            guard ensureDeliveryTap(to: destinationPID) else {
                decisionStatus = "Не удалось подтвердить доставку клавиш; текст не изменён"
                return .pass
            }
            let changesSource = replacementTable.id != currentID
            guard !changesSource || transition?.canPreserveAdditionalWindow != false else {
                decisionStatus = "Ожидается завершение предыдущей смены раскладки"; return .pass
            }
            guard pendingBoundary?.id == transactionID, permitted, !IsSecureEventInputEnabled(),
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == destinationPID,
                  InputSources.currentID() == currentID else {
                decisionStatus = "Приложение или раскладка изменились перед заменой"; return .pass
            }
            // This lower bound belongs to the temporary selection itself, not
            // to an earlier word boundary still waiting in the input queue.
            let switchStartedAt = DispatchTime.now().uptimeNanoseconds
            guard !changesSource || InputSources.selectID(replacementTable.id) else { decisionStatus = "Не удалось включить целевую раскладку"; return .pass }
            let sourceRollback = InputSourceRollback(previous: currentTable, temporary: replacementTable,
                                                     startedAt: switchStartedAt, destinationPID: destinationPID)
            let restoreSource: () -> Void = { [self] in
                if let restored = sourceRollback?.restore(preserving: transition,
                    currentSource: { InputSources.currentID() },
                    foregroundPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
                    selectPrevious: { InputSources.selectID(currentTable.id) },
                    restoredAt: { DispatchTime.now().uptimeNanoseconds }) {
                    transition = restored
                }
            }
            // AppKit/Qt can translate physical keys with the input source active
            // when the event is made, ignoring its overridden Unicode payload.
            // Create events only after selecting and confirming that source.
            guard InputSources.currentID() == replacementTable.id, var events = Self.events(for: keys) else {
                restoreSource()
                decisionStatus = "Целевая раскладка / события не готовы; текст не изменён"
                return .pass
            }
            // Submit/focus boundaries belong to the same ordered batch. Their
            // physical keyUp stays in the held FIFO and follows this fence.
            if !(isSpace || isPunctuation) {
                guard let originalBoundary = originalForPosting(boundaryEvent) else {
                    restoreSource()
                    decisionStatus = "Не создан исходный разделитель; текст не изменён"
                    return .pass
                }
                events.append(originalBoundary)
            }
            // The background result is a snapshot, not permission to edit a
            // later field in the same process. Revalidate it at the write edge.
            if let replacementContext,
               !ReplacementPreflight.isCurrent(replacementContext, original: observedOriginal, pid: destinationPID) {
                restoreSource()
                changedEditorWords += 1
                decisionStatus = "Фокус / текст изменился перед заменой"
                return .pass
            }
            if let opaqueContext {
                switch ReplacementPreflight.opaqueIdentityStatus(opaqueContext, pid: destinationPID) {
                case .current: break
                case .unavailable:
                    restoreSource()
                    decisionStatus = "Ожидается подтверждение прежнего поля"
                    return .retryOpaque(opaqueContext)
                case .changed:
                    restoreSource()
                    changedEditorWords += 1
                    decisionStatus = "Фокус непрозрачного редактора изменился перед заменой"
                    return .pass
                }
            }
            guard pendingBoundary?.id == transactionID, permitted, !IsSecureEventInputEnabled(),
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == destinationPID,
                  InputSources.currentID() == replacementTable.id,
                  ProcessInfo.processInfo.systemUptime - started < Self.pendingDecisionTimeout else {
                restoreSource()
                decisionStatus = "Контекст или срок ожидания изменился; текст не изменён"
                return .pass
            }
            guard let terminal = events.last, armDeliveryFence(terminal: terminal, to: destinationPID) else {
                restoreSource()
                decisionStatus = "Не подготовлена доставка клавиш; текст не изменён"
                return .pass
            }
            if let sourceRollback, let fence = deliveryFence {
                pendingSourceReturn = PendingSourceReturn(fenceID: fence.id, ticket: sourceRollback,
                    previous: currentTable)
            }
            // Transfer ownership before posting: the preflight watchdog can
            // no longer return a boundary already consumed by this batch.
            pendingBoundary = nil
            replayPID = destinationPID
            if replacesSelection, let replacementContext {
                recentSelectionProgress = ReplacementPreflight.SelectionProgress(
                    element: replacementContext.element, pid: destinationPID,
                    originalRange: NSRange(location: replacementContext.selection.location - observedOriginal.utf16.count,
                                           length: observedOriginal.utf16.count),
                    expiresAt: ProcessInfo.processInfo.systemUptime + Self.pendingReadTimeout)
            } else { recentSelectionProgress = nil }
            if isSpace || isPunctuation { physicalKeyReleases.replacedKeyDown(key) }
            else { noteForwardedOriginalKeyDown(boundaryEvent) }
            // All events and the fence exist before any deletion. No yield
            // between Backspace, replacement characters and the boundary.
            layout = correction.layout
            sourceID = replacementTable.id
            transition = QueuedLayoutTransition.committed(previous: currentTable, target: replacementTable,
                boundary: boundaryEvent.timestamp, selectedAt: DispatchTime.now().uptimeNanoseconds, preserving: transition)
            periodContinuation = nil
            if isEllipsis,
               let identity = opaqueContext ?? replacementContext.map({ ReplacementPreflight.OpaqueContext(element: $0.element, resolvedField: true) }) {
                periodSerial &+= 1
                periodContinuation = PeriodContinuation(id: periodSerial,
                    sequence: EllipsisContinuation(code: UInt16(clamping: key), modifierBits: Self.periodModifiers(boundaryEvent),
                                                   sourceID: replacementTable.id, destinationPID: destinationPID),
                    context: identity, selectionProgress: recentSelectionProgress,
                    expectedCaretBounds: replacementContext.flatMap {
                        let (start, underflow) = $0.selection.location.subtractingReportingOverflow(observedOriginal.utf16.count)
                        let (end, overflow) = start.addingReportingOverflow(replacementText.utf16.count)
                        guard !underflow, !overflow, start >= 0 else { return nil }
                        return start...max($0.selection.location, end)
                    })
            }
            for generated in events {
                trace("delivery-post", type: generated.type, event: generated)
                generated.postToPid(destinationPID)
            }
            if key == Int64(kVK_Tab) { buffer.reset(); invalidateFocus() }
            keyboardFallbacks += 1
            if replacesSelection { selectionKeyboardReplacements += 1 }
            if let replacementContext, !isAddressBoundary {
                observeReplacement(replacementContext, original: observedOriginal, replacement: replacementText, boundary: boundaryText, keyboard: true)
            }
            automaticCorrections += 1
            appCorrections += 1
            if isPunctuation { punctuationCorrections += 1 }
            decisionStatus = "События замены отправлены"
            lastReplacement = correction.layout == .russian ? "EN → RU" : "RU → EN"
            report("Замена клавиатурой: \(lastReplacement)")
            // Completion of a committed batch is owned by its delivery fence.
            // The original Enter/Tab was included exactly once above.
            return .committed
            }
            boundaryHeld = !passBoundary
            asynchronousBoundary = boundaryHeld
            return passBoundary
        }
        if key == Int64(kVK_Delete) { buffer.backspace(); return true }
        if [kVK_Tab, kVK_Return, kVK_ANSI_KeypadEnter, kVK_Escape, kVK_LeftArrow, kVK_RightArrow,
            kVK_UpArrow, kVK_DownArrow, kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown,
            kVK_ForwardDelete].contains(Int(key)) {
            buffer.reset(startOfWord: false)
            if key == Int64(kVK_Tab) { invalidateFocus() }
            if key == Int64(kVK_Return) || key == Int64(kVK_ANSI_KeypadEnter) { buffer.reset() }
            return true
        }
        guard let text else { buffer.reset(startOfWord: false); return true }
        receivedCharacters += 1
        buffer.append(text)
        return true
    }

    /// A continuation inserts one literal period; it never deletes or reads
    /// surrounding text. Reuse the same owned-boundary queue and delivery fence
    /// so a later key, cancellation or original keyUp cannot overtake it.
    private func continuePeriods(_ event: CGEvent, continuation: PeriodContinuation,
                                 table: KeyboardLayoutTable) -> Bool {
        let destinationPID = pid
        let context = continuation.context
        let started = ProcessInfo.processInfo.systemUptime
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        guard let period = table.replacement("."), !awaitingContext else {
            periodContinuation = nil
            return true
        }
        let pass = holdBoundary(event, pid: destinationPID, read: { cancellation, deadline, pinned in
            guard cancellation.isActive, ProcessInfo.processInfo.systemUptime < deadline else {
                return .changed("Истёк срок проверки продолжения многоточия")
            }
            if let pinned, pinned.resolvedField != context.resolvedField || !CFEqual(pinned.element, context.element) {
                return .changed("Изменилось поле продолжения многоточия")
            }
            let status = ReplacementPreflight.opaqueIdentityStatus(context, pid: destinationPID,
                budget: min(0.025, deadline - ProcessInfo.processInfo.systemUptime),
                previousSelection: continuation.selectionProgress, expectedCaretBounds: continuation.expectedCaretBounds)
            guard cancellation.isActive else { return .changed("Проверка отменена") }
            switch status {
            case .current, .unavailable:
                // A transient read grants nothing: completion checks this same
                // identity again, and can retry only inside the original bound.
                return .unavailable(context)
            case .changed: return .changed("Фокус изменился при продолжении многоточия")
            }
        }) { [self] result in
            var retained = false
            defer {
                longestDecisionMS = max(longestDecisionMS, (ProcessInfo.processInfo.systemUptime - started) * 1000)
                if !retained, periodContinuation?.id == continuation.id { periodContinuation = nil }
            }
            guard let transaction = pendingBoundary, periodContinuation?.id == continuation.id,
                  permitted, !awaitingContext, !IsSecureEventInputEnabled(), self.pid == destinationPID,
                  eligibleApplication()?.processIdentifier == destinationPID, InputSources.currentID() == table.id,
                  ProcessInfo.processInfo.systemUptime < transaction.decisionDeadline else {
                decisionStatus = "Контекст или срок проверки продолжения многоточия изменились"
                return .pass
            }
            switch result {
            case .changed(let reason): decisionStatus = reason; return .pass
            case .matches:
                decisionStatus = "Неожиданный результат проверки продолжения многоточия"
                return .pass
            case .unavailable(let current):
                guard current.resolvedField == context.resolvedField, CFEqual(current.element, context.element) else {
                    decisionStatus = "Поле продолжения многоточия изменилось"
                    return .pass
                }
            }
            guard let events = Self.events(for: [period]), let terminal = events.last,
                  ensureDeliveryTap(to: destinationPID) else {
                decisionStatus = "Не подготовлена доставка продолжения многоточия"
                return .pass
            }
            switch ReplacementPreflight.opaqueIdentityStatus(context, pid: destinationPID,
                previousSelection: continuation.selectionProgress, expectedCaretBounds: continuation.expectedCaretBounds) {
            case .current: break
            case .unavailable:
                if ProcessInfo.processInfo.systemUptime < transaction.decisionDeadline {
                    retained = true
                    return .retryOpaque(context)
                }
                decisionStatus = "Истёк срок проверки продолжения многоточия"
                return .pass
            case .changed:
                decisionStatus = "Фокус изменился при продолжении многоточия"
                return .pass
            }
            guard pendingBoundary?.id == transaction.id, periodContinuation?.id == continuation.id,
                  permitted, !awaitingContext, !IsSecureEventInputEnabled(),
                  eligibleApplication()?.processIdentifier == destinationPID, InputSources.currentID() == table.id,
                  ProcessInfo.processInfo.systemUptime < transaction.decisionDeadline,
                  armDeliveryFence(terminal: terminal, to: destinationPID) else {
                decisionStatus = "Контекст, срок или доставка продолжения многоточия изменились"
                return .pass
            }
            pendingBoundary = nil
            replayPID = destinationPID
            physicalKeyReleases.replacedKeyDown(key)
            // A transport ACK may precede application of the original word's
            // Shift+Left batch. A literal period creates no new selection and
            // cannot retire that batch's proof: the NEXT word needs the same
            // exact range/identity until its original, unchanged expiry.
            recentSelectionProgress = continuation.selectionProgress
            if let bounds = continuation.expectedCaretBounds, bounds.upperBound < Int.max {
                periodContinuation?.expectedCaretBounds = bounds.lowerBound...(bounds.upperBound + 1)
            }
            buffer.reset()
            retained = true
            for generated in events {
                trace("delivery-post", type: generated.type, event: generated)
                generated.postToPid(destinationPID)
            }
            decisionStatus = "Продолжение многоточия отправлено"
            return .committed
        }
        if pass { periodContinuation = nil }
        return pass
    }

    /// Do not synchronously query a text editor from the tap holding its next
    /// event. Its preceding key can still be waiting for that tap to return.
    private func holdBoundary(_ event: CGEvent, pid: pid_t, wordLength: Int = 0,
                              read: @escaping (ReplacementPreflight.Cancellation, TimeInterval, ReplacementPreflight.OpaqueContext?) -> ReplacementPreflight.Result,
                              complete: @escaping (ReplacementPreflight.Result) -> BoundaryCompletion) -> Bool {
        guard let copy = event.copy() else { return true }
        if let lease = replayLease {
            guard heldEvents.transfer(lease) != nil else { return true }
            replayLease = nil
        }
        pendingSerial &+= 1
        let serial = pendingSerial
        let createdAt = ProcessInfo.processInfo.systemUptime
        pendingBoundary = HeldBoundary(id: serial, pid: pid, event: copy, read: read,
            cancellation: ReplacementPreflight.Cancellation(), complete: complete,
            decisionDeadline: createdAt + Self.pendingReadTimeout)
        finalBoundaryResults.begin(id: serial, processID: pid, characterCount: wordLength)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pendingDecisionTimeout) { [weak self] in
            guard let self, self.pendingBoundary?.id == serial else { return }
            self.longestDecisionMS = max(self.longestDecisionMS, (ProcessInfo.processInfo.systemUptime - createdAt) * 1000)
            self.flushHeldInput(diagnosticOutcome: .timedOut,
                                diagnosticReason: "Редактор не ответил вовремя; исходные клавиши сохранены")
            self.decisionStatus = "Редактор не ответил вовремя; исходные клавиши сохранены"
        }
        startHeldProbe(serial: serial)
        return false
    }

    private func startHeldProbe(serial: UInt64) {
        // A boundary encountered during replay cannot examine text until all
        // preceding reposted letters crossed the destination's delivery tap.
        guard deliveryFence == nil, pendingBoundary?.id == serial,
              pendingBoundary?.probeStarted == false else { return }
        pendingBoundary?.probeStarted = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.002) { [weak self] in
            guard let self, let pending = self.pendingBoundary, pending.id == serial else { return }
            self.replacementProbeQueue.async { [weak self] in
                // Never inspect main-thread queue/generation state from this
                // worker. Canceled jobs leave the serial queue without another
                // AX read; an in-flight read stops at its next bounded step.
                guard pending.cancellation.isActive else { return }
                let result = pending.read(pending.cancellation, pending.decisionDeadline, pending.pinnedOpaqueContext)
                pending.cancellation.cancel()
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.tap != nil, let pending = self.pendingBoundary,
                          pending.id == serial else { return }
                    let completion = pending.complete(result)
                    self.trace("completed", type: pending.event.type, event: pending.event)
                    if case .committed = completion {
                        self.finalBoundaryResults.finish(id: serial, outcome: .posted, reason: self.decisionStatus)
                    }
                    // A committed replacement transferred ownership to its
                    // fence. Cancellation instead transferred it to the flush.
                    guard self.pendingBoundary?.id == serial else { return }
                    if case .retryOpaque(let context) = completion,
                       ProcessInfo.processInfo.systemUptime < pending.decisionDeadline {
                        // Keep this boundary and its exact first verified AX
                        // identity. No fresh field may be accepted by a retry.
                        // The worker already returned; give only the next read
                        // a new token, without extending the original deadline.
                        self.pendingBoundary?.cancellation.cancel()
                        self.pendingBoundary?.cancellation = ReplacementPreflight.Cancellation()
                        self.pendingBoundary?.pinnedOpaqueContext = context
                        self.pendingBoundary?.probeStarted = false
                        self.startHeldProbe(serial: serial)
                        return
                    }
                    if case .retryOpaque = completion {
                        self.decisionStatus = "Редактор не подтвердил прежнее поле до срока ожидания"
                        self.periodContinuation = nil
                    }
                    self.finalBoundaryResults.finish(id: serial, outcome: .preserved, reason: self.decisionStatus)
                    self.pendingBoundary = nil
                    self.replayPID = pending.pid
                    switch completion {
                    case .pass, .retryOpaque: self.postOriginal(pending.event, to: pending.pid)
                    case .committed: break
                    }
                    if self.deliveryFence == nil { self.scheduleDrain(serial: serial, destination: pending.pid) }
                }
            }
        }
    }

    private func scheduleDrain(serial: UInt64, destination: pid_t) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.002) { [weak self] in
            guard let self, self.tap != nil, self.pendingSerial == serial,
                  self.replayPID == destination else { return }
            self.drainHeldInput()
        }
    }

    private func drainHeldInput() {
        guard let destination = replayPID, pendingBoundary == nil, deliveryFence == nil else { return }
        let serial = pendingSerial
        while let lease = heldEvents.beginDelivery() {
            replayLease = lease
            let event = lease.event
            trace("replay", type: event.type, event: event)
            let pass = eligibleApplication()?.processIdentifier != destination || process(type: event.type, event: event)
            replayLease = nil
            // A cancellation already sent this event before its tail. A new
            // boundary owns it now. Neither path may send it a second time.
            guard let original = heldEvents.commit(lease) else { return }
            if pass { postOriginal(original, to: destination) }
            guard pendingSerial == serial, replayPID == destination else { return }
            let key = event.getIntegerValueField(.keyboardEventKeycode)
            if event.type == .keyDown, [Int64(kVK_Tab), Int64(kVK_Return), Int64(kVK_ANSI_KeypadEnter)].contains(key) {
                if deliveryFence == nil { scheduleDrain(serial: serial, destination: destination) }
                return
            }
        }
        // An empty FIFO is not an empty destination queue. New physical input
        // must still be held behind the final reposted original's fence.
        if deliveryFence == nil { replayPID = nil }
    }

    private func originalForPosting(_ event: CGEvent) -> CGEvent? {
        guard let copy = event.copy(), let source = replaySource else { return nil }
        let flags = event.flags
        source.keyboardType = UInt32(clamping: event.getIntegerValueField(.keyboardEventKeyboardType))
        copy.setSource(source)
        copy.flags = flags
        copy.setIntegerValueField(.eventSourceUserData, value: Self.ownEvent)
        return copy
    }

    /// Unlike preparing a boundary before preflight, these copies are committed
    /// to delivery. Account each down before filtering its following up in the
    /// same batch, using the original origin before it acquires our replay tag.
    private func originalForDelivery(_ event: CGEvent) -> CGEvent? {
        guard let copy = originalForPosting(event) else { return nil }
        restoreRepeatPress(copy, original: event)
        noteForwardedOriginalKeyDown(event)
        return copy
    }

    private func postOriginal(_ event: CGEvent, to destination: pid_t, tracked: Bool = true) {
        guard let copy = originalForDelivery(event) else { return }
        if tracked { _ = armDeliveryFence(terminal: copy, to: destination) }
        trace("post-original", type: copy.type, event: copy)
        copy.postToPid(destination)
        if copy.type == .keyDown, copy.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_Tab) {
            buffer.reset(); invalidateFocus()
        }
    }

    private func ensureDeliveryTap(to destination: pid_t) -> Bool {
        if deliveryPID == destination, let deliveryTap, CGEvent.tapIsEnabled(tap: deliveryTap) { return true }
        // Changing observer destinations is only legal between cohorts.
        guard deliveryFence == nil else { return false }
        detachDeliveryTap()
        let mask = [CGEventType.keyDown, .keyUp, .flagsChanged].reduce(CGEventMask(0)) {
            $0 | (CGEventMask(1) << $1.rawValue)
        }
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let owner = Unmanaged<AutoMonitor>.fromOpaque(context).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                owner.interruptedTaps += 1
                owner.releaseCancelledInputAfterFailure()
                owner.decisionStatus = "Подтверждение доставки прервано; повторной замены не было"
                if let tap = owner.deliveryTap { CGEvent.tapEnable(tap: tap, enable: true) }
            } else {
                owner.observeReplayedFocusChange(event)
                if let fixture = owner.fixture, fixture.alive,
                   owner.deliveryPID == fixture.process.processIdentifier,
                   event.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid()),
                   event.getIntegerValueField(.eventSourceUserData) == AutoMonitor.ownEvent || fixture.admits(event) {
                    if type == .keyDown { owner.tailKeyDowns += 1 }
                    else if type == .keyUp { owner.tailKeyUps += 1 }
                }
                owner.acknowledgeDelivery(event)
            }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreateForPid(pid: destination, place: .tailAppendEventTap,
                options: .listenOnly, eventsOfInterest: mask, callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { return false }
        deliveryTap = tap; deliverySource = runLoopSource; deliveryPID = destination
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return CGEvent.tapIsEnabled(tap: tap)
    }

    @discardableResult
    private func armDeliveryFence(terminal: CGEvent, to destination: pid_t) -> Bool {
        guard ensureDeliveryTap(to: destination) else { return false }
        deliverySerial &+= 1
        let serial = deliverySerial
        lastDeliveryTimestamp = max(DispatchTime.now().uptimeNanoseconds, lastDeliveryTimestamp &+ 1)
        terminal.timestamp = lastDeliveryTimestamp
        let fence = DeliveryFence(id: serial, pid: destination, timestamp: terminal.timestamp,
            type: terminal.type, key: terminal.getIntegerValueField(.keyboardEventKeycode),
            state: terminal.getIntegerValueField(.eventSourceStateID))
        deliveryFence = fence
        // This timer never resends committed events. If the destination stops
        // draining, preserve only originals still owned here and stop waiting.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
            guard let self, self.deliveryFence?.id == serial else { return }
            self.deliveryTimeouts += 1
            self.trace("delivery-timeout", type: terminal.type, event: terminal)
            self.decisionStatus = "Доставка клавиш не подтверждена; повторной замены не было"
            self.releaseCancelledInputAfterFailure()
        }
        return true
    }

    private func acknowledgeDelivery(_ event: CGEvent) {
        guard let fence = deliveryFence, deliveryPID == fence.pid, fence.matches(event) else { return }
        trace("delivery-ack", type: event.type, event: event)
        // Do not release physical input from inside the callback that is still
        // observing the terminal event. A newer batch invalidates this ACK.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.deliveryFence?.id == fence.id else { return }
            self.deliveryAcks += 1
            self.deliveryFence = nil
            self.manualConversionGate.noteInputHandoff(at: ProcessInfo.processInfo.systemUptime)
            guard self.tap != nil else { return }
            if self.pendingSourceReturn?.fenceID == fence.id {
                // The destination's tail tap sees the final keyUp before the
                // editor handles it. Keep later physical keys in our FIFO until
                // that editor has had a turn to apply the complete replacement.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) { [weak self] in
                    guard let self, self.tap != nil,
                          self.pendingSourceReturn?.fenceID == fence.id else { return }
                    self.finishSourceReturn(fenceID: fence.id)
                    self.resumeAfterDelivery(fence)
                }
                return
            }
            self.resumeAfterDelivery(fence)
        }
    }

    private func finishSourceReturn(fenceID: UInt64) {
        guard let pending = pendingSourceReturn, pending.fenceID == fenceID else { return }
        pendingSourceReturn = nil
        if let restored = pending.ticket.restore(preserving: transition,
            currentSource: { InputSources.currentID() },
            foregroundPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
            selectPrevious: { InputSources.selectID(pending.previous.id) },
            restoredAt: { DispatchTime.now().uptimeNanoseconds }) {
            transition = restored
            sourceID = pending.previous.id
            layout = InputSources.layout(forID: pending.previous.id)
            returnedInputSources += 1
        } else {
            skippedInputSourceReturns += 1
        }
    }

    private func resumeAfterDelivery(_ fence: DeliveryFence) {
        if cancelledInput != nil {
            _ = cancelledInput?.queue.destinationAcknowledged()
            drainCancelledInput()
            return
        }
        if let pending = pendingBoundary {
            startHeldProbe(serial: pending.id)
        } else {
            replayPID = fence.pid
            if [Int64(kVK_Tab), Int64(kVK_Return), Int64(kVK_ANSI_KeypadEnter)].contains(fence.key) {
                scheduleDrain(serial: pendingSerial, destination: fence.pid)
            } else {
                drainHeldInput()
            }
        }
    }

    private func detachDeliveryTap() {
        if let deliveryTap { CGEvent.tapEnable(tap: deliveryTap, enable: false); CFMachPortInvalidate(deliveryTap) }
        if let deliverySource { CFRunLoopRemoveSource(CFRunLoopGetMain(), deliverySource, .commonModes) }
        deliveryTap = nil; deliverySource = nil; deliveryPID = nil
    }

    private func flushHeldInput(interrupt: CGEvent? = nil,
                                diagnosticOutcome: BoundaryDecisionHistory.Outcome = .cancelled,
                                diagnosticReason: String = "Проверка отменена; исходные клавиши сохранены") {
        if let interrupt, interrupt.type == .keyDown,
           TypingShortcut.action(code: UInt16(clamping: interrupt.getIntegerValueField(.keyboardEventKeycode)),
               command: interrupt.flags.contains(.maskCommand), control: interrupt.flags.contains(.maskControl),
               option: interrupt.flags.contains(.maskAlternate), shift: interrupt.flags.contains(.maskShift),
               function: interrupt.flags.contains(.maskSecondaryFn)) == .inputSource {
            // A user's explicit source shortcut was captured after our word.
            // Deliver it against the source the user actually saw, rather than
            // silently restoring just before the shortcut reaches macOS.
            pendingSourceReturn = nil
        }
        recentSelectionProgress = nil
        let continuation = periodContinuation
        periodContinuation = nil
        if cancelledInput != nil {
            if let interrupt { _ = cancelledInput?.queue.enqueueInterrupt(interrupt) }
            return
        }
        guard let destination = pendingBoundary?.pid ?? deliveryFence?.pid ?? replayPID else { return }
        orderedCancellations += 1
        manualConversionGate.noteInputHandoff(at: ProcessInfo.processInfo.systemUptime)
        // Committed boundaries are no longer in pendingBoundary. Neither the
        // replacement nor an already-posted Enter can ever be replayed here.
        let events = pendingBoundary.map { [$0.event] } ?? []
        var queued = events + heldEvents.cancel()
        // These keys were captured before the interrupt. Reconcile stale TIS
        // payloads only while the original source transition still applies.
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == destination,
           let currentID = InputSources.currentID(), let table = keyboard.table(currentID) {
            var periods = permitted && !IsSecureEventInputEnabled() ? continuation?.sequence : nil
            let period = table.replacement(".")
            var prepared: [CGEvent] = []
            for event in queued {
                // Consume a committed third-dot up BEFORE preparing a fourth
                // down with the same physical code. Otherwise it could remove
                // the fourth dot's suppression bit when the queue drains.
                if consumeOriginalKeyUp(event) { continue }
                if event.type == .flagsChanged { periods = nil }
                if event.type == .keyDown {
                    let key = event.getIntegerValueField(.keyboardEventKeycode)
                    if var sequence = periods,
                       sequence.consume(code: UInt16(clamping: key), modifierBits: Self.periodModifiers(event),
                                        sourceID: currentID, destinationPID: destination),
                       let period, let pair = Self.events(for: [period]), InputSources.currentID() == currentID {
                        // Only already-captured punctuation inherits a committed
                        // run's meaning. Transfer one literal period at this FIFO
                        // position; cancellation never starts another correction.
                        periods = sequence
                        prepared.append(contentsOf: pair)
                        physicalKeyReleases.replacedKeyDown(key)
                        trace("period-cancel-preserved", type: event.type, event: event)
                        continue
                    }
                    periods = nil
                    _ = printableText(event, key: key, currentTable: table, currentID: currentID)
                    // This down is irrevocably assigned to cancellation delivery
                    // (or its fallback). Account now, before this FIFO consumes
                    // its up; merely held/undecided downs never reach this path.
                    noteForwardedOriginalKeyDown(event)
                }
                prepared.append(event)
            }
            queued = prepared
        }
        if let pending = pendingBoundary {
            finalBoundaryResults.finish(id: pending.id, outcome: diagnosticOutcome, reason: diagnosticReason)
        }
        pendingBoundary?.cancellation.cancel()
        pendingBoundary = nil; replayPID = nil; replayLease = nil
        pendingSerial &+= 1; cancellationSerial &+= 1
        buffer.reset(startOfWord: false); transition = nil
        var queue = OrderedInputCancellation(originals: queued, awaitingDestination: deliveryFence != nil)
        if let interrupt { _ = queue.enqueueInterrupt(interrupt) }
        cancelledInput = CancelledInput(id: cancellationSerial, pid: destination, queue: queue)
        drainCancelledInput()
    }

    /// Cancellation revokes editing immediately, not ownership of held input.
    /// Drain the old process first, then let macOS route the interrupt normally.
    private func drainCancelledInput() {
        guard pendingSourceReturn == nil else { return }
        guard let cancelled = cancelledInput else { return }
        if let originals = cancelledInput?.queue.takeDestinationBatch() {
            let events = originals.compactMap { event -> CGEvent? in
                if consumeOriginalKeyUp(event) { return nil }
                return originalForDelivery(event)
            }
            if let terminal = events.last {
                guard armDeliveryFence(terminal: terminal, to: cancelled.pid) else {
                    for event in events { event.postToPid(cancelled.pid) }
                    releaseCancelledInputAfterFailure()
                    return
                }
                for event in events { event.postToPid(cancelled.pid) }
                return
            }
            _ = cancelledInput?.queue.destinationAcknowledged()
        }
        guard let interrupts = cancelledInput?.queue.takeSessionBatch() else { return }
        let events = interrupts.compactMap { event -> CGEvent? in
            if consumeOriginalKeyUp(event) { return nil }
            return originalForDelivery(event)
        }
        guard let terminal = events.last else {
            _ = cancelledInput?.queue.sessionAcknowledged()
            if cancelledInput?.queue.phase == .finished { cancelledInput = nil }
            return
        }
        lastDeliveryTimestamp = max(DispatchTime.now().uptimeNanoseconds, lastDeliveryTimestamp &+ 1)
        terminal.timestamp = lastDeliveryTimestamp
        let fence = DeliveryFence(id: cancelled.id, pid: cancelled.pid, timestamp: terminal.timestamp,
            type: terminal.type, key: terminal.getIntegerValueField(.keyboardEventKeycode),
            state: terminal.getIntegerValueField(.eventSourceStateID))
        sessionFence = fence
        for event in events {
            postSessionOriginal(event)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
            guard let self, self.sessionFence?.timestamp == fence.timestamp else { return }
            self.deliveryTimeouts += 1
            self.releaseCancelledInputAfterFailure()
            self.decisionStatus = "Отмена замены: доставка ввода не подтверждена"
        }
    }

    private func postSessionOriginal(_ event: CGEvent) {
        // Both the ordered path and its fail-open fallback return these keys to
        // session routing. They may type in a new app before refreshContext()
        // adopts its PID, so record their boundary before the actual handoff.
        trackCancelledBoundary(event)
        if let fixture {
            // Test input never escapes the explicitly owned child editor.
            if fixture.alive { event.postToPid(fixture.process.processIdentifier) }
        } else {
            event.post(tap: .cgSessionEventTap)
        }
    }

    private func observeReplayedFocusChange(_ event: CGEvent) {
        guard event.getIntegerValueField(.eventSourceUserData) == Self.ownEvent,
              event.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid()) else { return }
        if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type) ||
            (event.type == .keyDown && event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_Tab)) {
            invalidateFocus()
        }
    }

    private func acknowledgeSessionDelivery(_ event: CGEvent) {
        guard let fence = sessionFence, fence.matches(event) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.sessionFence?.timestamp == fence.timestamp else { return }
            self.sessionFence = nil
            self.manualConversionGate.noteInputHandoff(at: ProcessInfo.processInfo.systemUptime)
            _ = self.cancelledInput?.queue.sessionAcknowledged()
            if self.cancelledInput?.queue.phase == .finished { self.cancelledInput = nil }
            else { self.drainCancelledInput() }
        }
    }

    private func trackCancelledBoundary(_ event: CGEvent) {
        if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type) {
            buffer.reset()
            sessionReplayBoundary.record(.focusNavigation)
            return
        }
        guard event.type == .keyDown else { return }
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        if let shortcut = TypingShortcut.action(code: UInt16(clamping: key), command: event.flags.contains(.maskCommand),
            control: event.flags.contains(.maskControl), option: event.flags.contains(.maskAlternate),
            shift: event.flags.contains(.maskShift), function: event.flags.contains(.maskSecondaryFn)) {
            shortcut.apply(to: &buffer)
            switch shortcut {
            case .inputSource: sessionReplayBoundary.record(.unchanged)
            case .selectAll: sessionReplayBoundary.record(.boundary)
            case .invalidate:
                let appSwitch = key == Int64(kVK_Tab) && event.flags.contains(.maskCommand) &&
                    !event.flags.contains(.maskControl) && !event.flags.contains(.maskAlternate)
                sessionReplayBoundary.record(appSwitch ? .focusNavigation : .unknownText)
            }
        } else if [Int64(kVK_Space), Int64(kVK_Return), Int64(kVK_Tab), Int64(kVK_ANSI_KeypadEnter)].contains(key) {
            buffer.reset()
            sessionReplayBoundary.record(.boundary)
        } else {
            buffer.reset(startOfWord: false)
            sessionReplayBoundary.record(.unknownText)
        }
    }

    /// Last-resort fail-open path for a disabled tap, shutdown or lost ACK.
    /// Never replay a committed replacement or anything already transferred.
    private func releaseCancelledInputAfterFailure() {
        // A disabled/missing tail tap cannot prove that the last generated
        // character was consumed. Unblock owned originals, but never switch
        // their source underneath an unacknowledged replacement batch.
        pendingSourceReturn = nil
        if cancelledInput == nil { flushHeldInput() }
        guard let cancelled = cancelledInput else {
            deliveryFence = nil
            return
        }
        let owned = cancelledInput?.queue.takeOwnedFallback()
        manualConversionGate.noteInputHandoff(at: ProcessInfo.processInfo.systemUptime)
        cancelledInput = nil; sessionFence = nil; deliveryFence = nil
        pendingSerial &+= 1; deliverySerial &+= 1
        for event in owned?.destination ?? [] {
            if consumeOriginalKeyUp(event) { continue }
            postOriginal(event, to: cancelled.pid, tracked: false)
        }
        for event in owned?.session ?? [] {
            if consumeOriginalKeyUp(event) { continue }
            if let copy = originalForDelivery(event) { postSessionOriginal(copy) }
        }
    }

    private func printableText(_ event: CGEvent, key: Int64, currentTable: KeyboardLayoutTable, currentID: String) -> String? {
        var chars = [UniChar](repeating: 0, count: 8)
        var length = 0
        event.keyboardGetUnicodeString(maxStringLength: chars.count, actualStringLength: &length, unicodeString: &chars)
        var text: String?
        if length == 1 { text = String(utf16CodeUnits: chars, count: length) }
        else if length == 0, (0...Int(UInt16.max)).contains(Int(key)) {
            text = currentTable.character(code: UInt16(key), shift: event.flags.contains(.maskShift),
                                           capsLock: event.flags.contains(.maskAlphaShift), option: event.flags.contains(.maskAlternate))
        } else { text = nil }
        if let value = text, let transition, (0...Int64(UInt16.max)).contains(key),
           let normalized = transition.normalized(value, code: UInt16(key), shift: event.flags.contains(.maskShift),
               capsLock: event.flags.contains(.maskAlphaShift), option: event.flags.contains(.maskAlternate),
               timestamp: event.timestamp, currentID: currentID,
               // CoreGraphics documents a source PID, not a guarantee that
               // physical input has PID zero. Use the same origin gate as the
               // receiver; tagged/private injected input was already excluded.
               systemEvent: fixture?.admits(event) == true || KeyboardEventOrigin.isSystem(
                    stateID: event.getIntegerValueField(.eventSourceStateID), userData: event.getIntegerValueField(.eventSourceUserData))) {
            let units = Array(normalized.utf16)
            event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            text = normalized; reconciledKeys += 1
        }
        return text
    }

    static func events(for keys: [ReplacementKey]) -> [CGEvent]? {
        guard let source = CGEventSource(stateID: .privateState) else { return nil }
        source.userData = ownEvent
        var events: [CGEvent] = []
        for key in keys {
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: key.code, keyDown: down) else { return nil }
                event.flags = (key.shift ? CGEventFlags.maskShift : []).union(key.option ? .maskAlternate : [])
                    .union(key.capsLock ? .maskAlphaShift : [])
                event.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
                event.setIntegerValueField(.eventSourceUserData, value: ownEvent)
                if let text = key.text {
                    let unicode = Array(text.utf16)
                    event.keyboardSetUnicodeString(stringLength: unicode.count, unicodeString: unicode)
                }
                events.append(event)
            }
        }
        return events
    }

    private func report(_ message: String) {
        // UI updates are outside the keyboard callback; never include the word.
        let session = monitorSession
        DispatchQueue.main.async { [weak self] in
            guard let self, self.monitorSession == session else { return }
            self.onResult?(message)
        }
    }

    private func observeReplacement(_ context: ReplacementPreflight.Context, original: String,
                                    replacement: String, boundary: String, keyboard: Bool) {
        let keys = receivedKeys, appPID = pid, generation = contextGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self, self.tap != nil, self.receivedKeys == keys, self.pid == appPID,
                  self.contextGeneration == generation else { return }
            let result = DirectWordReplacement.observe(context, original: original,
                replacement: replacement, boundary: boundary, pid: appPID)
            switch result {
            case .matches: if keyboard { self.confirmedKeyboardWrites += 1 }
            case .changed:
                self.lateEditorChanges += 1
                self.decisionStatus = "Редактор изменил результат после записи; повторной записи не было"
                self.report("Редактор изменил результат исправления")
            case .unavailable: break
            }
        }
    }

    private func invalidateFocus() {
        contextGeneration &+= 1; permission.begin(); focusResetPending = true; settlingSnapshots = 0
        transition = nil; recentSelectionProgress = nil; periodContinuation = nil
        // Mouse/Tab hasn't reached the editor while its tap callback is running.
        // Probe after returning, so a snapshot of the old field isn't cached.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.tap != nil else { return }
            self.refreshContext()
        }
    }
    private func eligibleApplication() -> NSRunningApplication? {
        guard !IsSecureEventInputEnabled(), let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !KeyboardSafety.passwordApp(app.bundleIdentifier ?? ""),
              !settings.excludesApp(app.bundleIdentifier ?? "") else { return nil }
        if let fixture, !fixture.alive || app.processIdentifier != fixture.process.processIdentifier { return nil }
        return app
    }
    private func refreshContext() {
        guard let app = eligibleApplication() else {
            contextStatus = IsSecureEventInputEnabled() ? "Защищённый ввод" : "Служебное окно / приложение исключено"
            contextGeneration &+= 1; permission.exclude(); cancel(); return
        }
        if pid != app.processIdentifier {
            detachObserver(); contextGeneration &+= 1
            pid = app.processIdentifier; application = AXUIElementCreateApplication(pid)
            adoptedActivationReceipt = activationReceipts.current(for: pid)?.sequence
            AXUIElementSetMessagingTimeout(application!, 0.01)
            var made: AXObserver?
            if AXObserverCreate(pid, { _, _, _, context in
                guard let context else { return }
                let owner = Unmanaged<AutoMonitor>.fromOpaque(context).takeUnretainedValue()
                owner.focusHints += 1; owner.refreshContext()
            }, &made) == .success, let made {
                observer = made
                AXObserverAddNotification(made, application!, kAXFocusedUIElementChangedNotification as CFString,
                                          Unmanaged.passUnretained(self).toOpaque())
                CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(made), .commonModes)
            }
            focused = nil; focusedRole = nil; focusedIdentity = nil
            buffer.reset(startOfWord: sessionReplayBoundary.startOfWordOnPIDChange())
            layout = nil; sourceID = nil; transition = nil; periodContinuation = nil
            permission.begin(); focusResetPending = true; settlingSnapshots = 0
            appKeys = 0; appSpaces = 0; appCorrections = 0; focusHints = 0; focusChanges = 0
            decisionStatus = "Ожидание ввода"
        }
        if fixture == nil { browserAccessibility?.prepare(app) }
        guard !probeBusy else { probeAgain = true; return }
        probeBusy = true; probeAgain = false
        let requestedPID = pid; let generation = contextGeneration
        focusQueue.async { [weak self] in
            let snapshot = FocusSnapshot.read(pid: requestedPID)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.probeBusy = false
                if self.tap != nil, self.pid == requestedPID, self.contextGeneration == generation,
                   NSWorkspace.shared.frontmostApplication?.processIdentifier == requestedPID {
                    self.apply(snapshot)
                }
                if self.probeAgain, self.tap != nil { self.refreshContext() }
            }
        }
    }
    private func apply(_ snapshot: FocusSnapshot) {
        guard eligibleApplication()?.processIdentifier == pid else {
            permission.exclude(); cancel(); return
        }
        longestFocusMS = max(longestFocusMS, snapshot.milliseconds)
        var allowed = permitted
        if let next = snapshot.element {
            let hadFocus = focused != nil
            let changed = focused.map { FocusTracking.changed(
                previousIdentity: focusedIdentity, nextIdentity: snapshot.identity,
                previousRole: focusedRole, nextRole: snapshot.role, sameElement: CFEqual($0, next)) } ?? true
            // Punctuation continuation belongs to one exact focus, even when
            // two opaque editors expose the same role/geometry in one process.
            if changed { periodContinuation = nil }
            let sameField = snapshot.identity != nil && snapshot.identity == focusedIdentity && snapshot.role == focusedRole
            // Geometry alone can identify two different editors at the same
            // position. Retain a held word across wrapper churn only when the
            // editor exposes the same stable AX identifier. The write edge
            // still verifies exact field and text ownership.
            let sameIdentifiedField = FocusTracking.sameIdentifiedField(
                previousIdentity: focusedIdentity, nextIdentity: snapshot.identity,
                previousRole: focusedRole, nextRole: snapshot.role)
            if FocusTracking.needsWholeWordProof(identityChanged: changed, sameLogicalField: sameField,
                sameIdentifiedField: sameIdentifiedField, previousRole: focusedRole, nextRole: snapshot.role) {
                buffer.requireVerifiedText()
            }
            let actualFieldChanged = hadFocus && FocusTracking.shouldCancelPending(
                previousRole: focusedRole, nextRole: snapshot.role,
                identityChanged: changed, sameLogicalField: sameIdentifiedField)
            if actualFieldChanged {
                recentSelectionProgress = nil
                if hasPendingInput { cancel() }
                // Equal geometry may be wrapper churn in the same editor;
                // retain that prefix only for exact whole-word verification.
                // A distinct identity starts a fresh word on the first key.
                if !sameField { buffer.reset() }
            }
            // Mouse/Tab/app changes already reset the stream. Transient AXWindow/
            // AXGroup wrappers are not a new text field on every typing hint.
            if FocusTracking.shouldReset(previousRole: focusedRole, nextRole: snapshot.role,
                                         identityChanged: changed, alreadyReset: focusResetPending, sameLogicalField: sameField) {
                buffer.invalidatePartialWord()
                transition = nil
            }
            if changed { focused = next; focusChanges += 1 }
            focusedRole = snapshot.role
            focusedIdentity = snapshot.identity
            if snapshot.role != nil || snapshot.subrole != nil || snapshot.protected != nil || snapshot.enabled != nil {
                allowed = KeyboardSafety.allowed(role: snapshot.role, subrole: snapshot.subrole,
                                                   protected: snapshot.protected, enabled: snapshot.enabled)
            } else if focusResetPending && !hadFocus { allowed = true }
            contextStatus = "Фокус: \(snapshot.role ?? "без роли") · \(allowed ? "ввод разрешён" : "ввод исключён")"
            // A probe immediately after Mouse/Tab may still describe the old
            // field. Don't erase the first new word when its delayed hint arrives.
            settlingSnapshots += 1
            if settlingSnapshots >= 2 && (!changed || sameField) { focusResetPending = false }
        } else {
            if focusResetPending && focused == nil { allowed = true }
            contextStatus = allowed ? "Фокус без ответа AX · клавиатура разрешена" : "AX недоступен · последнее поле исключено"
        }
        permission.resolve(allowed, buffer: &buffer)
        if !permitted { cancel() }
    }

    /// No deferred manual edit: its text/selection must belong to this request,
    /// not whatever the user focuses after an automatic input drain.
    func prepareManualConversion() -> Bool {
        let allowed = manualConversionGate.request(hasPendingInput: hasPendingInput,
                                                  at: ProcessInfo.processInfo.systemUptime)
        cancel()
        return allowed
    }
    func cancel() { flushHeldInput(); buffer.reset(startOfWord: false); layout = nil; sourceID = nil; transition = nil }
    private func detachObserver() {
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        observer = nil; application = nil
    }
    func stop() {
        monitorSession &+= 1
        contextGeneration &+= 1; probeAgain = false; focusResetPending = false; settlingSnapshots = 0
        cancel(); releaseCancelledInputAfterFailure(); pendingSourceReturn = nil
        permission.exclude(); physicalKeyReleases.reset()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil
        detachDeliveryTap()
        contextTimer?.invalidate(); contextTimer = nil
        detachObserver(); focused = nil; focusedIdentity = nil; pid = 0
        sessionReplayBoundary = SessionReplayBoundary()
        if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) }
        activation = nil
        adoptedActivationReceipt = nil; activationReceipts.clear()
    }
    deinit { stop() }
}
