import CoreGraphics

/// Turns wheel and trackpad deltas into whole steps. A later phase wires this
/// to the scroll-through-cells behaviour.
struct WheelStepper {
    var stepThreshold: CGFloat
    private var accumulated: CGFloat = 0
    var overscrolled = false

    init(stepThreshold: CGFloat) {
        self.stepThreshold = stepThreshold
    }

    /// Momentum events are ignored and touch nothing. A non-precise event (a
    /// mouse wheel notch) steps once per event, in the delta's sign, with no
    /// accumulation. A precise delta accumulates, returning whole steps
    /// truncated toward zero and keeping the remainder.
    mutating func feed(delta: CGFloat, precise: Bool, momentum: Bool) -> Int {
        guard !momentum else { return 0 }
        guard precise else {
            if delta > 0 { return 1 }
            if delta < 0 { return -1 }
            return 0
        }
        accumulated += delta
        let steps = Int(accumulated / stepThreshold)
        accumulated -= CGFloat(steps) * stepThreshold
        return steps
    }

    mutating func reset() {
        accumulated = 0
    }

    /// Clamps `index` to `range`, setting `overscrolled` when clamping
    /// changed it and clearing it otherwise.
    mutating func clamp(_ index: Int, within range: ClosedRange<Int>) -> Int {
        let clamped = min(max(index, range.lowerBound), range.upperBound)
        overscrolled = clamped != index
        return clamped
    }
}
