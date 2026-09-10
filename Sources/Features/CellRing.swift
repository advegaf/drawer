import SwiftUI

/// The ring around a cell's glyph: a grey track with a coloured arc that starts
/// at 12 o'clock and sweeps clockwise by the fraction used.
struct CellRing: View {
    /// Nil draws the track only, with no arc on top of it.
    let fraction: Double?
    let tint: Color
    /// Waiting on something to settle. Spins a status trim across the ring;
    /// the press-in is the caller's, since it is delayed a beat behind this.
    var isPending: Bool = false
    /// Scales the ring's diameter with the theme's cell size. The stroke
    /// widths stay fixed; only the diameter the brief lists as scaled.
    var metrics: Metrics = .default
    var theme: Theme = .default

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    private var sweep: CGFloat { CGFloat(min(max(fraction ?? 0, 0), 1)) }

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder((contrast == .increased ? Palette.primary(theme).opacity(0.45) : Palette.track(theme)), lineWidth: NotchLayout.trackStroke)


            if fraction != nil {
                let arc = Circle()
                    .inset(by: NotchLayout.trackStroke / 2)
                    .trim(from: 0, to: sweep)
                arc.stroke(tint, style: StrokeStyle(lineWidth: NotchLayout.progressStroke, lineCap: .round))
                .rotationEffect(.degrees(-90))
            }

            if isPending {
                if reduceMotion {
                    pendingTrim
                } else {
                    TimelineView(.animation) { context in
                        pendingTrim.rotationEffect(.degrees(Self.angle(at: context.date)))
                    }
                }
            }
        }
        .frame(width: NotchLayout.ringDiameter(metrics), height: NotchLayout.ringDiameter(metrics))
    }

    private var pendingTrim: some View {
        Circle()
            .trim(from: 0, to: 0.75)
            .stroke(Palette.secondary(theme),
                    style: StrokeStyle(lineWidth: NotchLayout.progressStroke, lineCap: .round))
            .rotationEffect(.degrees(-90))
    }

    private static let period: Double = 1.4

    private static func angle(at date: Date) -> Double {
        let turns = date.timeIntervalSinceReferenceDate / period
        return turns.truncatingRemainder(dividingBy: 1) * 360
    }
}
