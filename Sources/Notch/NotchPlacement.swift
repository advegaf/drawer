import Foundation

/// The one place in the notch that knows which way round the axes are.
///
/// Everything else works in **stack space**, which has only two coordinates and
/// no opinion about the screen:
///
/// - `along` runs the length of the cell stack, from its start to its end.
/// - `across` measures **inward from the bezel**, so zero is always the screen
///   edge and a positive value always moves toward the middle of the screen.
///
/// That is what lets `NotchLayout` stay the one-dimensional set of constants it
/// already was: its maths never cared which axis it was on, only that it had
/// one. This type turns a stack-space coordinate into a point in the panel,
/// whose origin is top-left (`NSHostingView` is flipped, and so is SwiftUI's
/// `GeometryReader`, so the two agree).
struct NotchPlacement {
    let edge: NotchEdge
    let panelSize: CGSize

    /// A point in panel coordinates.
    func point(along: CGFloat, across: CGFloat) -> CGPoint {
        switch edge {
        case .right:  return CGPoint(x: panelSize.width - across, y: along)
        case .left:   return CGPoint(x: across, y: along)
        }
    }

    /// A rect in panel coordinates, spanning `depth` **inward** from `across`.
    ///
    /// Spanning inward rather than symmetrically is the point: a hit region
    /// anchored at the bezel must not hang off the far side of it, where there
    /// is no screen to be on.
    func rect(along: CGFloat, across: CGFloat, length: CGFloat, depth: CGFloat) -> CGRect {
        switch edge {
        case .right:
            return CGRect(x: panelSize.width - across - depth, y: along,
                          width: depth, height: length)
        case .left:
            return CGRect(x: across, y: along, width: depth, height: length)
        }
    }

    /// The panel needed for a stack of `length` and a depth of `depth`.
    static func panelSize(edge: NotchEdge, length: CGFloat, depth: CGFloat) -> CGSize {
        CGSize(width: depth, height: length)
    }

    /// The inverse: how far along the stack a point in the panel is.
    func along(of point: CGPoint) -> CGFloat {
        point.y
    }

    /// And how far in from the bezel.
    func across(of point: CGPoint) -> CGFloat {
        switch edge {
        case .right:  return panelSize.width - point.x
        case .left:   return point.x
        }
    }

    /// The panel's extent along the stack, whichever axis that is.
    var panelLength: CGFloat { panelSize.height }

    /// And across it.
    var panelDepth: CGFloat { panelSize.width }
}
