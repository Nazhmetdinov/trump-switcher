import ApplicationServices

/// Chromium's BrowserCrApplication enables native Accessibility APIs when an
/// assistive client first requests the application role. Focus-first queries
/// can otherwise fail indefinitely. Only metadata is read: no AX writes,
/// text reads, screen-reader settings, application activation or app-name list.
enum ApplicationFocusBootstrap {
    static func prepare(_ application: AXUIElement, budget: TimeInterval) {
        guard budget.isFinite, budget > 0,
              AXUIElementSetMessagingTimeout(application, Float(min(0.003, budget))) == .success else { return }
        var role: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(application, kAXRoleAttribute as CFString, &role)
        // An unsupported role is not a reason to reject another framework's
        // working focus API. All existing focus/protection checks still apply.
    }
}
