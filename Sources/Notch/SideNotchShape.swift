import SwiftUI

/// The notch body: a pill welded to one edge of the screen, with *inverse*
/// rounded corners at each end that flare back out to the edge so it reads as
/// part of the bezel rather than a floating panel.
///
/// The path is only ever written once, for the right edge, and then transformed
/// onto whichever edge it is actually on. Writing four variants would mean four
/// copies of the corner-versus-flare clamping below, which is the one piece of
/// this that took real work to get right. And three of the copies would never
/// be the one under the cursor when it broke.
///
/// In canonical form `rect` is the whole shape including the flares; the
/// straight body runs from `rect.minY + curlRadius` to `rect.maxY - curlRadius`,
/// and `rect.maxX` is the screen edge.
struct SideNotchShape: Shape {
    var edge: NotchEdge = .right
    var curlRadius: CGFloat = NotchLayout.curlRadius
    var cornerRadius: CGFloat = NotchLayout.cornerRadius

    struct Curves: Equatable {
        let curl: CGFloat
        let corner: CGFloat
    }

    func resolvedCurves(in size: CGSize) -> Curves {
        let depth = size.width
        let length = size.height
        let wanted = max(0, min(cornerRadius, depth / 2))
        let curl = max(0, min(curlRadius, length / 2, depth - wanted))
        return Curves(curl: curl, corner: max(0, min(wanted, (length - 2 * curl) / 2)))
    }

    func path(in rect: CGRect) -> Path {
        let depth = rect.width
        let length = rect.height
        let canonical = canonicalPath(
            in: CGRect(x: 0, y: 0, width: depth, height: length),
            curves: resolvedCurves(in: rect.size)
        )
        return canonical
            .applying(Self.transform(for: edge, depth: depth))
            .applying(CGAffineTransform(translationX: rect.minX, y: rect.minY))
    }

    /// Canonical (`u`, `v`). `u` across from the far side, `v` along. Onto the
    /// rect's own coordinates, with the bezel landing on the right edge.
    ///
    /// Derived rather than eyeballed: in stack space the bezel is always
    /// `across == 0`, so `across = depth - u`, and each edge then places
    /// `(along, across)` the same way `NotchPlacement` does.
    static func transform(for edge: NotchEdge, depth: CGFloat) -> CGAffineTransform {
        switch edge {
        case .right:
            return .identity
        case .left:
            // Mirrored: the flares point the other way.
            return CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: depth, ty: 0)
        }
    }

    private func canonicalPath(in rect: CGRect, curves: Curves) -> Path {
        let curl = curves.curl
        let corner = curves.corner
        let bodyTop = rect.minY + curl
        let bodyBottom = rect.maxY - curl

        var path = Path()
        // Screen edge, above the body.
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        // Flare inward and down onto the top edge. Guarded rather than assumed:
        // a zero curl would otherwise draw a degenerate arc.
        if curl > 0 {
            path.addArc(
                center: CGPoint(x: rect.maxX - curl, y: rect.minY),
                radius: curl,
                startAngle: .degrees(0), endAngle: .degrees(90),
                clockwise: false
            )
        }
        path.addLine(to: CGPoint(x: rect.minX + corner, y: bodyTop))
        path.addArc(
            center: CGPoint(x: rect.minX + corner, y: bodyTop + corner),
            radius: corner,
            startAngle: .degrees(270), endAngle: .degrees(180),
            clockwise: true
        )
        path.addLine(to: CGPoint(x: rect.minX, y: bodyBottom - corner))
        path.addArc(
            center: CGPoint(x: rect.minX + corner, y: bodyBottom - corner),
            radius: corner,
            startAngle: .degrees(180), endAngle: .degrees(90),
            clockwise: true
        )
        path.addLine(to: CGPoint(x: rect.maxX - curl, y: bodyBottom))
        // Flare back out to the screen edge.
        if curl > 0 {
            path.addArc(
                center: CGPoint(x: rect.maxX - curl, y: rect.maxY),
                radius: curl,
                startAngle: .degrees(270), endAngle: .degrees(360),
                clockwise: false
            )
        }
        path.closeSubpath()
        return path
    }
}
