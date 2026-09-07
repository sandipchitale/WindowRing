import Foundation
import CoreGraphics

/// Minimal, UserDefaults-backed settings. Kept deliberately small per the
/// product brief: shortcut, two include/exclude toggles, and a max count.
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
    }
}
