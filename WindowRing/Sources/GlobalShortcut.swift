import AppKit
import CoreGraphics

/// Detects a "tap this combo of modifier keys" gesture system-wide, and — only
/// while a ring is actually on screen — routes keystrokes and scroll events to
/// the ring, consuming the ones it acts on.
///
/// **Why tap-on-release rather than fire-on-press.** The default shortcut is
/// Right Option, which is also a dead-key modifier: ⌥e, ⌥u, ⌥3 and friends all
/// begin with exactly the keystroke that would open the ring. Firing the
/// moment the modifier goes down therefore popped the ring open every time the
/// user typed an accented character. Instead the combo is *armed* when it goes
/// fully down, disarmed the instant any other key or a mouse click arrives,
/// and only fires when the last combo key comes back up having stayed clean
/// the whole time. A tap opens the ring; ⌥e types é and the ring never appears.
///
/// **Why the tap consumes.** The tap is `.defaultTap` rather than
/// `.listenOnly`, but `onKeyDown`/`onScroll` return true — the signal to
/// swallow the event — only while a ring is showing and only for the keys the
/// ring itself handles. With no ring up, every event passes through untouched,
/// so ⌘Tab and every other system shortcut behave exactly as before. The
/// alternative, an `NSEvent` global monitor, cannot consume at all: Return
/// would confirm the ring *and* land in whatever app was underneath.
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
    /// The combo was tapped cleanly: pressed and released with nothing else
    /// touched in between.
    var onTrigger: (() -> Void)?
    /// A key went down. Return true to act on it *and* swallow it.
    var onKeyDown: ((CGKeyCode, NSEvent.ModifierFlags) -> Bool)?
    /// A scroll happened, already normalized to "steps clockwise" (negative =
    /// counter-clockwise). Return true to swallow it.
    var onScroll: ((Int) -> Bool)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// Modifier keys physically held right now. Only modifiers ever go in
    /// here — regular keys are tracked via `holdIsClean` instead, since the
    /// tap sees their keyDown but nothing removes them again.
    private var modifiersDown: Set<CGKeyCode> = []
    /// The full combo is currently held down.
    private var isHoldingCombo = false
    /// Nothing outside the combo has been pressed or clicked since this hold
    /// began. Cleared by any foreign key or mouse button; if it's still true
    /// when the combo is released, that release is a tap.
    private var holdIsClean = false
    /// Accumulated scroll distance not yet spent on a selection step.
    private var scrollAccumulator = 0.0

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

        let mask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.scrollWheel.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
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
                    if shortcut.handle(type: type, event: event) {
                        return nil // swallowed: the ring acted on it
                    }
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
        modifiersDown.removeAll()
        isHoldingCombo = false
        holdIsClean = false
        scrollAccumulator = 0
    }

    /// Returns true if the event was consumed and must not reach anyone else.
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

        switch type {
        case .scrollWheel:
            return handleScroll(event)

        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            // ⌥-click, ⌥-drag and the like are legitimate uses of the modifier
            // that must not also fire the shortcut on release.
            holdIsClean = false
            return false

        case .keyDown:
            // Offer it to the ring first — Escape/Return/arrows/Tab/digits are
            // consumed while a ring is up, everything else falls through.
            let flags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
            let consumed = onKeyDown?(keyCode, flags) ?? false
            if !combo.contains(keyCode) {
                holdIsClean = false
            }
            return consumed

        case .flagsChanged:
            if isModifierPhysicallyDown(keyCode, flags: event.flags) {
                modifiersDown.insert(keyCode)
                if !combo.contains(keyCode) {
                    holdIsClean = false
                }
            } else {
                modifiersDown.remove(keyCode)
            }
            updateHoldState()
            return false

        default:
            return false
        }
    }

    /// Arms on a clean press of the whole combo; fires on the release that
    /// ends a still-clean hold.
    private func updateHoldState() {
        let satisfied = !combo.isEmpty && combo.isSubset(of: modifiersDown)

        if satisfied && !isHoldingCombo {
            isHoldingCombo = true
            // Any modifier already down that isn't part of the combo (e.g. the
            // user was already holding Shift) makes this hold dirty from the
            // start.
            holdIsClean = modifiersDown.isSubset(of: combo)
        } else if !satisfied && isHoldingCombo {
            isHoldingCombo = false
            if holdIsClean {
                debugLog("[WindowRing] GlobalShortcut: clean tap of \(combo)")
                onTrigger?()
            } else {
                debugLog("[WindowRing] GlobalShortcut: hold was dirty, not triggering")
            }
            holdIsClean = false
        }
    }

    /// Converts a scroll event into whole selection steps. Trackpads emit a
    /// stream of small continuous deltas while a wheel emits discrete lines,
    /// so the two need very different thresholds; the leftover is carried in
    /// `scrollAccumulator` rather than discarded, which keeps slow scrolling
    /// from feeling dead.
    private func handleScroll(_ event: CGEvent) -> Bool {
        let isContinuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        let raw = isContinuous
            ? Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
            : Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
        guard raw != 0 else { return false }

        // Positive axis-1 delta means scrolling up; scrolling *down* should
        // advance clockwise, the same direction ↓/Tab moves.
        scrollAccumulator += -raw
        let threshold = isContinuous ? 24.0 : 1.0
        var steps = 0
        while scrollAccumulator >= threshold {
            scrollAccumulator -= threshold
            steps += 1
        }
        while scrollAccumulator <= -threshold {
            scrollAccumulator += threshold
            steps -= 1
        }

        // Ask even for a zero-step scroll: if a ring is up we want to swallow
        // the whole gesture, not just the events that happen to cross a step
        // boundary, or the view underneath scrolls in fits and starts.
        return onScroll?(steps) ?? false
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
