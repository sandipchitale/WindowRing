import AppKit
import ApplicationServices

/// Builds a most-recently-focused-window history by watching AX focus-change
/// notifications on whichever app is currently frontmost, re-registering its
/// AXObserver each time the frontmost app changes.
final class WindowMRUTracker {
    private(set) var history: [WindowIdentity] = []

    private var observer: AXObserver?
    private var observedPID: pid_t = -1
    private var activationObserver: NSObjectProtocol?

    init() {
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.observe(pid: app.processIdentifier)
        }
        if let frontmost = NSWorkspace.shared.frontmostApplication {
            observe(pid: frontmost.processIdentifier)
        }
    }

    deinit {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        stopObserving()
    }

    private func observe(pid: pid_t) {
        guard pid != observedPID else { return }
        stopObserving()
        observedPID = pid

        var newObserver: AXObserver?
        let callback: AXObserverCallback = { _, element, _, refcon in
            guard let refcon else { return }
            let tracker = Unmanaged<WindowMRUTracker>.fromOpaque(refcon).takeUnretainedValue()
            tracker.bump(element)
        }
        guard AXObserverCreate(pid, callback, &newObserver) == .success, let newObserver else { return }

        let axApp = AXUIElementCreateApplication(pid)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let addErr = AXObserverAddNotification(newObserver, axApp, kAXFocusedWindowChangedNotification as CFString, selfPtr)
        guard addErr == .success else { return }

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(newObserver), .defaultMode)
        observer = newObserver

        // Seed history with whatever window is already focused in this app,
        // so switching to a single-window app via ⌘Tab still counts as a use.
        var focused: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focused) == .success,
           let focusedWindow = focused {
            bump(focusedWindow as! AXUIElement)
        }
    }

    private func stopObserving() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        observedPID = -1
    }

    private func bump(_ element: AXUIElement) {
        let id = WindowIdentity(element: element)
        history.removeAll { $0 == id }
        history.insert(id, at: 0)
    }
}
