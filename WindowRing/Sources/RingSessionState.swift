import Combine
import CoreGraphics

/// Live state for one ring layer: window ring or dock/app ring. Both rings of
/// a session share one overlay/frame, so geometry (`centerInView`,
/// `innerRadius`, `outerRadius`) is fixed at construction time — only
/// `windows` and `selectedIndex` change afterward, which lets the dock ring
/// be created once (empty) up front and simply populated in place the moment
/// it's actually opened, with no resize/recenter of anything already showing.
final class RingSessionState: ObservableObject {
    let centerInView: CGPoint
    let innerRadius: CGFloat
    let outerRadius: CGFloat
    @Published private(set) var windows: [WindowInfo]
    @Published var selectedIndex: Int?

    init(windows: [WindowInfo], centerInView: CGPoint, innerRadius: CGFloat, outerRadius: CGFloat) {
        self.windows = windows
        self.centerInView = centerInView
        self.innerRadius = innerRadius
        self.outerRadius = outerRadius
        // Default-highlight the most-recently-used item so a quick tap-release
        // (no pointing at all) still does something sensible.
        self.selectedIndex = windows.isEmpty ? nil : 0
    }

    var placements: [RadialLayout.Placement] {
        RadialLayout.placements(count: windows.count, center: centerInView, radius: outerRadius)
    }

    /// Replaces the item list in place (e.g. populating the dock ring when it
    /// opens, or clearing it back to empty when it's dismissed), preserving
    /// this same observed object identity.
    func reset(windows: [WindowInfo]) {
        self.windows = windows
        selectedIndex = windows.isEmpty ? nil : 0
    }

    func updateSelection(forGlobalMouse point: CGPoint, windowFrame: CGRect) {
        guard !windows.isEmpty else { return }
        let localPoint = RadialLayout.viewLocalPoint(fromGlobal: point, windowFrame: windowFrame)
        if let index = RadialLayout.nearestIndex(to: localPoint, center: centerInView, placements: placements) {
            selectedIndex = index
        }
    }

    /// Moves the selection one step around the ring. Placements are laid out
    /// starting at 12 o'clock and proceeding clockwise by increasing index, so
    /// clockwise is `+1` and counter-clockwise is `-1`, both wrapping.
    func rotateSelection(clockwise: Bool) {
        guard !windows.isEmpty else { return }
        let current = selectedIndex ?? 0
        let delta = clockwise ? 1 : -1
        selectedIndex = (current + delta + windows.count) % windows.count
    }
}
