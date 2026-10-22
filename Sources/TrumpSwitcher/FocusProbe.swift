import AppKit
import SwitcherCore

/// AXCopyMultiple succeeds even when individual attributes fail. Decode safety
/// fields before using their Swift casts: an AXError or a malformed Boolean is
/// not evidence that a field is unprotected/enabled.
struct FocusSafetyMetadata {
    let role: String
    let subrole: String?
    let protected: Bool?
    let enabled: Bool?
    enum Result { case allowed(FocusSafetyMetadata), unsafe, unavailable }

    static func decode(_ items: [Any]) -> Result {
        guard items.count == 4 else { return .unavailable }
        func missing(_ value: Any) -> AXError? {
            let raw = value as CFTypeRef
            guard CFGetTypeID(raw) == AXValueGetTypeID(), AXValueGetType(raw as! AXValue) == .axError else { return nil }
            var error = AXError.failure
            return AXValueGetValue(raw as! AXValue, .axError, &error) ? error : .failure
        }
        // An explicit protection/disabled response takes precedence over other
        // incomplete replies in the same snapshot.
        guard KeyboardSafety.allowed(role: items[0] as? String, subrole: items[1] as? String,
                                     protected: items[2] as? Bool, enabled: items[3] as? Bool) else { return .unsafe }
        for (index, item) in items.enumerated() {
            if let error = missing(item) {
                if error == .apiDisabled || error == .invalidUIElement { return .unsafe }
                guard index != 0, [.attributeUnsupported, .noValue, .notImplemented].contains(error) else { return .unavailable }
            } else if index < 2 {
                guard item is String else { return .unavailable }
            } else {
                guard CFGetTypeID(item as CFTypeRef) == CFBooleanGetTypeID() else { return .unavailable }
            }
        }
        guard let role = items[0] as? String, !role.isEmpty else { return .unavailable }
        return .allowed(FocusSafetyMetadata(role: role, subrole: items[1] as? String,
            protected: items[2] as? Bool, enabled: items[3] as? Bool))
    }
}

/// Normally runs on a serial worker; a first key can request a bounded safety
/// check if it arrives before a new-field probe finishes. Reads only
/// focus, role, protection and enabled metadata; never text/value/range attributes.
struct FocusSnapshot {
    let element: AXUIElement?
    let role: String?
    let subrole: String?
    let protected: Bool?
    let enabled: Bool?
    let identity: String?
    let milliseconds: Double
    static func read(pid: pid_t, budget: TimeInterval = 0.025) -> FocusSnapshot {
        let started = ProcessInfo.processInfo.systemUptime
        let deadline = started + max(0, min(0.025, budget))
        let application = AXUIElementCreateApplication(pid)
        ApplicationFocusBootstrap.prepare(application, budget: min(0.003, max(0, budget)))
        func prepare(_ node: AXUIElement) -> Bool {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            return remaining > 0 && AXUIElementSetMessagingTimeout(node, Float(min(0.005, remaining))) == .success
        }
        func focused(_ node: AXUIElement) -> AXUIElement? {
            guard prepare(node) else { return nil }
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(node, kAXFocusedUIElementAttribute as CFString, &value) == .success,
                  let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! AXUIElement)
        }
        var next = focused(application)
        for _ in 0..<4 {
            guard let node = next else { break }
            guard let child = focused(node), !CFEqual(node, child) else { break }
            next = child
        }
        var role: String?; var subrole: String?; var protected: Bool?; var enabled: Bool?; var identity: String?
        var verifiedMetadata = false
        if let next, prepare(next) {
            let names = [kAXRoleAttribute, kAXSubroleAttribute, "AXProtectedContent", kAXEnabledAttribute,
                         "AXIdentifier", kAXPositionAttribute, kAXSizeAttribute] as CFArray
            var values: CFArray?
            if AXUIElementCopyMultipleAttributeValues(next, names, [], &values) == .success,
               let values = values as? [Any], values.count == 7 {
                switch FocusSafetyMetadata.decode(Array(values.prefix(4))) {
                case .allowed(let metadata):
                    verifiedMetadata = true
                    role = metadata.role; subrole = metadata.subrole
                    protected = metadata.protected; enabled = metadata.enabled
                case .unsafe:
                    verifiedMetadata = true
                    // Preserve an explicit exclusion, including failed access
                    // after an element was invalidated, instead of casting it
                    // to four nil optionals and retaining permission to edit.
                    protected = true
                case .unavailable: break
                }
                if let identifier = values[4] as? String, !identifier.isEmpty {
                    identity = "\(role ?? "")/id/\(identifier)"
                } else {
                    // Browser/Qt AX object identities can change during typing.
                    // Position/width describe the same composer even as it grows.
                    let p = values[5] as CFTypeRef, s = values[6] as CFTypeRef
                    var point = CGPoint.zero, size = CGSize.zero
                    if CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID(),
                       AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size),
                       point.x.isFinite, point.y.isFinite, size.width.isFinite, size.width > 0 {
                        identity = "\(role ?? "")/rect/\(point.x)/\(point.y)/\(size.width)"
                    }
                }
            }
        }
        // Do not replace a previously pinned field with an incomplete metadata
        // snapshot. The caller can retain its last state while a fresh probe or
        // the stricter replacement preflight resolves this transient failure.
        return FocusSnapshot(element: verifiedMetadata ? next : nil, role: role, subrole: subrole, protected: protected, enabled: enabled, identity: identity,
                             milliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1000)
    }
}
