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

        // The CGEventTap can only be created once the process is Accessibility-
        // trusted; re-arm it the moment the user grants access, no relaunch needed.
        permissions.$isTrusted
            .filter { $0 }
            .sink { [weak self] _ in self?.ringController.startListeningForShortcut() }
            .store(in: &cancellables)
    }

    func openPreferences() {
        if preferencesWindow == nil {
            let view = PreferencesView(preferences: preferences, permissions: permissions) { [weak self] in
                self?.ringController.shortcutComboDidChange()
            }
            let window = NSWindow(
                contentRect: .zero,
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Window Ring Preferences"
            window.contentView = NSHostingView(rootView: view)
            window.center()
            window.isReleasedWhenClosed = false
            preferencesWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        preferencesWindow?.makeKeyAndOrderFront(nil)
    }
}
