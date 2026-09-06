import SwiftUI

/// Sizes are derived from cap heights measured in design pixels, so they
/// track `Design.scale` along with everything else.
enum Typography {
    /// The card's title. Cap height 26px.
    static let cardTitle = Font.system(size: Design.fontSize(capPixels: 26), weight: .semibold)
    /// Scaled by the theme's card text size.
    static func cardTitle(_ metrics: Metrics) -> Font {
        .system(size: Design.fontSize(capPixels: 26) * metrics.cardTextScale, weight: .semibold)
    }

    /// The card's body text. Cap height 21px.
    static let cardBody = Font.system(size: Design.fontSize(capPixels: 21), weight: .regular)
    /// Scaled by the theme's card text size.
    static func cardBody(_ metrics: Metrics) -> Font {
        .system(size: Design.fontSize(capPixels: 21) * metrics.cardTextScale, weight: .regular)
    }

    /// The cell's title under the ring, when labels are on. Cap height 22px,
    /// which comes out to about 11.6pt. Not scaled by the theme: a label is
    /// either shown or not, at one fixed size.
    static let cellLabel = Font.system(size: Design.fontSize(capPixels: 22), weight: .medium)
}
