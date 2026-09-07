import SwiftUI
import AppKit

struct PreferencesView: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var permissions: PermissionsManager
    var onShortcutChanged: () -> Void

    @State private var isRecording = false

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch Window Ring at login", isOn: $preferences.launchAtLogin)
            }

            Section("Global Shortcut") {
                HStack {
                    Text("Tap:")
                    Text(isRecording ? "Press and release the new key(s)…" : comboDescription)
                        .help("Tap these keys — press and release with nothing else — to open the ring.")
                        .font(.system(.body, design: .monospaced))
                    Spacer()
                    Button(isRecording ? "Cancel" : "Change…") {
                        isRecording.toggle()
                    }
                }
                ShortcutRecorderRepresentable(isRecording: $isRecording) { combo in
                    preferences.shortcutCombo = combo
                    onShortcutChanged()
                }
                .frame(height: 1)
            }

            Section("Windows") {
                Toggle("Include minimized windows", isOn: $preferences.includeMinimized)
                Toggle("Include hidden applications", isOn: $preferences.includeHidden)
                Stepper("Max windows shown: \(preferences.maxWindowCount)", value: $preferences.maxWindowCount, in: 3...12)
            }

            Section("Permissions") {
                HStack {
                    Image(systemName: permissions.isTrusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(permissions.isTrusted ? .green : .orange)
                    Text(permissions.isTrusted ? "Accessibility access granted" : "Accessibility access required")
                    Spacer()
                    if !permissions.isTrusted {
                        Button("Open Settings…") { permissions.openAccessibilitySettings() }
                    }
                }
                Text("Window Ring needs Accessibility access to read window titles, detect the global shortcut, and activate the window you point at. It never records or transmits keystrokes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 440)
        // The user can remove the login item from System Settings without us
        // hearing about it, so never trust the cached value on reopen.
        .onAppear { preferences.refreshLaunchAtLogin() }
    }

    private var comboDescription: String {
        preferences.shortcutCombo
            .map { VirtualKey.name(for: $0) }
            .sorted()
            .joined(separator: " + ")
    }
}

/// Bridges an NSView that can become first responder and capture a
/// flagsChanged-based modifier combo, without needing any global permission —
/// this only observes events delivered to our own (key) preferences window.
private struct ShortcutRecorderRepresentable: NSViewRepresentable {
    @Binding var isRecording: Bool
    var onCapture: (Set<CGKeyCode>) -> Void

    func makeNSView(context: Context) -> RecorderNSView {
        let view = RecorderNSView()
        view.onCapture = { combo in
            onCapture(combo)
        }
        return view
    }

    func updateNSView(_ nsView: RecorderNSView, context: Context) {
        if isRecording {
            nsView.window?.makeFirstResponder(nsView)
        }
    }
}

final class RecorderNSView: NSView {
    var onCapture: ((Set<CGKeyCode>) -> Void)?
    private var down: Set<CGKeyCode> = []

    override var acceptsFirstResponder: Bool { true }

    override func flagsChanged(with event: NSEvent) {
        let code = CGKeyCode(event.keyCode)
        guard VirtualKey.isModifier(code) else { return }

        if event.modifierFlags.rawValue & VirtualKey.flagMask(for: code) != 0 {
            down.insert(code)
        } else if !down.isEmpty {
            onCapture?(down)
            down.removeAll()
        }
    }
}
