import AppKit
import ApplicationServices

/// Activates a specific window: unminimizes it if needed, brings its owning
/// app forward, raises the exact AX window, and marks it as that app's
/// focused window — so activation always lands on the window the user
/// pointed at, not just "whichever window that app last had focused".
enum WindowActivation {
    static func activate(_ window: WindowInfo) {
        if window.isMinimized {
            AXUIElementSetAttributeValue(window.axElement, kAXMinimizedAttribute as CFString, false as CFTypeRef)
        }

        if let app = NSRunningApplication(processIdentifier: window.pid) {
            if app.isHidden {
                app.unhide()
            }
            app.activate(options: [.activateAllWindows])
        }

        AXUIElementPerformAction(window.axElement, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(
            AXUIElementCreateApplication(window.pid),
            kAXFocusedWindowAttribute as CFString,
            window.axElement as CFTypeRef
        )
    }
}
