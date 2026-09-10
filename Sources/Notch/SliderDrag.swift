import CoreGraphics

/// A drag-to-set control, such as a volume or brightness bar. A later phase
/// wires this to an actual slider cell.
struct SliderDrag {
    let band: CGRect
    let horizontal: Bool
    var isActive: Bool

    /// The along-axis position of `point` inside `band`, mapped to 0...1 and
    /// clamped: left to right when horizontal, bottom to top when vertical,
    /// since AppKit's y grows upward.
    func value(at point: CGPoint) -> Double {
        let fraction = horizontal
            ? (point.x - band.minX) / band.width
            : (point.y - band.minY) / band.height
        return Double(min(max(fraction, 0), 1))
    }

    func contains(_ point: CGPoint) -> Bool {
        band.contains(point)
    }
}
