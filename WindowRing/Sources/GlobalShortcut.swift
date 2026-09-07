import AppKit
import CoreGraphics

/// Detects a "hold this combo of modifier keys, then release" gesture
/// system-wide, via a listen-only CGEventTap. `.listenOnly` means events are
/// only observed, never consumed or rewritten, so ⌘Tab and every other
/// shortcut in the system keep working exactly as before.
///
/// Requires Accessibility trust (`AXIsProcessTrusted()`); `start()` returns
/// false if the tap can't be created (permission not yet granted).
///
/// Known limitation: telling left vs. right modifier keys apart relies on
/// combining the flagsChanged event's keycode with the (side-agnostic)
/// CGEventFlags mask for that modifier family — a public-API-only heuristic
/// that is unambiguous for the single-key-per-family combos this app
/// supports (e.g. Right Option alone, or Control+Option), but could
/// misidentify state if a user held both the left and right key of the same
/// family at once. That combination isn't offered by the shortcut recorder.
final class GlobalShortcut {
    var combo: Set<CGKeyCode>
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var currentlyDown: Set<CGKeyCode> = []
    private var isActive = false

    init(combo: Set<CGKeyCode>) {
        self.combo = combo
    }

    @discardableResult
    func start() -> Bool {
        guard eventTap == nil else { return true }
        guard AXIsProcessTrusted() else {
            debugLog("[WindowRing] GlobalShortcut.start(): AXIsProcessTrusted() == false, aborting")
            return false
        }

        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { proxy, type, event, refcon in
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let refcon {
                        let shortcut = Unmanaged<GlobalShortcut>.fromOpaque(refcon).takeUnretainedValue()
                        if let tap = shortcut.eventTap {
                            CGEvent.tapEnable(tap: tap, enable: true)
                        }
                    }
                    return Unmanaged.passUnretained(event)
                }
                if let refcon {
                    let shortcut = Unmanaged<GlobalShortcut>.fromOpaque(refcon).takeUnretainedValue()
                    shortcut.handle(type: type, event: event)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            debugLog("[WindowRing] GlobalShortcut.start(): CGEvent.tapCreate returned nil (likely missing Input Monitoring permission)")
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        debugLog("[WindowRing] GlobalShortcut.start(): event tap created and enabled, combo=\(combo)")
        return true
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        currentlyDown.removeAll()
        isActive = false
    }

    private func handle(type: CGEventType, event: CGEvent) {
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

        switch type {
        case .flagsChanged:
            if isModifierPhysicallyDown(keyCode, flags: event.flags) {
                currentlyDown.insert(keyCode)
            } else {
                currentlyDown.remove(keyCode)
            }
        case .keyDown:
            currentlyDown.insert(keyCode)
        default:
            break
        }

        let comboSatisfied = !combo.isEmpty && combo.isSubset(of: currentlyDown)
        if comboSatisfied && !isActive {
            isActive = true
            debugLog("[WindowRing] GlobalShortcut: combo pressed, currentlyDown=\(currentlyDown)")
            onPress?()
        } else if !comboSatisfied && isActive {
            isActive = false
            debugLog("[WindowRing] GlobalShortcut: combo released")
            onRelease?()
        }
    }

    private func isModifierPhysicallyDown(_ keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        switch keyCode {
        case VirtualKey.optionLeft, VirtualKey.optionRight:
            return flags.contains(.maskAlternate)
        case VirtualKey.controlLeft, VirtualKey.controlRight:
            return flags.contains(.maskControl)
        case VirtualKey.commandLeft, VirtualKey.commandRight:
            return flags.contains(.maskCommand)
        case VirtualKey.shiftLeft, VirtualKey.shiftRight:
            return flags.contains(.maskShift)
        default:
            return false
        }
    }
}
