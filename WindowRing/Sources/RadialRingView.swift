import SwiftUI

/// Hosts both ring layers — the window ring (inner) and the dock/app ring
/// (outer, empty until opened) — plus one shared center label that always
/// reflects whichever ring currently owns the selection.
struct RadialRingContainerView: View {
    @ObservedObject var state: RingSessionState
    @ObservedObject var dockState: RingSessionState

    /// The dock ring, once opened, owns all selection feedback; the window
    /// ring keeps its own last selection underneath but is no longer "live".
    private var activeState: RingSessionState {
        dockState.windows.isEmpty ? state : dockState
    }

    var body: some View {
        ZStack {
            RadialRingLayer(state: state)
            RadialRingLayer(state: dockState, highlightSpansFullBand: true)
            centerLabel
        }
        .transition(.opacity.combined(with: .scale(scale: 0.92)))
    }

    /// The active ring's selected item title, shown once in the hub rather
    /// than next to every icon.
    @ViewBuilder
    private var centerLabel: some View {
        if let selectedIndex = activeState.selectedIndex, activeState.windows.indices.contains(selectedIndex) {
            Text(activeState.windows[selectedIndex].title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(maxWidth: 140)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.black.opacity(0.8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(Color.white.opacity(0.9), lineWidth: 1)
                        )
                )
                .position(state.centerInView)
                .animation(.easeInOut(duration: 0.12), value: activeState.selectedIndex)
        } else {
            Circle()
                .fill(Color.white.opacity(0.85))
                .frame(width: 8, height: 8)
                .position(state.centerInView)
        }
    }
}

/// One ring's wedges + icons, between `state.innerRadius` and
/// `state.outerRadius`. Renders nothing when `state.windows` is empty, which
/// is how the dock ring stays invisible until it's actually populated.
private struct RadialRingLayer: View {
    @ObservedObject var state: RingSessionState
    /// When true, the selection-feedback wedge spans this ring's full radial
    /// thickness (edge to edge) instead of just an inset outer band — used
    /// for the dock ring, whose entire width is the "button".
    var highlightSpansFullBand: Bool = false

    private var wedgeHalfStep: CGFloat {
        state.windows.count > 1 ? (.pi / CGFloat(state.windows.count)) : .pi
    }

    /// The selection-feedback wedge reaches this ring's outer edge; unless
    /// `highlightSpansFullBand`, it starts well clear of the inner edge too,
    /// so it reads as an outer highlighted band rather than a full pie slice.
    private var highlightInnerRadius: CGFloat {
        highlightSpansFullBand ? state.innerRadius : state.innerRadius + (state.outerRadius - state.innerRadius) * 0.35
    }

    private var highlightOuterRadius: CGFloat {
        state.outerRadius
    }

    /// Icons sit at the radial midpoint of the highlight band, so each icon
    /// reads as centered within its own selection wedge.
    private var iconRadius: CGFloat {
        (highlightInnerRadius + highlightOuterRadius) / 2
    }

    private func iconPoint(forAngle angle: CGFloat) -> CGPoint {
        CGPoint(
            x: state.centerInView.x + iconRadius * cos(angle),
            y: state.centerInView.y + iconRadius * sin(angle)
        )
    }

    var body: some View {
        if state.windows.isEmpty {
            EmptyView()
        } else {
            let placements = state.placements
            ZStack {
                AnnulusShape(center: state.centerInView, innerRadius: state.innerRadius, outerRadius: state.outerRadius)
                    .fill(.thickMaterial, style: FillStyle(eoFill: true))
                ForEach(Array(zip(state.windows.indices, placements)), id: \.0) { index, placement in
                    WedgeSliceView(
                        center: state.centerInView,
                        innerRadius: highlightInnerRadius,
                        outerRadius: highlightOuterRadius,
                        startAngle: .radians(Double(placement.angle - wedgeHalfStep)),
                        endAngle: .radians(Double(placement.angle + wedgeHalfStep)),
                        isSelected: index == state.selectedIndex
                    )
                }
                ForEach(Array(zip(state.windows.indices, placements)), id: \.0) { index, placement in
                    RingIconView(window: state.windows[index], isSelected: index == state.selectedIndex)
                        .position(iconPoint(forAngle: placement.angle))
                }
            }
        }
    }
}

/// A pie-slice from `innerRadius` to `outerRadius` spanning `startAngle` to
/// `endAngle`, shrunk by `inset` on all four sides and with all four corners
/// rounded. The arcs are walked in small line segments rather than relying on
/// Shape.addArc's clockwise flag — its sense flips confusingly in SwiftUI's
/// y-down coordinate space, and this is unambiguous either way.
private struct WedgeShape: Shape {
    let center: CGPoint
    let innerRadius: CGFloat
    let outerRadius: CGFloat
    let startAngle: Angle
    let endAngle: Angle
    /// Uniform transparent margin between the wedge's nominal bounds and the
    /// filled shape, in points — so neighbouring wedges never touch and the
    /// fill never reaches the ring's own edges.
    var inset: CGFloat = 4
    /// Corner rounding in points, clamped below to whatever this particular
    /// wedge can actually accommodate.
    var cornerRadius: CGFloat = 10

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let start = startAngle.radians
        let end = endAngle.radians
        let sweep = end - start
        guard abs(sweep) > 1e-6 else { return path }
        let direction: Double = sweep < 0 ? -1 : 1

