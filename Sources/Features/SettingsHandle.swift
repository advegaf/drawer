import SwiftUI

/// The settings control, below the notch.
///
/// At rest it is a single arc. A segment of a circle's edge, tucked into the
/// corner the notch's bottom flare makes. On hover that same circle fills in and
/// takes a gear. The two states are the same circle, which is what makes the
/// change read as one object waking up rather than as one thing being swapped
/// for another.
///
/// It is a bare arc at rest because the notch is meant to be glanceable: a
/// permanently visible gear is a second thing competing with the items, and
/// the items are the point. An arc says "there is something here" without
/// asserting anything.
struct SettingsArcBand: Shape {
    let trim: ClosedRange<CGFloat>
    let width: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addArc(center: CGPoint(x: rect.midX, y: rect.midY),
                    radius: max(0, (min(rect.width, rect.height) - width) / 2),
                    startAngle: .degrees(Double(trim.lowerBound) * 360),
                    endAngle: .degrees(Double(trim.upperBound) * 360), clockwise: false)
        return path.strokedPath(StrokeStyle(lineWidth: width, lineCap: .round))
    }
}

struct SettingsOrb: View {
    let isHovered: Bool
    var edge: NotchEdge = .right
    /// True when the arc traces the bar's own rounded corner from outside
    /// rather than a flare from inside. Always false today: every bar flares,
    /// so nothing sets this.
    var convex: Bool = false
    /// The circle the resting arc follows.
    var arcRadius: CGFloat = NotchLayout.orbArcRadius
    /// How far the arc sits from the button. Zero inside the flare's pocket,
    /// where the two are the same object, which is every case today.
    var arcOffset: CGSize = .zero
    /// The bar's own look, so the orb matches it at rest.
    var theme: Theme = .default

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Which quarter of the circle the resting arc occupies.
    ///
    /// The arc has to parallel the flare at the far end of the notch, so it
    /// faces two ways at once: **back along the stack**, toward the notch it
    /// hangs off, and **outward**, toward the bezel it is about to merge into.
    /// On the right edge that is twelve o'clock round to three, which is the
    /// arc this was drawn as before there was any choice of edge. Turn the
    /// notch and the same two directions pick a different quadrant.
    ///
    /// SwiftUI's `Circle` trim starts at three o'clock and runs clockwise, with
    /// y growing downward.
    /// Hugging a corner from outside is the same relationship as hugging a
    /// flare from inside, turned through half a circle.
    static func restingTrim(for edge: NotchEdge, convex: Bool) -> ClosedRange<CGFloat> {
        let concave = restingTrim(for: edge)
        guard convex else { return concave }
        let turned = (concave.lowerBound + 0.5).truncatingRemainder(dividingBy: 1)
        return turned...(turned + 0.25)
    }

    static func restingTrim(for edge: NotchEdge) -> ClosedRange<CGFloat> {
        switch edge {
        case .right:  return 0.75...1.0      // up, round to the right
        case .left:   return 0.5...0.75      // left, round to up
        }
    }

    private var restingTrim: ClosedRange<CGFloat> { Self.restingTrim(for: edge, convex: convex) }



    var body: some View {
        ZStack {
            DrawerChrome(shape: SettingsArcBand(trim: restingTrim, width: NotchLayout.orbStroke), theme: theme,
                         size: CGSize(width: arcRadius * 2 + NotchLayout.orbStroke,
                                      height: arcRadius * 2 + NotchLayout.orbStroke))
                .opacity(isHovered ? 0 : 1)
                .scaleEffect(reduceMotion ? 1 : isHovered ? 0.96 : 1)
                .offset(arcOffset)

            Image(systemName: "gearshape")
                .font(.system(size: NotchLayout.orbGlyph, weight: .regular))
                .foregroundStyle(Palette.primary(theme))
                .frame(width: NotchLayout.orbDiameter, height: NotchLayout.orbDiameter)
                .modifier(DrawerSurface(shape: Circle(), theme: theme))
                .opacity(isHovered ? 1 : 0)
                .scaleEffect(reduceMotion ? 1 : isHovered ? 1 : 0.96)
        }
        // Sized to the larger of the two states, and never clipped: the arc
        // may sit well outside this frame when it has stayed back on the
        // corner the button hangs from.
        .frame(width: arcRadius * 2 + NotchLayout.orbStroke,
               height: arcRadius * 2 + NotchLayout.orbStroke)
        .animation(reduceMotion ? NotchMotion.crossfade : NotchMotion.handle, value: isHovered)
    }
}
