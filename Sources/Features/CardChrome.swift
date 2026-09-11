import SwiftUI

struct PopoverShape: Shape {
    var direction: NotchEdge.TooltipDirection
    var pointerOffset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let vertical = direction == .leading || direction == .trailing
        let width = vertical ? rect.height : rect.width
        let height = vertical ? rect.width : rect.height
        let d = NotchLayout.pointerDepth
        let c = min(NotchLayout.cardCorner, (height - d) / 2, width / 2)
        let halfBase = NotchLayout.pointerBase / 2
        let m = min(max(width / 2 + pointerOffset, c + halfBase), width - c - halfBase)
        var p = Path()
        p.move(to: CGPoint(x: c, y: d))
        p.addLine(to: CGPoint(x: m - halfBase, y: d))
        p.addCurve(to: CGPoint(x: m - d * 0.16, y: d * 0.16),
                   control1: CGPoint(x: m - halfBase * 0.55, y: d),
                   control2: CGPoint(x: m - d * 0.35, y: d * 0.16))
        p.addQuadCurve(to: CGPoint(x: m + d * 0.16, y: d * 0.16), control: CGPoint(x: m, y: -d * 0.16))
        p.addCurve(to: CGPoint(x: m + halfBase, y: d),
                   control1: CGPoint(x: m + d * 0.35, y: d * 0.16),
                   control2: CGPoint(x: m + halfBase * 0.55, y: d))
        p.addLine(to: CGPoint(x: width - c, y: d))
        p.addQuadCurve(to: CGPoint(x: width, y: d + c), control: CGPoint(x: width, y: d))
        p.addLine(to: CGPoint(x: width, y: height - c))
        p.addQuadCurve(to: CGPoint(x: width - c, y: height), control: CGPoint(x: width, y: height))
        p.addLine(to: CGPoint(x: c, y: height))
        p.addQuadCurve(to: CGPoint(x: 0, y: height - c), control: CGPoint(x: 0, y: height))
        p.addLine(to: CGPoint(x: 0, y: d + c))
        p.addQuadCurve(to: CGPoint(x: c, y: d), control: CGPoint(x: 0, y: d))
        p.closeSubpath()
        let transform: CGAffineTransform
        switch direction {
        case .trailing: transform = CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        case .leading: transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: height, ty: 0)
        }
        return p.applying(transform).applying(CGAffineTransform(translationX: rect.minX, y: rect.minY))
    }
}

struct TooltipShell<Content: View>: View {
    let height: CGFloat
    /// Measured from the card's own text rather than a constant, so a long
    /// title and a long note both fit. Defaults to the floor for previews.
    var width: CGFloat = NotchLayout.cardMinWidth
    let direction: NotchEdge.TooltipDirection
    var theme: Theme = .default
    var pointerOffset: CGFloat = 0
    @ViewBuilder let content: Content

    private var pointer: CGSize {
        let d = NotchLayout.pointerDepth
        switch direction {
        case .leading: return CGSize(width: d, height: 0)
        case .trailing: return CGSize(width: -d, height: 0)
        }
    }

    var body: some View {
        content
            .padding(NotchLayout.cardPadding)
            .frame(width: width, height: height, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: NotchLayout.cardCorner))
            .offset(x: -pointer.width / 2, y: -pointer.height / 2)
            .frame(width: width + abs(pointer.width), height: height + abs(pointer.height))
            .modifier(DrawerSurface(shape: PopoverShape(direction: direction, pointerOffset: pointerOffset), theme: theme))
            .offset(x: pointer.width / 2, y: pointer.height / 2)
            .frame(width: width, height: height)
    }
}

struct TooltipHeader<Mark: View>: View {
    let title: String
    /// Sits on the header's own line, so a secondary detail costs the card no
    /// extra height.
    var note: String?
    /// `Palette.textSecondary` for an ordinary detail; a state that needs
    /// attention (armed, failed) passes `Palette.critical` instead.
    var noteColor: Color = Palette.textSecondary
    /// Scales the title and note with the theme's card text size.
    var metrics: Metrics = .default
    var theme: Theme = .default
    @ViewBuilder let mark: Mark

