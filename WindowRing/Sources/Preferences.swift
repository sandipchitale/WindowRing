import Foundation
import CoreGraphics
import ServiceManagement


/// Minimal settings. Kept deliberately small per the product brief: shortcut,
/// two include/exclude toggles, a max count, and launch-at-login. Everything
/// but launch-at-login is UserDefaults-backed.
final class Preferences: ObservableObject {
    private enum Keys {
        static let shortcutKeyCodes = "shortcutKeyCodes"
        static let includeMinimized = "includeMinimized"
        static let includeHidden = "includeHidden"
        static let maxWindowCount = "maxWindowCount"
    }

    @Published var shortcutCombo: Set<CGKeyCode> {
        didSet {
            UserDefaults.standard.set(shortcutCombo.map { Int($0) }, forKey: Keys.shortcutKeyCodes)
        }
    }
    @Published var includeMinimized: Bool {
        didSet { UserDefaults.standard.set(includeMinimized, forKey: Keys.includeMinimized) }
    }
    @Published var includeHidden: Bool {
        didSet { UserDefaults.standard.set(includeHidden, forKey: Keys.includeHidden) }
    }
    @Published var maxWindowCount: Int {
        didSet { UserDefaults.standard.set(maxWindowCount, forKey: Keys.maxWindowCount) }
    }

    /// Deliberately *not* UserDefaults-backed: launchd owns this state, and a
    /// cached copy would drift the moment the user removes the app in System
    /// Settings → General → Login Items. The published property mirrors
    /// `SMAppService` and is re-read whenever the settings window appears.
    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                debugLog("[WindowRing] launchAtLogin set to \(launchAtLogin)")
            } catch {
                debugLog("[WindowRing] launchAtLogin \(launchAtLogin) failed: \(error.localizedDescription)")
                // Snap back so the toggle can never claim a state launchd
                // didn't actually accept.
                DispatchQueue.main.async { [weak self] in
                    self?.refreshLaunchAtLogin()
                }
            }
        }
    }

    /// Re-reads the real login-item state. Call when the settings UI appears,
    /// since the user can change it from System Settings behind our back.
    /// Assigning an unchanged value is already a no-op thanks to the guard in
    /// `didSet`, so there's no second check here.
    func refreshLaunchAtLogin() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    init() {
        let defaults = UserDefaults.standard
        if let saved = defaults.array(forKey: Keys.shortcutKeyCodes) as? [Int], !saved.isEmpty {
            shortcutCombo = Set(saved.map { CGKeyCode($0) })
        } else {
            shortcutCombo = [VirtualKey.optionRight]
        }
        includeMinimized = defaults.object(forKey: Keys.includeMinimized) as? Bool ?? true
        includeHidden = defaults.object(forKey: Keys.includeHidden) as? Bool ?? false
        maxWindowCount = defaults.object(forKey: Keys.maxWindowCount) as? Int ?? 8
        // Not read from SMAppService here: that's a synchronous round trip to
        // the service-management daemon, and this initializer runs on the
        // launch path. Nothing needs the real value until the settings window
        // appears, which calls refreshLaunchAtLogin() anyway.
        launchAtLogin = false
    }
}
