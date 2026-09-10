import SwiftUI

/// Every number in this app's UI is measured in design pixels on a 2000 x 2000
/// canvas, so the layout is *proportionally* exact rather than eyeballed.
///
/// Design pixels fix only ratios, never an absolute size, so one anchor picks
/// the scale: a cell's ring is 44pt across, and it measures 117 design pixels.
/// Change `scale` and the whole surface, notch, rings, type, tooltip, resizes
/// together, still in the same proportions.
enum Design {
    /// Points per design pixel.
    static let scale: CGFloat = 44.0 / 117.0

    /// A distance measured in design pixels, in points.
    static func px(_ pixels: CGFloat) -> CGFloat { pixels * scale }

    /// Cap-height fraction of an em for SF Pro. Type is only ever specified by
    /// its cap height, so this converts back to a point size.
    private static let capRatio: CGFloat = 0.714

    /// The point size whose capital letters are `pixels` design pixels tall.
    static func fontSize(capPixels pixels: CGFloat) -> CGFloat {
        px(pixels) / capRatio
    }
}
