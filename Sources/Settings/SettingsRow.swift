import SwiftUI

/// One setting, drawn as a row: a symbol, a name, an optional line of
/// explanation under it, and the control that changes it, hard right.
///
/// The shape is the point. A column of these puts every label on one
/// leading edge and every control on one trailing edge, so the eye runs
/// down two straight lines instead of hunting through stacked pickers
/// with paragraphs wedged between them.
struct SettingsRow<Control: View>: View {
    let title: String
    let symbol: String
    let subtitle: String?
    @ViewBuilder let control: () -> Control

    init(_ title: String, symbol: String, subtitle: String? = nil,
         @ViewBuilder control: @escaping () -> Control) {
        self.title = title
        self.symbol = symbol
        self.subtitle = subtitle
        self.control = control
    }

    var body: some View {
        HStack(alignment: .center, spacing: SettingsStyle.s16) {
            // A fixed 24pt column, not the glyph's own width: SF Symbols
            // are not all the same width, and without the frame every row
            // would start its title at a slightly different place.
            Image(systemName: symbol)
                .font(.system(size: 16))
                .frame(width: 24)
                .foregroundStyle(SettingsStyle.textSecondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: SettingsStyle.s2) {
                Text(title)
                    .settingsFont(SettingsStyle.bodyMedium)
                    .foregroundStyle(SettingsStyle.ink)
                if let subtitle {
                    Text(subtitle)
                        .settingsFont(SettingsStyle.captionLight)
                        .foregroundStyle(SettingsStyle.textSecondary)
                        // Wrap rather than truncate: some of these lines
                        // are a full sentence and the row is allowed to
                        // grow to hold them.
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: SettingsStyle.s8)
            control()
        }
        // Vertical only. The card around the row supplies the horizontal
        // inset, so a row never has to know how wide its card's padding is.
        .padding(.vertical, SettingsStyle.s8)
    }
}

/// The title above a card's rows, with an optional second line and an
/// optional control of its own on the right.
struct SettingsSectionHeader<Trailing: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let trailing: () -> Trailing

    init(_ title: String, subtitle: String? = nil,
         @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        // First text baseline, not centre: the trailing view is usually a
        // small control, and aligning boxes would float it above the
        // heading's baseline instead of sitting on it.
        HStack(alignment: .firstTextBaseline, spacing: SettingsStyle.s12) {
            VStack(alignment: .leading, spacing: SettingsStyle.s4) {
                Text(title)
                    .settingsFont(SettingsStyle.sectionHeading)
                    .foregroundStyle(SettingsStyle.ink)
                if let subtitle {
                    // `lineLimit` is not about the look, it is about the
                    // least height this can claim. A wrapping label that
                    // is free to grow answers a zero width proposal, which
                    // is how AppKit measures the window, with one word per
                    // line: this one line of text alone asked for 640pt
                    // and opened the settings window as tall as the
                    // screen. Two lines is more than either subtitle here
                    // needs and is a bound the window can live with.
                    Text(subtitle)
                        .settingsFont(SettingsStyle.body)
                        .foregroundStyle(SettingsStyle.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            trailing()
        }
    }
}

extension SettingsSectionHeader where Trailing == EmptyView {
    init(_ title: String, subtitle: String? = nil) {
        self.init(title, subtitle: subtitle) { EmptyView() }
    }
}
