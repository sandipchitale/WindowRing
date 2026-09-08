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
    /// Modifiers that may be held *alongside* the combo without spoiling the
    /// tap. They don't open a different shortcut so much as qualify this one:
    /// which of them were held is reported to `onTrigger`, letting the same
    /// tap mean something slightly different (⌘ + the combo opens the app ring
    /// first). Everything not listed here still cancels the tap. Expressed as
    /// flags rather than keycodes because no caller cares which side of the
    /// keyboard the key was on.
    var qualifyingModifiers: NSEvent.ModifierFlags = .command
    /// The combo was tapped cleanly: pressed and released with nothing but
    /// `qualifyingModifiers` touched in between. The argument is whichever of
    /// those were held at any point during the hold.
    var onTrigger: ((NSEvent.ModifierFlags) -> Void)?
    /// A key went down. Return true to act on it *and* swallow it.
    var onKeyDown: ((CGKeyCode, NSEvent.ModifierFlags) -> Bool)?
    /// A scroll happened, already normalized to "steps clockwise" (negative =
    /// counter-clockwise). Return true to swallow it.
    var onScroll: ((Int) -> Bool)?
    /// The tap had to be torn down because the process is no longer allowed to
    /// own one — Accessibility was revoked, or the tap kept being disabled.
    /// Called on the main queue, after `stop()` has already run.
    var onTapTornDown: (() -> Void)?
    /// Whether a ring is currently on screen. Scroll is the one event class
    /// this tap has no use for otherwise, and a trackpad emits a continuous
    /// stream of them — so while no ring is showing they're rejected before
    /// anything is read off the event, rather than being decoded and offered
    /// to a handler that would only decline them.
    var ringIsVisible = false

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
    /// Which qualifying modifiers were held at any point during this hold.
    /// Accumulated rather than sampled at release, because the user may well
    /// let go of ⌘ a moment before the combo key itself.
    private var qualifiersDuringHold: NSEvent.ModifierFlags = []
    /// Accumulated scroll distance not yet spent on a selection step.
    private var scrollAccumulator = 0.0
    /// When the current burst of tap-disabled notifications began, and how
    /// many have arrived in it — see `handleTapDisabled`.
    private var reEnableBurstStart: CFAbsoluteTime = 0
    private var reEnableBurstCount = 0

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
                        shortcut.handleTapDisabled()
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

    /// macOS disabled the tap. Re-enabling is the right answer for the
    /// ordinary cause — the callback took too long once — but it is exactly
    /// the wrong answer when the reason is that Accessibility was revoked
    /// while the app was running.
    ///
    /// This tap is a blocking `.defaultTap` head-inserted into the session tap,
    /// so every keystroke and click in the system flows through it. Re-enabling
    /// one the process is no longer trusted to own puts it straight back in
    /// front of the whole HID stream only to be disabled again, and the loop
    /// that follows stalls the event stream on every input: the user's mouse
    /// and keyboard appear to stop working, system-wide, until Window Ring is
    /// quit. So a revoked grant tears the tap down for good instead — the
    /// 2-second trust poll in PermissionsManager re-creates it if the user
    /// grants access again.
    ///
    /// `AXIsProcessTrusted()` is a TCC round-trip and this runs inside the tap
    /// callback, where nothing slow may run. That's acceptable only because
    /// this branch fires on tap-disabled notifications, not on ordinary events.
    ///
    /// The count is a backstop for the same freeze arriving by another route:
    /// if the tap is disabled repeatedly in a short window while trust still
    /// reads as granted (TCC's answer can lag its own revocation), stop
    /// fighting the system and shut down rather than spin.
    private func handleTapDisabled() {
        guard AXIsProcessTrusted() else {
            debugLog("[WindowRing] GlobalShortcut: tap disabled and process is no longer trusted, tearing it down")
            tearDown()
            return
        }

        let now = CFAbsoluteTimeGetCurrent()
        if now - reEnableBurstStart > 5.0 {
            reEnableBurstStart = now
            reEnableBurstCount = 0
        }
        reEnableBurstCount += 1
        guard reEnableBurstCount <= 5 else {
            debugLog("[WindowRing] GlobalShortcut: tap disabled \(reEnableBurstCount) times in 5s, tearing it down")
            tearDown()
            return
        }

        guard let eventTap else { return }
        debugLog("[WindowRing] GlobalShortcut: tap was disabled, re-enabling")
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    /// Deferred to the main queue: `stop()` removes the run loop source the
    /// callback is running under, which must not happen inside the callback.
    private func tearDown() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.eventTap != nil else { return }
            self.stop()
            self.onTapTornDown?()
        }
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
        qualifiersDuringHold = []
        scrollAccumulator = 0
        reEnableBurstStart = 0
        reEnableBurstCount = 0
    }

    /// Returns true if the event was consumed and must not reach anyone else.
    /// Every keystroke, scroll and click in the system reaches this method, so
    /// each case does as little as possible before bailing out.
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .scrollWheel:
            guard ringIsVisible else { return false }
            return handleScroll(event)

        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            // ⌥-click, ⌥-drag and the like are legitimate uses of the modifier
            // that must not also fire the shortcut on release.
            holdIsClean = false
            return false

        case .keyDown:
            // Offer it to the ring first — Escape/Return/arrows/Tab/digits are
            // consumed while a ring is up, everything else falls through.
            let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            let flags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
            let consumed = onKeyDown?(keyCode, flags) ?? false
            // A combo is always modifiers only, which never produce keyDown,
            // so any key arriving here spoils the tap.
            holdIsClean = false
            return consumed

        case .flagsChanged:
            let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            if isModifierPhysicallyDown(keyCode, flags: event.flags) {
                modifiersDown.insert(keyCode)
                if let qualifier = qualifier(for: keyCode) {
                    if isHoldingCombo { qualifiersDuringHold.insert(qualifier) }
                } else if !combo.contains(keyCode) {
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
            // Any modifier already down that is neither part of the combo nor
            // an allowed qualifier (e.g. the user was already holding Shift)
            // makes this hold dirty from the start.
            var qualifiers: NSEvent.ModifierFlags = []
            var isClean = true
            for code in modifiersDown.subtracting(combo) {
                if let qualifier = qualifier(for: code) {
                    qualifiers.insert(qualifier)
                } else {
                    isClean = false
                }
            }
            holdIsClean = isClean
            qualifiersDuringHold = qualifiers
        } else if !satisfied && isHoldingCombo {
            isHoldingCombo = false
            if holdIsClean {
                debugLog("[WindowRing] GlobalShortcut: clean tap of \(combo), qualifiers=\(qualifiersDuringHold.rawValue)")
                onTrigger?(qualifiersDuringHold)
            } else {
                debugLog("[WindowRing] GlobalShortcut: hold was dirty, not triggering")
            }
            holdIsClean = false
            qualifiersDuringHold = []
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
        let steps = Int((scrollAccumulator / threshold).rounded(.towardZero))
        scrollAccumulator -= Double(steps) * threshold

        // Ask even for a zero-step scroll: if a ring is up we want to swallow
        // the whole gesture, not just the events that happen to cross a step
        // boundary, or the view underneath scrolls in fits and starts.
        return onScroll?(steps) ?? false
    }

    /// The qualifying modifier this keycode represents, or nil if it isn't one
    /// — collapsing left/right into a single family via the mapping VirtualKey
    /// already owns, so callers never deal in sides.
    private func qualifier(for keyCode: CGKeyCode) -> NSEvent.ModifierFlags? {
        let mask = VirtualKey.flagMask(for: keyCode)
        guard mask != 0 else { return nil }
        let flag = NSEvent.ModifierFlags(rawValue: mask)
        return qualifyingModifiers.contains(flag) ? flag : nil
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
