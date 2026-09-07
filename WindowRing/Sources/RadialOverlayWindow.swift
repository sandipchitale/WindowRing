import AppKit
import SwiftUI

/// The transient overlay panel the ring is drawn in.
///
/// `.nonactivatingPanel` lets it become key (so it can receive the Escape
/// keydown directly) and accept mouse clicks without activating Window Ring
/// or stealing focus from whatever app was frontmost — matching the "no
/// unnecessary focus stealing" requirement. Hover selection is still driven
/// by a global mouse-moved monitor owned by RingController; a click on a ring
/// confirms whatever's selected, and a click outside every ring dismisses.
final class RadialOverlayWindow: NSPanel {
    var onEscape: (() -> Void)?
    var onConfirm: (() -> Void)?
    var onRotateClockwise: (() -> Void)?
    var onRotateCounterClockwise: (() -> Void)?
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

    override var canBecomeKey: Bool { true }

    override func mouseDown(with event: NSEvent) {
        onMouseDownAt?(event.locationInWindow)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case VirtualKey.escape:
            onEscape?()
        case VirtualKey.returnKey, VirtualKey.keypadEnter:
            onConfirm?()
        case VirtualKey.rightArrow:
            onRotateClockwise?()
        case VirtualKey.leftArrow:
            onRotateCounterClockwise?()
        case VirtualKey.tab:
            if event.modifierFlags.contains(.shift) {
                onRotateCounterClockwise?()
            } else {
                onRotateClockwise?()
            }
        default:
            super.keyDown(with: event)
        }
    }

    func presentSession(state: RingSessionState, dockState: RingSessionState, frame: NSRect) {
        contentView = NSHostingView(rootView: RadialRingContainerView(state: state, dockState: dockState))
        setFrame(frame, display: true)
        alphaValue = 0
        orderFrontRegardless()
        makeKey()
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
