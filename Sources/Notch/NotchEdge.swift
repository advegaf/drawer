import Foundation

/// Which screen edge the notch is welded to.
///
/// The edge decides which way the tooltip leaves. Both edges keep the stack
/// running down the screen: a bottom edge shipped for a while and was
/// removed, because a wide bar resting on the Dock is a second Dock, and
/// because every cell in it sat where a window's own controls are.
enum NotchEdge: String, CaseIterable, Identifiable {
    case right
    case left

    var id: String { rawValue }

    /// Where the tooltip goes: away from the bezel, always.
    enum TooltipDirection: Equatable {
        case leading    // card to the left of the notch
        case trailing   // card to the right of it
    }

    var tooltipDirection: TooltipDirection {
        switch self {
        case .right:  return .leading
        case .left:   return .trailing
        }
    }

    /// A unit vector pointing at the bezel, in panel coordinates (y grows down,
    /// as it does in a flipped `NSHostingView` and in SwiftUI). This is the way
    /// the contents slide as the notch folds away into the edge.
    var outward: CGPoint {
        switch self {
        case .right:  return CGPoint(x: 1, y: 0)
        case .left:   return CGPoint(x: -1, y: 0)
        }
    }

    /// A unit vector along the stack, in the same panel coordinates as
    /// `outward`. Perpendicular to it by construction: the stack runs *along*
    /// the bezel, and `across` leaves the bezel at a right angle.
    var alongDirection: CGPoint { CGPoint(x: 0, y: 1) }

    var title: String {
        switch self {
        case .right:  return "Right"
        case .left:   return "Left"
        }
    }

    var explanation: String {
        switch self {
        case .right:
            return "Down the right-hand edge, clear of a Dock on that side."
        case .left:
            return "Down the left-hand edge, clear of a Dock on that side."
        }
    }
}
