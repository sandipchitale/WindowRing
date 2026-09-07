import AppKit
import ApplicationServices

/// One individual on-screen window — the fundamental unit Window Ring shows
/// in the ring. Two windows of the same app are two separate WindowInfo
/// values, never merged.
struct WindowInfo: Identifiable {
    let id: WindowIdentity
    let axElement: AXUIElement
    let pid: pid_t
    let appName: String
    let icon: NSImage?
    let title: String
    let isMinimized: Bool
}

/// Wraps an AXUIElement so it can be used as stable, hashable window identity
/// across repeated AX queries and over the app's lifetime. AXUIElement is a
/// CFType supporting CFEqual/CFHash, so two references to the same underlying
/// window compare equal even when fetched via separate calls — no need for
/// the private `_AXUIElementGetWindow` → CGWindowID bridge that some window
/// managers use.
struct WindowIdentity: Hashable {
    let element: AXUIElement

    static func == (lhs: WindowIdentity, rhs: WindowIdentity) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(element))
    }
}