    var body: some View {
        HStack(spacing: NotchLayout.headerGap) {
            mark
            Text(title)
                .font(Typography.cardTitle(metrics))
                .foregroundStyle(Palette.primary(theme))
            if let note {
                Spacer(minLength: Design.px(20))
                Text(note)
                    .font(Typography.cardBody(metrics).monospacedDigit())
                    .foregroundStyle(noteColor)
                    .lineLimit(1)
            }
        }
        .frame(height: NotchLayout.cardTitleLineHeight(metrics))
    }
}

/// A label on the left and a quieter value on the right, the row shape used
/// throughout the cards.
struct SplitRow<Accessory: View>: View {
    let leading: String
    let trailing: String
    var leadingColor: Color = Palette.textPrimary
    var trailingColor: Color = Palette.textSecondary
    /// Sits immediately before the trailing text, inside the same group, so it
    /// travels with the word instead of drifting to the middle of the row.
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: Design.px(20)) {
            Text(leading).foregroundStyle(leadingColor)
            Spacer(minLength: 0)
            HStack(spacing: NotchLayout.statusDotGap) {
                accessory()
                Text(trailing).foregroundStyle(trailingColor)
            }
        }
        .font(Typography.cardBody)
        .lineLimit(1)
    }
}

extension SplitRow where Accessory == EmptyView {
    init(leading: String,
         trailing: String,
         leadingColor: Color = Palette.textPrimary,
         trailingColor: Color = Palette.textSecondary) {
        self.init(leading: leading, trailing: trailing,
                  leadingColor: leadingColor, trailingColor: trailingColor,
                  accessory: { EmptyView() })
    }
}

/// What `StatusRing` draws: busy spins, waiting holds at half, idle holds full.
enum StatusRingState {
    case busy, waiting, idle
}

/// The ring beside a row's status.
///
/// Turning while the thing behind it is busy, still when it is not. So the
/// row says what is happening before the word is read.
struct StatusRing: View {
    let state: StatusRingState
    let color: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// One turn, in seconds. Slow enough to read as deliberate rather than as
    /// something struggling.
    private static let period: Double = 1.4

    var body: some View {
        Group {
            switch state {
            case .busy:
                if reduceMotion {
                    // Still, but still three-quarters: the gap alone says
                    // "in progress" without anything moving.
                    ring(trim: 0.75)
                } else {
                    // A timeline rather than `repeatForever`. An endless
                    // animation has to be cancelled to stop, and setting the
                    // value it is already heading towards does not cancel it,
                    // which is exactly how the refresh ring here once span for
                    // ever. Derived from the clock, it simply stops being drawn.
                    TimelineView(.animation) { context in
                        ring(trim: 0.75)
                            .rotationEffect(.degrees(angle(at: context.date)))
                    }
                }
            case .waiting:
                // Half a ring, held still: blocked, not progressing.
                ring(trim: 0.5)
            case .idle:
                ring(trim: 1)
            }
        }
        .frame(width: NotchLayout.statusDot, height: NotchLayout.statusDot)
    }

    private func ring(trim: CGFloat) -> some View {
        Circle()
            .trim(from: 0, to: trim)
            .stroke(color,
                    style: StrokeStyle(lineWidth: NotchLayout.statusDotStroke, lineCap: .round))
            // Start the gap at the top, where the eye lands first.
            .rotationEffect(.degrees(-90))
    }

    private func angle(at date: Date) -> Double {
        let turns = date.timeIntervalSinceReferenceDate / Self.period
        return turns.truncatingRemainder(dividingBy: 1) * 360
    }
}

/// A filled capsule over a track capsule, the bar shape every level tile
/// uses.
struct LevelBar: View {
    let fraction: Double
    let fill: Color
    let track: Color
    /// A white circle riding the fill's leading edge, for a bar that is meant
    /// to be dragged rather than just read.
    var thumb: Bool = false
    var theme: Theme = .default
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        GeometryReader { proxy in
            let width = max(NotchLayout.barHeight, proxy.size.width * CGFloat(min(max(fraction, 0), 1)))
            ZStack(alignment: .leading) {
                Capsule().fill(contrast == .increased ? Palette.primary(theme).opacity(0.45) : track)
                Capsule().fill(fill).frame(width: width)
                if thumb {
                    Circle()
                        .fill(Palette.primary(theme))
                        .frame(width: NotchLayout.sliderThumb, height: NotchLayout.sliderThumb)
                        .offset(x: width - NotchLayout.sliderThumb / 2)
                }
            }
        }
        .frame(height: NotchLayout.barHeight)
    }
}
