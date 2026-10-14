import AppKit

/// Accessibility notifications cover native editors and input sent directly to an app.
/// No text is retained. TextAccess checks the last character before reading a word.
final class FieldMonitor {
    private var observer: AXObserver?
    private var application: AXUIElement?
    private var field: AXUIElement?
    private var activation: NSObjectProtocol?
    private var pending: DispatchWorkItem?
    private(set) var changes = 0
    var makeAttempt: (() -> (() -> Void)?)?

    func start() {
        stop()
        attach()
        activation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.attach() }
    }

    private func detach() {
        pending?.cancel(); pending = nil
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil; application = nil; field = nil
    }

    private func attach() {
        detach()
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        var created: AXObserver?
        guard AXObserverCreate(app.processIdentifier, { _, _, notification, context in
            guard let context else { return }
            let owner = Unmanaged<FieldMonitor>.fromOpaque(context).takeUnretainedValue()
            if notification as String == kAXFocusedUIElementChangedNotification {
                owner.observeField()
            } else { owner.changed() }
        }, &created) == .success, let created else { return }
        observer = created
        application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application!, 0.2)
        AXObserverAddNotification(created, application!, kAXFocusedUIElementChangedNotification as CFString,
                                  Unmanaged.passUnretained(self).toOpaque())
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        observeField()
    }

    private func observeField() {
        pending?.cancel(); pending = nil
        guard let observer, let application else { return }
        if let field {
            AXObserverRemoveNotification(observer, field, kAXValueChangedNotification as CFString)
            AXObserverRemoveNotification(observer, field, kAXSelectedTextChangedNotification as CFString)
        }
        field = nil
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return }
        field = (raw as! AXUIElement)
        for name in [kAXValueChangedNotification, kAXSelectedTextChangedNotification] {
            AXObserverAddNotification(observer, field!, name as CFString, Unmanaged.passUnretained(self).toOpaque())
        }
    }

    private func changed() {
        changes += 1
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let attempt = self.makeAttempt?() else { return }
            attempt()
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    func stop() {
        detach()
        if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) }
        activation = nil
    }
    deinit { stop() }
}
