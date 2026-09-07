import AppKit

/// Orchestrates one shortcut-driven session, which can hold up to two ring
/// layers: the window ring always shows first; a second press of the
/// shortcut while it's open promotes to a second, outer ring listing running
/// (Dock-visible) applications. Whichever ring is open last is "active" and
/// owns mouse/keyboard selection; the shortcut collapses the rings back one
/// at a time, while Escape (or a click outside) dismisses all of them at once.
final class RingController {
    private let preferences: Preferences
    private let mruTracker = WindowMRUTracker()
    private let overlayWindow = RadialOverlayWindow()

    private lazy var shortcut: GlobalShortcut = {
        let shortcut = GlobalShortcut(combo: preferences.shortcutCombo)
        shortcut.onPress = { [weak self] in self?.handleShortcutPress() }
        // Releasing the shortcut no longer dismisses anything: rings stay
        // open so they can be driven by keyboard (arrow keys / Tab / Return)
        // or the mouse. Only Escape (cancel) and Return/click (confirm) act.
        return shortcut
    }()

    private var mouseMonitor: Any?
    private var escapeMonitor: Any?
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
        overlayWindow.onEscape = { [weak self] in self?.endSession(activate: false) }
        overlayWindow.onConfirm = { [weak self] in self?.confirmActiveSelection() }
        overlayWindow.onRotateClockwise = { [weak self] in self?.activeSession?.rotateSelection(clockwise: true) }
        overlayWindow.onRotateCounterClockwise = { [weak self] in self?.activeSession?.rotateSelection(clockwise: false) }
        overlayWindow.onMouseDownAt = { [weak self] point in self?.handleMouseDown(atWindowPoint: point) }
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

        // Since rings now stay open after the shortcut is released, the
        // overlay panel can lose key-window status later (e.g. the user
        // clicks another app) and stop seeing Escape locally. A global
        // monitor guarantees Escape always works regardless of focus,
        // without needing Accessibility beyond what's already required for
        // the shortcut itself.
        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == VirtualKey.escape {
                self?.endSession(activate: false)
            }
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
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
        }
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
        }
        mouseMonitor = nil
        escapeMonitor = nil
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
