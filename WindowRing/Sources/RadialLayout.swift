import CoreGraphics

/// Pure geometry for the pie-menu ring: where each item sits around a fixed
/// center, and which item a given mouse point is pointing at. No AppKit/AX
/// dependency, so this is trivially testable and reusable regardless of how
/// many windows are being shown.
enum RadialLayout {
    struct Placement {
        let index: Int
        /// Radians, 0 = the positive-x direction in this coordinate space;
        /// placements start at the top (-π/2) and proceed clockwise.
        let angle: CGFloat
        /// Position relative to the same origin as `center`.
        let point: CGPoint
    }

    static func placements(count: Int, center: CGPoint, radius: CGFloat) -> [Placement] {
        guard count > 0 else { return [] }
        if count == 1 {
            return [Placement(index: 0, angle: -.pi / 2, point: CGPoint(x: center.x, y: center.y - radius))]
        }
        var result: [Placement] = []
        let step = (2 * CGFloat.pi) / CGFloat(count)
        for i in 0..<count {
            let angle = -CGFloat.pi / 2 + CGFloat(i) * step
            let point = CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
            result.append(Placement(index: i, angle: angle, point: point))
        }
        return result
    }

    /// Ring radius that grows with item count so icons don't overlap, clamped
    /// to a sensible min/max so the ring never gets absurdly small or huge.
    static func suggestedRadius(count: Int, itemSize: CGFloat, minRadius: CGFloat = 140, maxRadius: CGFloat = 320) -> CGFloat {
        guard count > 1 else { return minRadius }
        let neededCircumference = CGFloat(count) * (itemSize * 1.3)
        let radius = neededCircumference / (2 * CGFloat.pi)
        return min(max(radius, minRadius), maxRadius)
    }

    /// The placement whose angle is closest to the direction from `center` to
    /// `point`, or nil if `point` is within `deadZoneRadius` of `center` (so
    /// tiny jitter right at the press location doesn't flicker the selection).
    static func nearestIndex(to point: CGPoint, center: CGPoint, placements: [Placement], deadZoneRadius: CGFloat = 18) -> Int? {
        guard !placements.isEmpty else { return nil }
        let dx = point.x - center.x
        let dy = point.y - center.y
        guard sqrt(dx * dx + dy * dy) > deadZoneRadius else { return nil }

        let pointAngle = atan2(dy, dx)
        var bestIndex = 0
        var bestDelta = CGFloat.greatestFiniteMagnitude
        for placement in placements {
            // atan2 returns (-π, π] but placement angles run from -π/2 up to
            // nearly -π/2 + 2π, so the raw difference can exceed 2π. Reduce it
            // into [0, 2π) first: without that, `2π - delta` goes negative and
            // — being smaller than every real distance — makes those high-index
            // placements (the ones just counter-clockwise of 12 o'clock) win
            // unconditionally, which stole the whole north-west arc.
            var delta = abs(pointAngle - placement.angle).truncatingRemainder(dividingBy: 2 * .pi)
            if delta > .pi { delta = 2 * .pi - delta }
            if delta < bestDelta {
                bestDelta = delta
                bestIndex = placement.index
            }
        }
        return bestIndex
    }

    /// Converts a point in AppKit's global, y-up screen coordinate space into
    /// the y-down local coordinate space SwiftUI uses inside the overlay
    /// window's content view.
    static func viewLocalPoint(fromGlobal globalPoint: CGPoint, windowFrame: CGRect) -> CGPoint {
        CGPoint(
            x: globalPoint.x - windowFrame.origin.x,
            y: windowFrame.height - (globalPoint.y - windowFrame.origin.y)
        )
    }
}
