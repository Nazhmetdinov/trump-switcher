import AppKit
import ServiceManagement

enum LaunchAtLoginState: Equatable {
    case off, on, needsApproval, unavailable
}

enum LaunchAtLogin {
    static func state() -> LaunchAtLoginState {
        state(for: SMAppService.mainApp.status)
    }

    static func state(for status: SMAppService.Status) -> LaunchAtLoginState {
        switch status {
        case .enabled: return .on
        // mainApp may report notFound before its first registration even for
        // an installed, signed app. Do not disable the only way to register it.
        case .notRegistered, .notFound: return .off
        case .requiresApproval: return .needsApproval
        @unknown default: return .unavailable
        }
    }

    static func setEnabled(_ enabled: Bool) throws {
        let current = state()
        if enabled && (current == .on || current == .needsApproval) { return }
        if !enabled && current == .off { return }
        if enabled { try SMAppService.mainApp.register() }
        else { try SMAppService.mainApp.unregister() }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
