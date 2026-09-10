import SwiftUI

/// A rounded panel holding one group of settings rows.
///
/// The window is built out of these: a page is a column of cards on the
/// canvas with air between them, rather than a single sheet of controls.
/// The card carries the near surface, so the canvas behind it reads as
/// the page and the card reads as the thing you act on.
enum SettingsCardStyle {
    /// Every ordinary group of rows.
    case standard
    /// A card that has to sit above the others, such as one carrying the
    /// drawer preview. Larger corner, deeper shadow.
    case hero
}

struct SettingsCard<Content: View>: View {
    let style: SettingsCardStyle
    let padding: CGFloat
    @ViewBuilder let content: () -> Content

    init(style: SettingsCardStyle = .standard, padding: CGFloat = SettingsStyle.s16,
         @ViewBuilder content: @escaping () -> Content) {
        self.style = style
        self.padding = padding
        self.content = content
    }

    private var cornerRadius: CGFloat {
        switch style {
        case .standard: SettingsStyle.r12
        case .hero: SettingsStyle.r16
        }
    }

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SettingsStyle.display)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .settingsBorder(radius: cornerRadius)
            .modifier(CardShadow(style: style))
    }
}

private struct CardShadow: ViewModifier {
    let style: SettingsCardStyle
    func body(content: Content) -> some View {
        switch style {
        case .standard: content.settingsSoftShadow()
        case .hero: content.settingsDeepShadow()
        }
    }
}

extension View {
    /// The hairline around a card. `strokeBorder` rather than `stroke` so
    /// the line sits inside the shape and does not straddle the clip the
    /// card already applied, which would leave it half a point soft.
    func settingsBorder(radius: CGFloat = SettingsStyle.r12) -> some View {
        overlay(RoundedRectangle(cornerRadius: radius)
            .strokeBorder(SettingsStyle.border, lineWidth: 1))
    }

    /// Four shadows rather than one. Each is nearly invisible on its own,
    /// and stacking them from a one point blur out to eighteen gives a
    /// falloff that reads as a card resting on the page instead of a
    /// rectangle with a grey edge under it.
    func settingsSoftShadow() -> some View {
        shadow(color: .black.opacity(0.04), radius: 18, y: 4)
            .shadow(color: .black.opacity(0.027), radius: 7.85, y: 2.025)
            .shadow(color: .black.opacity(0.02), radius: 2.93, y: 0.8)
            .shadow(color: .black.opacity(0.01), radius: 1.04, y: 0.175)
    }

    /// The same idea carried further, out to a fifty two point blur, for
    /// the one card on a page that has to float above the rest.
    func settingsDeepShadow() -> some View {
        shadow(color: .black.opacity(0.01), radius: 3, y: 1)
            .shadow(color: .black.opacity(0.02), radius: 7, y: 3)
            .shadow(color: .black.opacity(0.02), radius: 15, y: 7)
            .shadow(color: .black.opacity(0.04), radius: 28, y: 14)
            .shadow(color: .black.opacity(0.05), radius: 52, y: 23)
    }
}
