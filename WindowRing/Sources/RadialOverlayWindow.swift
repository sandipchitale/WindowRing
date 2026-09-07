import AppKit
import SwiftUI

/// The transient overlay panel the ring is drawn in.
///
/// The panel deliberately **never becomes key**. It used to call `makeKey()`
/// so it could receive keystrokes through `keyDown(with:)`, but that meant an
/// open ring swallowed the keyboard: anything typed went to the ring instead
/// of the document the user was working in. All ring keyboard handling now
/// goes through RingController's event tap instead, which can act on the keys
/// it wants and pass the rest straight through to the app underneath.
/// `.nonactivatingPanel` plus `acceptsFirstMouse` keeps clicks working without
/// activating Window Ring or pulling focus off the frontmost app. Hover
/// selection is driven by a global mouse-moved monitor owned by
/// RingController; a click on a ring confirms whatever's selected, and a click
/// outside every ring dismisses.
final class RadialOverlayWindow: NSPanel {
    /// A click landed somewhere in this panel's frame, at this window-local
    /// (AppKit y-up) point. RingController decides whether that point is
    /// actually on a ring (confirm) or in the panel's transparent margin
    /// around it (dismiss), since only it knows the current ring geometry.
    var onMouseDownAt: ((NSPoint) -> Void)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        ignoresMouseEvents = false
        alphaValue = 0
    }

    // Never take key status — see the type comment. Without this, merely
    // clicking the ring would pull the keyboard away from the frontmost app.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func mouseDown(with event: NSEvent) {
        onMouseDownAt?(event.locationInWindow)
    }

    func presentSession(state: RingSessionState, dockState: RingSessionState, frame: NSRect) {
        contentView = FirstMouseHostingView(rootView: RadialRingContainerView(state: state, dockState: dockState))
        setFrame(frame, display: true)
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            self.animator().alphaValue = 1
        }
    }

    func dismiss() {
        NSAnimationContext.runAnimationGroup(
            { context in
                context.duration = 0.08
                self.animator().alphaValue = 0
            },
            completionHandler: { [weak self] in
                self?.contentView = nil
                self?.orderOut(nil)
            }
        )
    }
}

/// Window Ring is never the active app while a ring is showing, so without
/// `acceptsFirstMouse` the user's first click would be spent activating the
/// panel instead of being delivered as a `mouseDown` — meaning click-to-
/// confirm would silently need two clicks.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
