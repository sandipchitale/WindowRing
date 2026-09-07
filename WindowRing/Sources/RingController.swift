import AppKit

/// Orchestrates one shortcut-driven session, which can hold up to two ring
/// layers: the window ring always shows first; a second press of the
/// shortcut while it's open promotes to a second, outer ring listing running
/// (Dock-visible) applications. Whichever ring is open last is "active" and
/// owns mouse/keyboard selection; the shortcut collapses the rings back one
/// at a time, while Escape (or a click outside) dismisses all of them at once.
///
/// Keyboard and scroll input reach the rings through GlobalShortcut's event
/// tap rather than through the overlay panel, so the panel never has to take
/// key focus away from the app the user is actually working in.
final class RingController {
    private let preferences: Preferences
    private let mruTracker = WindowMRUTracker()
    private let overlayWindow = RadialOverlayWindow()

    private lazy var shortcut: GlobalShortcut = {
        let shortcut = GlobalShortcut(combo: preferences.shortcutCombo)
        // Fires on a clean *tap* of the combo, not on press — see
        // GlobalShortcut for why. Rings stay open afterwards, driven by the
        // keyboard (arrows / Tab / digits / Return), scroll, or the mouse.
        // Deferred, not called inline: this runs inside the CGEventTap
        // callback, and building a ring does a full AX sweep of every running
        // app. Block the tap long enough and macOS disables it outright
        // (kCGEventTapDisabledByTimeout), which would kill the shortcut until
        // the next re-enable. The same goes for confirm, which activates
        // windows over AX.
        shortcut.onTrigger = { [weak self] in
            DispatchQueue.main.async { self?.handleShortcutPress() }
        }
        shortcut.onKeyDown = { [weak self] code, flags in
            self?.handleKeyDown(code, flags: flags) ?? false
        }
        shortcut.onScroll = { [weak self] steps in
            self?.handleScroll(steps: steps) ?? false
        }
        return shortcut
    }()

    private var mouseMonitor: Any?
    private var outsideClickMonitor: Any?
    private var session: RingSessionState?
    private var dockSession: RingSessionState?
    private var pendingDockApps: [WindowInfo] = []
    /// Whether the dock ring has already been shown during this session, so a
    /// press with only the window ring up can tell "not expanded yet" (show
    /// the dock ring) from "already collapsed back" (dismiss everything).
    private var dockRingWasShown = false
    private var dockLaunchURLs: [WindowIdentity: URL] = [:]
    private var windowFrame: NSRect = .zero

    /// Whichever ring currently owns mouse/keyboard selection: the dock ring
    /// once it's open, otherwise the window ring.
    private var activeSession: RingSessionState? {
        dockSession ?? session
    }

    init(preferences: Preferences) {
        self.preferences = preferences
        overlayWindow.onMouseDownAt = { [weak self] point in self?.handleMouseDown(atWindowPoint: point) }
    }

    /// Every keystroke in the system passes through here. Returns true only
    /// for keys a visible ring actually acts on — everything else falls
    /// through to whatever app the user was working in, untouched.
    ///
    /// Any key that isn't part of the ring's own vocabulary dismisses the ring
    /// *and* passes through: starting to type simply gets the ring out of the
    /// way, rather than stranding it on screen or eating the keystroke.
    private func handleKeyDown(_ code: CGKeyCode, flags: NSEvent.ModifierFlags) -> Bool {
        guard session != nil else { return false }

        switch code {
        case VirtualKey.escape:
            endSession(activate: false)
            return true
        case VirtualKey.returnKey, VirtualKey.keypadEnter:
            deferred { $0.confirmActiveSelection() }
            return true
        case VirtualKey.rightArrow:
            activeSession?.rotateSelection(clockwise: true)
            return true
        case VirtualKey.leftArrow:
            activeSession?.rotateSelection(clockwise: false)
            return true
        case VirtualKey.tab:
            activeSession?.rotateSelection(clockwise: !flags.contains(.shift))
            return true
        default:
            // 1–9 jump straight to that item and confirm it, matching the
            // index badges drawn on the ring.
            if let index = VirtualKey.digitIndex(for: code),
               let active = activeSession,
               active.windows.indices.contains(index) {
                active.selectedIndex = index
                deferred { $0.confirmActiveSelection() }
                return true
            }
            endSession(activate: false)
            return false
        }
    }

