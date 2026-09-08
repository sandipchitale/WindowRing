import AppKit
import SwiftUI
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    let preferences = Preferences()
    let permissions = PermissionsManager()
    private lazy var ringController = RingController(preferences: preferences)
    private var preferencesWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !permissions.isTrusted {
            permissions.requestAccess()
        }
        ringController.startListeningForShortcut()

        // The CGEventTap can only exist while the process is Accessibility-
        // trusted, and that can change in either direction while the app runs.
        // Granting re-arms the tap the moment it happens, no relaunch needed.
        // Revoking has to tear it down just as promptly: a blocking session tap
        // owned by a process TCC no longer trusts gets disabled by the system,
        // and an app that keeps putting it back stalls every keystroke and
        // click on the machine.
        permissions.$isTrusted
            .removeDuplicates()
            .sink { [weak self] trusted in
                guard let self else { return }
                if trusted {
                    self.ringController.startListeningForShortcut()
                } else {
                    self.ringController.stopListeningForShortcut()
                }
            }
            .store(in: &cancellables)
    }

    func openPreferences() {
        if preferencesWindow == nil {
            let view = PreferencesView(preferences: preferences, permissions: permissions) { [weak self] in
                self?.ringController.shortcutComboDidChange()
            }
            // Built from a hosting *controller* rather than by dropping an
            // NSHostingView into a zero-sized NSWindow. That older shape made
            // AppKit resize the window from .zero to the SwiftUI content's
            // fitting size from *inside* the layout pass
            // (`_setFrameCommon:…fromServer:` under `layoutIfNeeded`), and the
            // hosting view answered each resize by invalidating its safe-area
            // corner insets — which asked for another Update Constraints pass,
            // which resized again. AppKit runs that loop until it has done more
            // passes than the window has views and then throws NSGenericException,
            // so opening Preferences spun the main thread for over a second and
            // then aborted the app. A window that knows its size before it is
            // laid out never enters the loop.
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.styleMask = [.titled, .closable]
            window.title = "Window Ring Preferences"
            window.center()
            window.isReleasedWhenClosed = false
            preferencesWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        preferencesWindow?.makeKeyAndOrderFront(nil)
    }
}
