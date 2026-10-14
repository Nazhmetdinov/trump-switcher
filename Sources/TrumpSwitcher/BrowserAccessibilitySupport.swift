import AppKit
import Carbon
import SwitcherCore

/// Negotiate browser Accessibility on a worker, ahead of typing. This changes
/// only the browser's assistive-API mode, never focus, text or selection.
final class BrowserAccessibilitySupport {
    private let queue = DispatchQueue(label: "local.trumpswitcher.browser-accessibility")
    private struct Entry {
        let app: NSRunningApplication
        let root: AXUIElement
        let lease: AccessibilityModeRequest.Lease
    }
    private var entries: [String: Entry] = [:]
    private var attempts: [String: (app: NSRunningApplication, count: Int, time: TimeInterval)] = [:]
    private var launchObserver: NSObjectProtocol?
    private var enabled = false
    private var session: UInt64 = 0
    private let statusLock = NSLock()
    private var preparedCount = 0
    var status: String {
        statusLock.lock(); defer { statusLock.unlock() }
        return "Режим доступности Chromium запрошен / уже включён: \(preparedCount) процессов"
    }

    func start(excluded: [String]) {
        let startedSession = queue.sync { session &+= 1; enabled = true; return session }
        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: nil
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  !KeyboardSafety.passwordApp(app.bundleIdentifier ?? ""),
                  !excluded.contains(where: { $0.caseInsensitiveCompare(app.bundleIdentifier ?? "") == .orderedSame }) else { return }
            self?.prepare(app, session: startedSession)
        }
        for app in NSWorkspace.shared.runningApplications {
            guard !KeyboardSafety.passwordApp(app.bundleIdentifier ?? ""),
                  !excluded.contains(where: { $0.caseInsensitiveCompare(app.bundleIdentifier ?? "") == .orderedSame }) else { continue }
            prepare(app, session: startedSession)
        }
    }
    func prepare(_ app: NSRunningApplication, session expectedSession: UInt64? = nil) {
        queue.async { [self] in
            guard enabled, expectedSession == nil || expectedSession == session else { return }
            entries = entries.filter { !$0.value.app.isTerminated }
            attempts = attempts.filter { !$0.value.app.isTerminated }
            statusLock.lock(); preparedCount = entries.count; statusLock.unlock()
            guard !app.isTerminated, app.processIdentifier > 0, AXIsProcessTrusted(), !IsSecureEventInputEnabled() else { return }
            let key = "\(app.processIdentifier):\(app.launchDate?.timeIntervalSince1970 ?? -1)"
            guard entries[key] == nil else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if let attempt = attempts[key], attempt.count >= 3 || now - attempt.time < 1 { return }
            guard let url = app.bundleURL, let bundle = Bundle(url: url),
                  let principal = bundle.object(forInfoDictionaryKey: "NSPrincipalClass") as? String,
                  ["BrowserCrApplication", "ChromeBrowserApp", "ChromeApplication", "AtomApplication", "ElectronApplication"].contains(principal) else { return }
            attempts[key] = (app, (attempts[key]?.count ?? 0) + 1, now)
            let root = AXUIElementCreateApplication(app.processIdentifier)
            ApplicationFocusBootstrap.prepare(root, budget: 0.003)
            guard AXUIElementSetMessagingTimeout(root, 0.01) == .success else { return }
            let lease = AccessibilityModeRequest.acquire(read: { attribute in
                var raw: CFTypeRef?
                guard AXUIElementCopyAttributeValue(root, attribute as CFString, &raw) == .success,
                      let raw, CFGetTypeID(raw) == CFBooleanGetTypeID() else { return nil }
                return CFBooleanGetValue(raw as! CFBoolean)
            }, enable: { attribute in
                guard !app.isTerminated, AXIsProcessTrusted(), !IsSecureEventInputEnabled() else { return false }
                return AXUIElementSetAttributeValue(root, attribute as CFString, kCFBooleanTrue) == .success
            })
            if let lease {
                entries[key] = Entry(app: app, root: root, lease: lease)
                statusLock.lock(); preparedCount = entries.count; statusLock.unlock()
            } else if (attempts[key]?.count ?? 3) < 3 {
                // A newly launched browser can announce itself before its AX
                // service is ready. Retry on this worker even in manual mode.
                let requestedSession = session
                queue.asyncAfter(deadline: .now() + 1) { [weak self] in
                    self?.prepare(app, session: requestedSession)
                }
            }
        }
    }
    func stop() {
        if let launchObserver { NSWorkspace.shared.notificationCenter.removeObserver(launchObserver) }
        launchObserver = nil
        queue.sync {
            enabled = false; session &+= 1
            for entry in entries.values where entry.lease.restoreDisabled && !entry.app.isTerminated {
                AXUIElementSetMessagingTimeout(entry.root, 0.003)
                var raw: CFTypeRef?
                if AXUIElementCopyAttributeValue(entry.root, entry.lease.attribute as CFString, &raw) == .success,
                   let raw, CFGetTypeID(raw) == CFBooleanGetTypeID(), CFBooleanGetValue(raw as! CFBoolean) {
                    _ = AXUIElementSetAttributeValue(entry.root, entry.lease.attribute as CFString, kCFBooleanFalse)
                }
            }
            entries.removeAll(); attempts.removeAll()
            statusLock.lock(); preparedCount = 0; statusLock.unlock()
        }
    }
}
