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
/// `endAngle`, drawn by walking the arc in small line segments rather than
/// relying on Shape.addArc's clockwise flag — its sense flips confusingly in
/// SwiftUI's y-down coordinate space, and this is unambiguous either way.
private struct WedgeShape: Shape {
    let center: CGPoint
    let innerRadius: CGFloat
    let outerRadius: CGFloat
    let startAngle: Angle
    let endAngle: Angle

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let steps = 24
        let start = startAngle.radians
        let end = endAngle.radians
        func point(at angle: Double, radius: CGFloat) -> CGPoint {
            CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
        }
        path.move(to: point(at: start, radius: innerRadius))
        path.addLine(to: point(at: start, radius: outerRadius))
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            path.addLine(to: point(at: start + (end - start) * t, radius: outerRadius))
        }
        path.addLine(to: point(at: end, radius: innerRadius))
        for i in stride(from: steps - 1, through: 0, by: -1) {
            let t = Double(i) / Double(steps)
            path.addLine(to: point(at: start + (end - start) * t, radius: innerRadius))
        }
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

/// One wedge's tint — no stroke/border, so adjacent wedges read as one soft
/// disc rather than a set of hard-edged pie slices. Selection is communicated
/// purely by a warmer, stronger fill.
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