    /// Runs `body` after the current event-tap callback has returned. See the
    /// note on `onTrigger` for why anything touching AX must not run inline.
    private func deferred(_ body: @escaping (RingController) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            body(self)
        }
    }

    /// Scroll rotates the selection: down/right is clockwise. Swallowed
    /// whenever a ring is up — including the sub-step scrolls that don't move
    /// the selection — so the view underneath doesn't scroll along with it.
    private func handleScroll(steps: Int) -> Bool {
        guard let active = activeSession, !active.windows.isEmpty else { return false }
        for _ in 0..<abs(steps) {
            active.rotateSelection(clockwise: steps > 0)
        }
        return true
    }

    /// A click inside the overlay's own frame: confirm if it landed within
    /// the outermost currently-open ring; otherwise it's a click "elsewhere"
    /// (the panel's transparent margin counts as elsewhere too), which hides
    /// every ring at once — unlike Escape, this doesn't peel one at a time.
    private func handleMouseDown(atWindowPoint point: NSPoint) {
        guard let session else { return }
        let localPoint = CGPoint(x: point.x, y: windowFrame.height - point.y)
        let dx = localPoint.x - session.centerInView.x
        let dy = localPoint.y - session.centerInView.y
        let distance = sqrt(dx * dx + dy * dy)
        let outerBound = dockSession?.outerRadius ?? session.outerRadius
        if distance <= outerBound {
            confirmActiveSelection()
        } else {
            endSession(activate: false)
        }
    }

    @discardableResult
    func startListeningForShortcut() -> Bool {
        shortcut.start()
    }

    func shortcutComboDidChange() {
        shortcut.stop()
        shortcut.combo = preferences.shortcutCombo
        shortcut.start()
    }

    /// The shortcut walks out and then back in: nothing → window ring →
    /// + dock ring → dock ring hidden → everything hidden.
    private func handleShortcutPress() {
        if session == nil {
            beginWindowRing()
        } else if dockSession != nil {
            hideDockRing()
        } else if dockRingWasShown {
            endSession(activate: false)
        } else {
            beginDockRing()
        }
    }

    private func hideDockRing() {
        dockSession?.reset(windows: [])
        dockSession = nil
        debugLog("[WindowRing] hideDockRing(): dock ring closed, window ring stays open")
    }

    private func confirmActiveSelection() {
        if let dockSession, let index = dockSession.selectedIndex, dockSession.windows.indices.contains(index) {
            let appInfo = dockSession.windows[index]
            if appInfo.pid > 0, let app = NSRunningApplication(processIdentifier: appInfo.pid) {
                if app.isHidden { app.unhide() }
                app.activate(options: [.activateAllWindows])
            } else if let url = dockLaunchURLs[appInfo.id] {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }
            endSession(activate: false)
        } else {
            endSession(activate: true)
        }
    }

    private func beginWindowRing() {
        let pressPoint = NSEvent.mouseLocation

        let allWindows = WindowDiscovery.discoverWindows(
            includeMinimized: preferences.includeMinimized,
            includeHidden: preferences.includeHidden
        )
        let ordered = MRUOrdering(history: mruTracker.history).order(allWindows)
        let limited = Array(ordered.prefix(preferences.maxWindowCount))
        debugLog("[WindowRing] beginWindowRing(): discovered \(allWindows.count) windows, showing \(limited.count) at \(pressPoint)")
        guard !limited.isEmpty else {
            debugLog("[WindowRing] beginWindowRing(): no eligible windows, ring will not show")
            return
        }

        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pressPoint) }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame

        let itemSize: CGFloat = 64
        let windowRadius = RadialLayout.suggestedRadius(count: limited.count, itemSize: itemSize, minRadius: 90, maxRadius: 170)
        let windowOuterRadius = windowRadius + 36

        // Precompute the dock ring's geometry (and app list) up front, using
        // the same MRU order, so the overlay's frame is sized correctly for
        // it from the start — no resize/recenter is ever needed when it's
        // later opened, it just gets populated in place.
        let gap: CGFloat = 12
        let dockEntries = DockDiscovery.discoverDockApps()
        pendingDockApps = dockEntries.map(\.info)
        dockLaunchURLs = Dictionary(uniqueKeysWithValues: dockEntries.compactMap { entry in
            entry.launchURL.map { (entry.info.id, $0) }
        })
        let dockThickness = RadialLayout.suggestedRadius(count: max(pendingDockApps.count, 1), itemSize: itemSize, minRadius: 70, maxRadius: 130)
        let dockInnerRadius = windowOuterRadius + gap
        let dockOuterRadius = dockInnerRadius + dockThickness

        let margin: CGFloat = itemSize + 40
        let side = (dockOuterRadius + margin) * 2

        var origin = NSPoint(x: pressPoint.x - side / 2, y: pressPoint.y - side / 2)
        origin.x = min(max(origin.x, visible.minX), max(visible.minX, visible.maxX - side))
        origin.y = min(max(origin.y, visible.minY), max(visible.minY, visible.maxY - side))
        let frame = NSRect(origin: origin, size: NSSize(width: side, height: side))
        windowFrame = frame

        let centerInView = RadialLayout.viewLocalPoint(fromGlobal: pressPoint, windowFrame: frame)
        let windowState = RingSessionState(windows: limited, centerInView: centerInView, innerRadius: 0, outerRadius: windowOuterRadius)
        let dockState = RingSessionState(windows: [], centerInView: centerInView, innerRadius: dockInnerRadius, outerRadius: dockOuterRadius)
        session = windowState

        overlayWindow.presentSession(state: windowState, dockState: dockState, frame: frame)

        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            guard let self else { return }
            self.activeSession?.updateSelection(forGlobalMouse: NSEvent.mouseLocation, windowFrame: self.windowFrame)
        }

        // A click anywhere outside the overlay's own frame entirely (another
        // app's window, the desktop) hides every ring at once, same as a
        // click landing inside the frame but outside every ring's disc.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.endSession(activate: false)
        }

        // Hold onto the (empty-for-now) dock session so a second press can
        // just populate it in place.
        self.dockSessionPlaceholder = dockState
    }

    /// The dock ring's session object, created empty alongside the window
    /// ring so its geometry never needs to change — `beginDockRing()` just
    /// populates it.
    private var dockSessionPlaceholder: RingSessionState?

    private func beginDockRing() {
        guard let dockState = dockSessionPlaceholder else { return }
        dockState.reset(windows: pendingDockApps)
        dockSession = dockState
        dockRingWasShown = true
        debugLog("[WindowRing] beginDockRing(): showing \(pendingDockApps.count) dock apps")
    }

    private func endSession(activate: Bool) {
        guard let state = session else { return }
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
        }
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
        }
        mouseMonitor = nil
        outsideClickMonitor = nil
        overlayWindow.dismiss()
        session = nil
        dockSession = nil
        dockSessionPlaceholder = nil
        pendingDockApps = []
        dockLaunchURLs = [:]
        dockRingWasShown = false

        if activate, let index = state.selectedIndex, state.windows.indices.contains(index) {
            WindowActivation.activate(state.windows[index])
        }
    }
}