        // Pull both radii in by `inset`, then pull each radial edge in by the
        // angle that covers `inset` points *at that edge's radius* — an equal
        // arc-length margin top and bottom, which leaves the radial edges very
        // slightly non-radial. That is what a uniform border looks like.
        let rIn = innerRadius + inset
        let rOut = outerRadius - inset
        guard rOut > rIn, rIn > 0 else { return path }
        let innerMargin = Double(inset / rIn) * direction
        let outerMargin = Double(inset / rOut) * direction
        let startIn = start + innerMargin
        let endIn = end - innerMargin
        let startOut = start + outerMargin
        let endOut = end - outerMargin
        // A wedge too narrow to survive its own inset draws nothing.
        guard (endIn - startIn) * direction > 0, (endOut - startOut) * direction > 0 else { return path }

        func point(_ angle: Double, _ r: CGFloat) -> CGPoint {
            CGPoint(x: center.x + r * cos(angle), y: center.y + r * sin(angle))
        }
        func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
            CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }
        func addArc(from a0: Double, to a1: Double, r: CGFloat) {
            let steps = max(2, Int(abs(a1 - a0) / 0.08) + 1)
            for i in 1...steps {
                let t = Double(i) / Double(steps)
                path.addLine(to: point(a0 + (a1 - a0) * t, r))
            }
        }

        // The four sharp corners the rounding replaces.
        let c1 = point(startIn, rIn)
        let c2 = point(startOut, rOut)
        let c3 = point(endOut, rOut)
        let c4 = point(endIn, rIn)
        let edgeLength = hypot(c2.x - c1.x, c2.y - c1.y)

        // Rounding must fit the wedge in both directions: half the radial edge,
        // and half the arc length of the inner edge (the shorter of the two).
        let radius = max(0, min(cornerRadius,
                                edgeLength / 2,
                                rIn * CGFloat(abs(endIn - startIn)) / 2))
        let edgeFraction = edgeLength > 0 ? radius / edgeLength : 0
        let innerStep = Double(radius / rIn) * direction
        let outerStep = Double(radius / rOut) * direction

        // Each corner is a quadratic curve whose control point is that corner.
        path.move(to: lerp(c1, c2, edgeFraction))
        path.addLine(to: lerp(c2, c1, edgeFraction))
        path.addQuadCurve(to: point(startOut + outerStep, rOut), control: c2)
        addArc(from: startOut + outerStep, to: endOut - outerStep, r: rOut)
        path.addQuadCurve(to: lerp(c3, c4, edgeFraction), control: c3)
        path.addLine(to: lerp(c4, c3, edgeFraction))
        path.addQuadCurve(to: point(endIn - innerStep, rIn), control: c4)
        addArc(from: endIn - innerStep, to: startIn + innerStep, r: rIn)
        path.addQuadCurve(to: lerp(c1, c2, edgeFraction), control: c1)
        path.closeSubpath()
        return path
    }
}

/// The full ring from `innerRadius` to `outerRadius` — the frosted-glass base
/// every wedge tint sits on top of, drawn once so there's no seam between
/// adjacent wedges.
private struct AnnulusShape: Shape {
    let center: CGPoint
    let innerRadius: CGFloat
    let outerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addArc(center: center, radius: outerRadius, startAngle: .degrees(0), endAngle: .degrees(360), clockwise: false)
        path.addArc(center: center, radius: innerRadius, startAngle: .degrees(0), endAngle: .degrees(360), clockwise: false)
        return path
    }
}

/// One wedge's tint. Only the selected wedge is drawn at all — an accent fill
/// with rounded corners, sitting inside a 4pt transparent margin so it never
/// touches its neighbours or the ring's edges.
private struct WedgeSliceView: View {
    let center: CGPoint
    let innerRadius: CGFloat
    let outerRadius: CGFloat
    let startAngle: Angle
    let endAngle: Angle
    let isSelected: Bool

    private var shape: WedgeShape {
        WedgeShape(center: center, innerRadius: innerRadius, outerRadius: outerRadius, startAngle: startAngle, endAngle: endAngle)
    }

    var body: some View {
        shape
            .fill(isSelected ? Color.accentColor.opacity(0.35) : Color.clear)
            .animation(.spring(response: 0.2, dampingFraction: 0.8), value: isSelected)
    }
}

/// Just the icon circle — the window's title only appears once, in the
/// ring's center hub, for whichever item is currently selected.
private struct RingIconView: View {
    let window: WindowInfo
    let isSelected: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: isSelected ? 64 : 52, height: isSelected ? 64 : 52)
                .overlay(
                    Circle().strokeBorder(
                        isSelected ? Color.accentColor : Color.white.opacity(0.25),
                        lineWidth: isSelected ? 2.5 : 1
                    )
                )
            if let icon = window.icon {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: isSelected ? 40 : 32, height: isSelected ? 40 : 32)
            }
        }
        .shadow(color: .black.opacity(isSelected ? 0.35 : 0.15), radius: isSelected ? 8 : 3)
        .scaleEffect(isSelected ? 1.08 : 1.0)
        .animation(.spring(response: 0.22, dampingFraction: 0.75), value: isSelected)
    }
}
