import AppKit
import ApplicationServices

/// Tracks whether Window Ring is trusted for Accessibility, which is required
/// for everything that makes the ring work: reading window titles/minimized
/// state via AX, detecting the global shortcut hold/release via CGEventTap,
/// and raising/activating the selected window.
///
/// `AXIsProcessTrusted()` has no push notification, so this polls — letting
/// the Preferences UI and the shortcut listener react as soon as the user
/// grants access in System Settings, without requiring a relaunch.
final class PermissionsManager: ObservableObject {
    @Published private(set) var isTrusted: Bool = AXIsProcessTrusted()
    private var timer: Timer?

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        let trusted = AXIsProcessTrusted()
        if trusted != isTrusted {
            isTrusted = trusted
        }
    }

    /// Shows the system's own "Allow Accessibility access" prompt if not
    /// already trusted.
    func requestAccess() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options: CFDictionary = [promptKey: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }
}
