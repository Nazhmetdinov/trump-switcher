import Foundation

public enum KeyboardSafety {
    public static func passwordApp(_ id: String) -> Bool {
        ["com.1password.", "com.agilebits.", "com.bitwarden.", "org.keepassxc.",
         "com.apple.keychainaccess", "com.apple.Passwords", "com.apple.loginwindow"].contains {
            id.lowercased().hasPrefix($0.lowercased())
        }
    }
    public static func allowed(role: String?, subrole: String?, protected: Bool?, enabled: Bool?) -> Bool {
        guard role != "AXSecureTextField", subrole != "AXSecureTextField", protected != true, enabled != false else { return false }
        let controls: Set<String> = ["AXButton", "AXCheckBox", "AXRadioButton", "AXSlider", "AXMenuItem",
                                    "AXMenu", "AXMenuBar", "AXOutline", "AXTable", "AXRow", "AXCell", "AXToolbar"]
        return !controls.contains(role ?? "")
    }
}
