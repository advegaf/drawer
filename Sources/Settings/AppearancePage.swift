import SwiftUI

/// How the drawer looks and where it lives. Two cards on the canvas, one
/// setting per row.
struct AppearancePage: View {
    @ObservedObject var preferences: Preferences
    @FocusState private var focusedFinish: Theme.BarStyle?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsStyle.s24) {
                look
                placement
            }
            // No padding of its own: this page is laid out under the shared
            // preview banner, which already sits inside the window's own
            // inset. Adding another here would step the cards in from the
            // banner above them.
            .padding(.bottom, SettingsStyle.s24)
        }
        .scrollIndicators(.hidden)
        .background(HiddenScrollIndicators())
        .navigationTitle(SettingsPage.appearance.title)
    }

    private var look: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: SettingsStyle.s4) {
                SettingsSectionHeader("Look")

                Divider()

                SettingsRow("Finish", symbol: "circle.lefthalf.filled",
                            subtitle: "Follow macOS switches with the system appearance.") {
                    finishRow()
                }

                Divider()

                SettingsRow("Accent", symbol: "paintpalette") {
                    HStack(spacing: SettingsStyle.s6) {
                        swatch(color: Color.accentColor, label: "System",
                               selected: preferences.theme.accent == .system) {
                            preferences.theme.accent = .system
                        }
                        ForEach(Theme.Preset.allCases, id: \.self) { preset in
                            swatch(color: preset.color, label: preset.rawValue.capitalized,
                                   selected: preferences.theme.accent == .preset(preset)) {
                                preferences.theme.accent = .preset(preset)
                            }
                        }
                        ColorPicker("Custom", selection: customAccentBinding, supportsOpacity: false)
                            .labelsHidden()
                    }
                }

                Divider()

                SettingsRow("Cell size", symbol: "square.resize") {
                    Picker("Cell size", selection: $preferences.theme.cellSize) {
                        ForEach(Theme.CellSize.allCases, id: \.self) { size in
                            Text(size.rawValue.capitalized).tag(size)
                        }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }

                Divider()

                SettingsRow("Titles under cells", symbol: "textformat.size",
                            subtitle: "Deepens the drawer to make room for a name under each cell.") {
                    Toggle("Titles under cells", isOn: $preferences.theme.showsLabels)
                        .labelsHidden().toggleStyle(.switch)
                }

                Divider()

                SettingsRow("Card text", symbol: "character") {
                    Picker("Card text", selection: $preferences.theme.cardText) {
                        ForEach(Theme.CardText.allCases, id: \.self) { text in
                            Text(text.rawValue.capitalized).tag(text)
                        }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
            }
        }
    }

    private var placement: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: SettingsStyle.s4) {
                SettingsSectionHeader("Placement")

                Divider()

                SettingsRow("Show", symbol: "eye", subtitle: preferences.notchVisibility.explanation) {
                    Picker("Show", selection: $preferences.notchVisibility) {
                        ForEach(NotchVisibility.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }

                Divider()

                SettingsRow("Edge", symbol: "rectangle.righthalf.inset.filled",
                            subtitle: preferences.notchEdge.explanation) {
                    Picker("Edge", selection: $preferences.notchEdge) {
                        ForEach(NotchEdge.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
            }
        }
    }

    /// One row of finish thumbnails, read by VoiceOver as a single control
    /// labelled "Finish" (`.accessibilityElement(children: .contain)` keeps
    /// each tile's own `.isSelected` trait underneath that label). Left and
    /// right move focus between the three tiles, which a plain row of
    /// buttons does not do on its own.
    ///
    /// The tiles sit in a row's trailing control, so they get whatever
    /// width the card has left rather than a fixed column. 10pt between
    /// them still, which reads as three choices in one control instead of
    /// three separate buttons.
    private func finishRow() -> some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(Theme.BarStyle.allCases, id: \.self) { style in
                finishChoice(style)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Finish")
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            let all = Theme.BarStyle.allCases
            guard let current = focusedFinish, let index = all.firstIndex(of: current) else { return .ignored }
            switch press.key {
            case .leftArrow where index > 0: focusedFinish = all[index - 1]
            case .rightArrow where index < all.count - 1: focusedFinish = all[index + 1]
            default: return .ignored
            }
            return .handled
        }
    }

    private func finishChoice(_ style: Theme.BarStyle) -> some View {
        let selected = preferences.theme.bar == style
        return Button { preferences.theme.bar = style } label: {
            VStack(spacing: 6) {
                // `.overlay` never grows the width its parent reports, so
                // the selection ring can sit a few points outside the tile
                // without widening this item and blowing the row's budget
                // the way stacking it in a same-size `ZStack` did.
                FinishThumbnail(style: style, base: preferences.theme)
                    .overlay {
                        RoundedRectangle(cornerRadius: FinishThumbnail.cornerRadius + 3)
                            .strokeBorder(SettingsStyle.accent, lineWidth: selected ? 2 : 0)
                            .padding(-4)
                    }
                Text(style.title).font(.caption).foregroundStyle(selected ? .primary : .secondary)
                    .frame(width: FinishThumbnail.size.width)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .padding(.vertical, 4)
            .background(SettingsStyle.accent.opacity(focusedFinish == style ? 0.16 : 0), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).focused($focusedFinish, equals: style).focusEffectDisabled()
            .accessibilityLabel(style.title).accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func swatch(color: Color, label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle()
                .fill(color)
                .frame(width: 22, height: 22)
                .overlay {
                    if selected {
                        Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Converts the chosen `Color` to and from `Theme.Accent.custom(hex:)`.
    /// While the accent is `.system` or a preset, the picker just shows that
    /// accent's own resolved colour rather than a stale custom value.
    private var customAccentBinding: Binding<Color> {
        Binding(
            get: {
                switch preferences.theme.accent {
                case .system: return Color.accentColor
                case .preset(let preset): return preset.color
                case .custom(let hex): return Color(hex: hex)
                }
            },
            set: { color in
                guard let hex = color.hex else { return }
                preferences.theme.accent = .custom(hex: hex)
            }
        )
    }
}

/// One Finish choice, drawn as a crop of the drawer's own edge rather than a
/// miniature of a whole display: at this size a bar down the edge of a
/// shrunk display would render a few points wide and the finish, the thing
/// being chosen, would be invisible. So the tile fills its whole bounds with
/// `DrawerChrome`'s real background and a couple of plain `CellRing` tracks
/// (no progress arc; this is a finish picker, not a status readout), the
/// same views the drawer itself paints with, so a finish can never look one
/// way here and another way in the drawer.
///
/// Follow macOS has no single surface to show, so its tile splits diagonally
/// into a light half and a dark half, each with its own rings, the same way
/// System Settings' own Auto appearance thumbnail reads.
struct FinishThumbnail: View {
    let style: Theme.BarStyle
    var base: Theme = .default

    @Environment(\.colorScheme) private var systemScheme

    static let size = CGSize(width: 76, height: 52)
    static let cornerRadius: CGFloat = 12
    // Three narrower rings, not two: two same-size circles side by side
    // read as a domino's pips rather than a drawer's cells (phase 37,
    // `phase37-appearance-before.png`). A third ring at a smaller scale
    // keeps roughly the same total width the two larger rings used.
    private static let ringMetrics = Metrics(cellScale: 0.38, showsLabels: false, cardTextScale: 1)

    var body: some View {
        Group {
            switch style {
            case .light: surface(bar: .light)
            case .oled: surface(bar: .oled)
            case .automatic:
                ZStack {
                    surface(bar: .light).clipShape(DiagonalHalf(trailing: false))
                    surface(bar: .oled).clipShape(DiagonalHalf(trailing: true))
                }
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
        // A hairline, or the Light tile disappears: its surface is white
        // and so is the card it sits on, leaving three rings floating with
        // no tile under them.
        .settingsBorder(radius: Self.cornerRadius)
    }

    /// `bar`, not `style`: the automatic tile draws this twice, once per
    /// half, and neither call is itself automatic.
    private func surface(bar: Theme.BarStyle) -> some View {
        var theme = base
        theme.bar = bar
        return DrawerChrome(shape: Rectangle(), theme: theme, separatesFromBackdrop: false, size: Self.size)
            .overlay {
                HStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { _ in
                        CellRing(fraction: nil, tint: .clear, metrics: Self.ringMetrics, theme: theme)
                    }
                }
            }
            // `DrawerChrome` sets this environment on its own background
            // fill, which an `.overlay` attached outside it never inherits;
            // set it again here so the rings above pick the same light or
            // dark colour scheme the tile itself resolved to.
            .environment(\.colorScheme, theme.colorScheme(fallback: systemScheme))
    }
}

/// One triangular half of `FinishThumbnail`'s Follow macOS tile, split from
/// the top-right corner to the bottom-left.
private struct DiagonalHalf: Shape {
    /// `true` for the lower-right triangle, `false` for the upper-left.
    let trailing: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        if trailing {
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        } else {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        }
        path.closeSubpath()
        return path
    }
}
