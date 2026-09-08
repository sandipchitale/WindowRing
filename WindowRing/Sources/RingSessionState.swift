import Combine
import CoreGraphics

/// Live state for one ring layer: window ring or dock/app ring. Both rings of
/// a session share one overlay/frame, so geometry (`centerInView`,
/// `innerRadius`, `outerRadius`) is fixed at construction time. Both are also
/// populated once, up front, and then shown or hidden via `isHidden` — no
/// resize, recentre, or reload is ever needed when the visible ring changes.
final class RingSessionState: ObservableObject {
    /// Where the ring is centred, in the overlay's own (y-down) coordinates.
    /// Always the overlay's midpoint — dragging moves the overlay itself, so
    /// this never changes and the ring can never be clipped by the panel edge.
    let centerInView: CGPoint
    let innerRadius: CGFloat
    let outerRadius: CGFloat
    @Published private(set) var windows: [WindowInfo]
    @Published var selectedIndex: Int?
    /// Whether this ring is currently off screen. Deliberately separate from
    /// `windows`: only one ring shows at a time, and hiding one must not
    /// destroy its contents or its selection, since it has to come back
    /// exactly as the user left it.
    @Published var isHidden = false

    /// Precomputed rather than derived on demand: it depends only on the item
    /// count and the fixed geometry, but is read on every mouse move, every
    /// scroll, and every SwiftUI body evaluation.
    private(set) var placements: [RadialLayout.Placement]

    init(windows: [WindowInfo], centerInView: CGPoint, innerRadius: CGFloat, outerRadius: CGFloat) {
        self.windows = windows
        self.centerInView = centerInView
        self.innerRadius = innerRadius
        self.outerRadius = outerRadius
        // Default-highlight the most-recently-used item so confirming without
        // pointing at anything still does something sensible.
        self.selectedIndex = windows.isEmpty ? nil : 0
        self.placements = RadialLayout.placements(count: windows.count, center: centerInView, radius: outerRadius)
    }

    /// Replaces the item list in place, preserving this same observed object
    /// identity.
    func reset(windows: [WindowInfo]) {
        self.windows = windows
        selectedIndex = windows.isEmpty ? nil : 0
        placements = RadialLayout.placements(count: windows.count, center: centerInView, radius: outerRadius)
    }

    func updateSelection(forGlobalMouse point: CGPoint, windowFrame: CGRect) {
        guard !windows.isEmpty else { return }
        let localPoint = RadialLayout.viewLocalPoint(fromGlobal: point, windowFrame: windowFrame)
        if let index = RadialLayout.nearestIndex(to: localPoint, center: centerInView, placements: placements) {
            selectedIndex = index
        }
    }

    func rotateSelection(clockwise: Bool) {
        rotateSelection(by: clockwise ? 1 : -1)
    }

    /// Moves the selection `steps` positions around the ring, negative being
    /// counter-clockwise, wrapping either way. Placements start at 12 o'clock
    /// and proceed clockwise by increasing index, so this is plain modular
    /// arithmetic — done in a single assignment so that a fast scroll flick
    /// publishes one change rather than one per step.
    func rotateSelection(by steps: Int) {
        guard !windows.isEmpty, steps != 0 else { return }
        let count = windows.count
        let current = selectedIndex ?? 0
        selectedIndex = ((current + steps) % count + count) % count
    }
}
