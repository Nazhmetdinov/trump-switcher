import AppKit

// A data-only URL shortcut works even before Gatekeeper permits the app to run.
// Give only the staged shortcut a recognizable icon; never modify the signed app.
let shortcut = URL(fileURLWithPath: CommandLine.arguments[1])
let expected = "[InternetShortcut]\nURL=x-apple.systempreferences:com.apple.preference.security?General\n"
guard try String(contentsOf: shortcut, encoding: .utf8) == expected else {
    fatalError("Unexpected installer shortcut destination")
}
guard let icon = NSImage(contentsOfFile: "/System/Applications/System Settings.app/Contents/Resources/Settings.icns") else {
    fatalError("System Settings icon is unavailable")
}
guard NSWorkspace.shared.setIcon(icon, forFile: shortcut.path, options: []) else {
    fatalError("Could not set the security shortcut icon")
}
