import AppKit
import SwiftUI

/// The drawer appearance persisted by `Preferences.theme`.
struct Theme: Hashable, Codable {
    enum Accent: Hashable, Codable {
        case system, preset(Preset), custom(hex: UInt32)
    }

    enum Preset: String, CaseIterable, Codable {
        case blue, purple, pink, red, orange, yellow, green, graphite
    }

    enum BarStyle: String, CaseIterable, Codable {
        case automatic
        case oled = "black"
        case light

        var title: String {
            switch self {
            case .automatic: return "Follow macOS"
            case .oled: return "OLED"
            case .light: return "Light"
            }
        }

        /// Every legacy and alias input a saved theme could still carry.
        /// `Theme.init(from:)` decodes `bar` with `decodeIfPresent`, and a
        /// thrown error there propagates out of the whole decode; `Preferences`
        /// catches that with `try?` and discards the entire theme blob (accent,
        /// cell size, labels, card text), not just the finish. So an unrecognised
        /// string here has to fall back to a real case rather than fail: `black`,
        /// `graphite` and `oled` keep meaning OLED; `material` and `liquidGlass`,
        /// the former Liquid Glass finish, and `adaptive`, the former Adapt to
        /// background finish, all fall back to Follow macOS rather than losing
        /// the rest of the user's saved look.
        init?(input: String) {
            switch input {
            case "automatic", "adaptive", "material", "liquidGlass": self = .automatic
            case "light": self = .light
            case "black", "graphite", "oled": self = .oled
            default: return nil
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let style = Self(input: value) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown drawer finish")
            }
            self = style
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    enum CellSize: String, CaseIterable, Codable {
        case compact, regular, large
    }

    enum CardText: String, CaseIterable, Codable {
        case regular, large
    }

    var accent: Accent = .system
    var bar: BarStyle = .oled
    var cellSize: CellSize = .regular
    var showsLabels: Bool = false
    var cardText: CardText = .regular

    static let `default` = Theme()

    /// What `NotchLayout` actually reads. Derived here so layout code takes
    /// one small value type instead of the whole theme.
    var metrics: Metrics {
        Metrics(cellScale: cellSize.scale, showsLabels: showsLabels, cardTextScale: cardText.scale)
    }
}

/// The geometry side of a `Theme`. Every `NotchLayout` function that moves
/// with the theme takes one of these, defaulted, so untouched call sites and
/// tests keep compiling.
struct Metrics: Hashable {
    let cellScale: CGFloat
    let showsLabels: Bool
    let cardTextScale: CGFloat
    static let `default` = Metrics(cellScale: 1, showsLabels: false, cardTextScale: 1)
}

private extension Theme.CellSize {
    var scale: CGFloat {
        switch self {
        case .compact: return 0.82
        case .regular: return 1
        case .large: return 1.18
        }
    }
}

private extension Theme.CardText {
    var scale: CGFloat {
        switch self {
        case .regular: return 1
        case .large: return 1.15
        }
    }
}

extension Color {
    /// The reverse of `init(hex:)`, for a `ColorPicker` binding that has to
    /// turn a chosen `Color` back into `Theme.Accent.custom(hex:)`. Nil when
    /// the colour cannot be read back in sRGB, which a `ColorPicker` should
    /// never actually hand back.
    var hex: UInt32? {
        guard let srgb = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        let r = UInt32((srgb.redComponent * 255).rounded())
        let g = UInt32((srgb.greenComponent * 255).rounded())
        let b = UInt32((srgb.blueComponent * 255).rounded())
        return (r << 16) | (g << 8) | b
    }
}

extension Theme.Preset {
    /// Close to macOS's own accent hues, not lifted from a private API.
    var color: Color {
        switch self {
        case .blue:     return Color(hex: 0x007AFF)
        case .purple:   return Color(hex: 0xAF52DE)
        case .pink:     return Color(hex: 0xFF2D55)
        case .red:      return Color(hex: 0xFF3B30)
        case .orange:   return Color(hex: 0xFF9500)
        case .yellow:   return Color(hex: 0xFFCC00)
        case .green:    return Color(hex: 0x34C759)
        case .graphite: return Color(hex: 0x8E8E93)
        }
    }
}

extension Theme {
    /// The compact form a screenshot's `DRAWER_THEME` env var uses:
    /// `accent=purple,bar=oled,cell=large,labels=1,card=large`. An
    /// unknown key or an unknown value for a known key is skipped rather
    /// than failing the whole string, so a typo loses one field instead of
    /// the whole demo run.
    init?(demoString: String) {
        guard !demoString.isEmpty else { return nil }
        var theme = Theme.default
        for pair in demoString.split(separator: ",") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let value = String(parts[1])
            switch parts[0] {
            case "accent":
                if value == "system" {
                    theme.accent = .system
                } else if let preset = Preset(rawValue: value) {
                    theme.accent = .preset(preset)
                } else if let hex = UInt32(
                    value.hasPrefix("0x") ? String(value.dropFirst(2)) : value, radix: 16
                ) {
                    theme.accent = .custom(hex: hex)
                }
            case "bar":
                if let bar = BarStyle(input: value) { theme.bar = bar }
            case "cell":
                if let size = CellSize(rawValue: value) { theme.cellSize = size }
            case "labels":
                theme.showsLabels = value == "1"
            case "card":
                if let text = CardText(rawValue: value) { theme.cardText = text }
            default:
                break
            }
        }
        self = theme
    }

    /// The inverse of `init?(demoString:)`, so a round trip test does not
    /// have to restate the format by hand.
    var demoString: String {
        let accentPart: String
        switch accent {
        case .system: accentPart = "system"
        case .preset(let preset): accentPart = preset.rawValue
        case .custom(let hex): accentPart = String(format: "0x%06X", hex)
        }
        return "accent=\(accentPart),bar=\(bar.rawValue),cell=\(cellSize.rawValue),"
             + "labels=\(showsLabels ? "1" : "0"),card=\(cardText.rawValue)"
    }
}


extension Theme {
    private enum CodingKeys: String, CodingKey {
        case accent, bar, cellSize, showsLabels, cardText
    }

    /// A stored `glassAppearance` key from an older save is simply not in
    /// this list, so keyed decoding ignores it rather than needing migration
    /// code to strip it out.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accent = try container.decodeIfPresent(Accent.self, forKey: .accent) ?? .system
        bar = try container.decodeIfPresent(BarStyle.self, forKey: .bar) ?? .oled
        cellSize = try container.decodeIfPresent(CellSize.self, forKey: .cellSize) ?? .regular
        showsLabels = try container.decodeIfPresent(Bool.self, forKey: .showsLabels) ?? false
        cardText = try container.decodeIfPresent(CardText.self, forKey: .cardText) ?? .regular
    }

    func resolved(system: ColorScheme) -> Theme {
        var result = self
        if bar == .automatic {
            result.bar = system == .dark ? .oled : .light
        }
        return result
    }

    func colorScheme(fallback: ColorScheme) -> ColorScheme {
        switch bar {
        case .oled: return .dark
        case .light: return .light
        case .automatic: return fallback
        }
    }
}
