import Foundation

extension Prefs {
    static let autoUpdateCheckKey = "autoUpdateCheck"
    static let lastUpdateCheckKey = "lastUpdateCheck"          // Double, timeIntervalSince1970; 0 = never
    static let skippedUpdateVersionKey = "skippedUpdateVersion" // "" = none

    static func registerUpdateDefaults() {
        UserDefaults.standard.register(defaults: [autoUpdateCheckKey: true, lastUpdateCheckKey: 0.0, skippedUpdateVersionKey: ""])
    }

    static var lastUpdateCheck: Date? {
        let t = UserDefaults.standard.double(forKey: lastUpdateCheckKey)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }
}
