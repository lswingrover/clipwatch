import Foundation

// MARK: - Prefs: UserDefaults keys and defaults

enum Prefs {
    static let hotkeyKeyCode   = "hotkeyKeyCode"    // Int  (default 9 = V)
    static let hotkeyModifiers = "hotkeyModifiers"  // Int  (default ⌥⌘)
    static let menuItemCount   = "menuItemCount"    // Int  (default 10)
    static let retentionDays   = "retentionDays"    // Int  (default 365)
    static let screenFocusMode = "screenFocusMode"  // String "activeApp" | "cursor"
    static let excludedApps    = "excludedApps"     // [String] bundle IDs
    static let excludedURLs    = "excludedURLs"     // [String] domain/URL patterns
    static let secureMode      = "secureMode"       // Bool — require Touch ID to open panel
    static let unlockDuration  = "unlockDuration"   // Int  — seconds to stay unlocked (0=always ask, -1=session)
    static let launchAtLogin   = "launchAtLogin"    // Bool

    static let defaultExcludedApps: [String] = [
        "com.1password.1password",
        "com.agilebits.onepassword-osx",
        "com.agilebits.onepassword7",
        "com.agilebits.onepassword4",
        "com.bitwarden.desktop",
        "com.lastpass.LastPass",
    ]

    static func menuCount() -> Int {
        let v = UserDefaults.standard.integer(forKey: menuItemCount)
        return (v >= 5 && v <= 25) ? v : 10
    }

    static func hotkeyVirtualKey() -> Int {
        let v = UserDefaults.standard.integer(forKey: hotkeyKeyCode)
        return v > 0 ? v : 9  // default V
    }

    static func hotkeyModifierFlags() -> Int {
        let v = UserDefaults.standard.integer(forKey: hotkeyModifiers)
        // default: option (524288) + command (1048576) = 1572864
        return v > 0 ? v : 1572864
    }

    static func isSecureModeEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: secureMode)
    }

    /// Seconds to stay unlocked after a successful Touch ID authentication.
    /// 0 = authenticate every use; -1 = stay unlocked until app restarts.
    static func unlockDurationSeconds() -> Int {
        // UserDefaults returns 0 for missing keys, which is our "every use" default — no special casing needed.
        return UserDefaults.standard.integer(forKey: unlockDuration)
    }

    static func screenMode() -> String {
        let v = UserDefaults.standard.string(forKey: screenFocusMode) ?? ""
        return v.isEmpty ? "activeApp" : v
    }
}
