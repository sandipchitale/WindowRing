import AppKit

/// Orchestrates one shortcut-driven session, which can hold up to two ring
/// layers: an inner window ring and an outer ring of applications. Only one is
/// ever on screen at a time — a plain tap of the shortcut leads with the window
/// ring, a ⌘-qualified tap leads with the app ring, and further taps swap
/// between them and then dismiss. Whichever ring is showing owns mouse and
/// keyboard selection; Escape (or a click outside) dismisses everything at
/// once.
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
        shortcut.onTrigger = { [weak self] qualifiers in
            let dockFirst = qualifiers.contains(.command)
            DispatchQueue.main.async { self?.handleShortcutTap(dockFirst: dockFirst) }
        }
        shortcut.onKeyDown = { [weak self] code, flags in
            self?.handleKeyDown(code, flags: flags) ?? false
        }
        shortcut.onScroll = { [weak self] steps in
            self?.handleScroll(steps: steps) ?? false
        }
        return shortcut
    }()

    /// The two ring layers of the current session, or nil when nothing is
    /// showing. Both are fully populated for the whole session; which one is
    /// on screen is `RingSessionState.isHidden`, so hiding a ring never
    /// discards its contents or its selection.
    private enum Layer { case windows, apps }
    private var session: RingSessionState?
    private var dockState: RingSessionState?

    private var mouseMonitor: Any?
    private var outsideClickMonitor: Any?
    /// Whether the app ring has already been shown during this session, so a
    /// tap with the window ring up can tell "not expanded yet" (show the app
    /// ring) from "already come back from it" (dismiss everything).
    private var dockRingWasShown = false
    private var dockLaunchURLs: [WindowIdentity: URL] = [:]
    private var windowFrame: NSRect = .zero

    /// The ring currently on screen, which owns mouse and keyboard selection.
    private var activeSession: RingSessionState? {
        if let dockState, !dockState.isHidden { return dockState }
        return session
    }

    private func ring(_ layer: Layer) -> RingSessionState? {
        layer == .windows ? session : dockState
    }

    /// Shows exactly one layer and hides the other. Routing every visibility
    /// change through here is what makes "only one ring at a time" true by
    /// construction, rather than something each caller has to remember to
    /// pair up.
    private func show(_ layer: Layer) {
        session?.isHidden = layer != .windows
        dockState?.isHidden = layer != .apps
        if layer == .apps { dockRingWasShown = true }
        debugLog("[WindowRing] show(\(layer))")
    }

    private func hasItems(_ layer: Layer) -> Bool {
        ring(layer)?.windows.isEmpty == false
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
            confirmSelectionSoon()
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
            // 1–9 jump straight to that item, counting clockwise from the
            // top, and confirm it.
            if let index = VirtualKey.digitIndex(for: code),
               let active = activeSession,
               active.windows.indices.contains(index) {
                active.selectedIndex = index
                confirmSelectionSoon()
                return true
            }
            endSession(activate: false)
            return false
        }
    }

    /// Confirms once the current event-tap callback has returned — see the
    /// note on `onTrigger` for why anything touching AX must not run inline.
    private func confirmSelectionSoon() {
        DispatchQueue.main.async { [weak self] in self?.confirmActiveSelection() }
    }

    /// Scroll rotates the selection: down is clockwise. Swallowed whenever a
    /// ring is up — including the sub-step scrolls that don't move the
    /// selection — so the view underneath doesn't scroll along with it.
    private func handleScroll(steps: Int) -> Bool {
        guard let active = activeSession, !active.windows.isEmpty else { return false }
        active.rotateSelection(by: steps)
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
        let outerBound = activeSession?.outerRadius ?? session.outerRadius
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

    /// Two entry points into the same session, differing only in which ring
    /// comes up first, and each stepping toward dismissal on every further tap.
    ///
    /// Plain tap — windows first:
    ///   nothing → window ring → app ring → back to window ring → dismissed.
    ///
    /// ⌘ tap — apps first:
    ///   nothing → app ring → app ring swapped for window ring → dismissed.
    ///
    /// Either way only one ring is ever on screen at a time.
    private func handleShortcutTap(dockFirst: Bool) {
        if session == nil {
            guard beginSession() else { return }
            // Lead with the requested ring, unless it has nothing in it.
            let leadWithApps = (dockFirst || !hasItems(.windows)) && hasItems(.apps)
            show(leadWithApps ? .apps : .windows)
            return
        }

        if activeSession === dockState {
            // The app ring hands back to the window ring. With no windows to
            // hand back to, that step would be a blank overlay, so skip it.
            if hasItems(.windows) {
                show(.windows)
            } else {
                endSession(activate: false)
            }
        } else if dockFirst || dockRingWasShown {
            // ⌘ means "start where the app ring already happened", so from the
            // window ring it's the end of the sequence either way.
            endSession(activate: false)
        } else {
            show(.apps)
        }
    }

    private func confirmActiveSelection() {
        if let dockState, !dockState.isHidden,
           let index = dockState.selectedIndex, dockState.windows.indices.contains(index) {
            let appInfo = dockState.windows[index]
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

    /// Builds the overlay and both ring states for a new session, both fully
    /// populated but hidden — the caller decides which one to show first.
    /// Returns false if there's nothing at all to show.
    private func beginSession() -> Bool {
        let pressPoint = NSEvent.mouseLocation

        let allWindows = WindowDiscovery.discoverWindows(
            includeMinimized: preferences.includeMinimized,
            includeHidden: preferences.includeHidden
        )
        let ordered = MRUOrdering(history: mruTracker.history).order(allWindows)
        let limited = Array(ordered.prefix(preferences.maxWindowCount))
        debugLog("[WindowRing] beginSession(): discovered \(allWindows.count) windows, showing \(limited.count) at \(pressPoint)")

        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pressPoint) }) ?? NSScreen.main else { return false }
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
        let dockApps = dockEntries.map(\.info)
        dockLaunchURLs = Dictionary(uniqueKeysWithValues: dockEntries.compactMap { entry in
            entry.launchURL.map { (entry.info.id, $0) }
        })
        // Nothing to show in either ring: don't flash an empty overlay.
        guard !limited.isEmpty || !dockApps.isEmpty else {
            debugLog("[WindowRing] beginSession(): no windows and no dock apps, nothing to show")
            return false
        }
        let dockThickness = RadialLayout.suggestedRadius(count: max(dockApps.count, 1), itemSize: itemSize, minRadius: 70, maxRadius: 130)
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
        // Both rings are populated now and stay that way for the session; only
        // `isHidden` changes afterwards. That's what lets either ring lead, and
        // either be hidden and brought back with its selection intact, without
        // resizing or recentring anything already on screen.
        let windowState = RingSessionState(windows: limited, centerInView: centerInView, innerRadius: 0, outerRadius: windowOuterRadius)
        let appState = RingSessionState(windows: dockApps, centerInView: centerInView, innerRadius: dockInnerRadius, outerRadius: dockOuterRadius)
        windowState.isHidden = true
        appState.isHidden = true
        session = windowState
        dockState = appState

        overlayWindow.presentSession(state: windowState, dockState: appState, frame: frame)

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

        // Scroll events are only tapped while a ring is on screen; see
        // GlobalShortcut.ringIsVisible.
        shortcut.ringIsVisible = true
        return true
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
        shortcut.ringIsVisible = false
        overlayWindow.dismiss()
        session = nil
        dockState = nil
        dockLaunchURLs = [:]
        dockRingWasShown = false

        if activate, let index = state.selectedIndex, state.windows.indices.contains(index) {
            WindowActivation.activate(state.windows[index])
        }
    }
}
