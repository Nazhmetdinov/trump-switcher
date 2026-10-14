import Foundation
import SwitcherCore

final class PreferencesStore {
    private let defaults: UserDefaults
    private let key = "localSettingsV1"
    private(set) var settings: CorrectionSettings
    private(set) var invalidSavedSettings = false
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.object(forKey: key) != nil {
            if let data = defaults.data(forKey: key), let decoded = CorrectionSettings.decode(data) { settings = decoded }
            else {
                settings = CorrectionSettings(); settings.automatic = false
                invalidSavedSettings = true
            }
        } else { settings = CorrectionSettings() }
    }
    func save(_ settings: CorrectionSettings) throws {
        let data = try JSONEncoder().encode(settings)
        guard CorrectionSettings.decode(data) != nil else { throw CocoaError(.coderInvalidValue) }
        if invalidSavedSettings, let original = defaults.object(forKey: key) {
            defaults.set(original, forKey: "localSettingsV1Recovery")
        }
        defaults.set(data, forKey: key)
        self.settings = settings
        invalidSavedSettings = false
    }
}
