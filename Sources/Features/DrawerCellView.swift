import SwiftUI

/// One cell's content: a ring, a glyph, and nothing that listens for a
/// gesture of its own. The view stays gesture-free because
/// `NotchPanel.mouseDown` dispatches clicks by geometry, not by anything
/// attached here.
struct DrawerCellView: View {
    let cell: DrawerCell
    /// The user's look. Drives the ring's size, its accent tint, and
    /// whether a title sits under it. `Theme` rather than `Metrics` alone,
    /// since the ring's tint needs `Palette.on(theme)`, not just geometry.
    var theme: Theme = .default
    private var metrics: Metrics { theme.metrics }

    /// The spinner trim, delayed behind the state change itself so a click
    /// that resolves in a blink never flashes one.
    @State private var showSpinner = false
    @State private var settledToggle: Bool?

    init(cell: DrawerCell, theme: Theme = .default) {
        self.cell = cell
        self.theme = theme
        _settledToggle = State(initialValue: Self.toggleValue(cell.state))
    }

    private static func toggleValue(_ state: CellState) -> Bool? {
        switch state {
        case .on: return true
        case .off: return false
        default: return nil
        }
    }

    private var showsPendingMotion: Bool { cell.kind != .toggle && cell.state == .pending }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: metrics.showsLabels ? NotchLayout.labelGap : 0) {
            Group {
                if cell.kind == .launch, cell.state != .notInstalled {
                    glyph(cell.icon, size: NotchLayout.ringDiameter(metrics), tint: .white)
                } else {
                    ZStack {
                        CellRing(fraction: fraction, tint: tint, isPending: showsPendingMotion && showSpinner, metrics: metrics, theme: theme)
                        glyph(displayIcon, size: NotchLayout.glyphSize(metrics), tint: glyphTint)
                            .opacity(cell.kind == .toggle && cell.state == .pending ? 0.65 : 1)
                    }
                }
            }
            .frame(width: NotchLayout.ringDiameter(metrics), height: NotchLayout.ringDiameter(metrics))
            .scaleEffect(reduceMotion ? 1 : showsPendingMotion ? 0.97 : 1)
            .animation(NotchMotion.respectingReduceMotion(NotchMotion.overscroll, reduceMotion), value: showsPendingMotion)

            if metrics.showsLabels {
                // A fixed frame, not the text's own measured size: the
                // stack's pitch and the hover bands are both built from
                // `NotchLayout.cellExtent(metrics)`, and a font-measured
                // height could drift a point or two from that figure.
                //
                // Width is `NotchLayout.cellLabelWidth`, wide enough for the
                // real titles to read in full. The bar grows to meet it
                // instead of the label shrinking to meet the bar:
                // `NotchLayout.bodyDepth` gives a vertical edge extra depth,
                // at the ring's own clearance, whenever labels are on. See
                // `bodyDepth`'s own comment and `docs/qa/decisions.md` Phase
                // 24 for why narrowing the label was tried first and reverted.
                Text(cell.title)
                    .font(Typography.cellLabel)
                    .foregroundStyle(Palette.primary(theme))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: NotchLayout.cellLabelWidth, height: NotchLayout.cellLabelLineHeight)
            }
        }
        .frame(height: NotchLayout.cellExtent(metrics))
        .opacity(isGhosted ? Palette.ghost : 1)
        .onChange(of: cell.state) { _, state in
            if let value = Self.toggleValue(state) { settledToggle = value }
        }
        .task(id: showsPendingMotion) {
            showSpinner = false
            guard showsPendingMotion else { return }
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            showSpinner = true
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(cell.title)
        .accessibilityValue(cell.state.label)
        .accessibilityAddTraits(.isButton)
    }

    private var isGhosted: Bool {
        switch cell.state {
        case .unavailable, .notInstalled, .notFound: return true
        default: return false
        }
    }

    private var fraction: Double? {
        switch cell.state {
        case .on: return 1
        case .off: return 0
        case .level(let value): return value.isFinite ? min(1, max(0, value)) : nil
        case .failed, .armed: return 1
        case .pending where cell.kind == .toggle: return settledToggle.map { $0 ? 1 : 0 }
        default: return nil
        }
    }

    private var tint: Color {
        switch cell.state {
        case .failed, .armed: return Palette.critical
        default: return Palette.on(theme)
        }
    }

    private var glyphTint: Color {
        cell.kind == .add ? Palette.secondary(theme) : Palette.primary(theme)
    }

    private var displayIcon: Icon {
        if cell.kind == .launch, cell.state == .notInstalled {
            return .symbol("app.dashed")
        }
        if cell.id == "action:mute" {
            let isOn = Self.toggleValue(cell.state) ?? (cell.state == .pending ? settledToggle : nil) ?? false
            return .symbol(isOn ? "speaker.slash.fill" : "speaker.wave.2.fill")
        }
        return cell.icon
    }

    @ViewBuilder
    private func glyph(_ icon: Icon, size: CGFloat, tint: Color) -> some View {
        switch icon {
        case .symbol(let name):
            Image(systemName: name)
                .resizable()
                .scaledToFit()
                .foregroundStyle(tint)
                .frame(width: size, height: size)
        case .image(let nsImage):
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        }
    }
}
