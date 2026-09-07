import SwiftUI

@main
struct WindowRingApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("Window Ring", systemImage: "circle.grid.3x3.fill") {
            Button("Preferences…") {
                appDelegate.openPreferences()
            }
            .keyboardShortcut(",")
            Divider()
            Button("Quit Window Ring") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}
