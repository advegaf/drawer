import SwiftUI

/// The app's colours, sampled rather than invented.
enum Palette {
    static let notch         = Color.black                    // #000000
    static let frost        = Color(hex: 0xF5F5F7)
    static let card          = Color.black                    // #000000
    static let ringTrack     = Color(hex: 0x303030)
    static let barTrack      = Color(hex: 0x2D2D2D)

    static let critical      = Color(hex: 0xFF3F00)           // orange

    /// The arc colour for a toggle that is on, or a level's fill.
    static let on = Color.accentColor
    /// Opacity for a cell that is unavailable, not installed, or not found.
    static let ghost: Double = 0.45

    static let textPrimary   = Color.white
    static let textSecondary = Color(hex: 0x808080)

    /// The arc colour for a toggle that is on, or a level's fill, under a
    /// chosen theme. Presets are sampled close to macOS's own accent hues;
    /// system defers to whatever the user picked in System Settings.
    static func on(_ theme: Theme) -> Color {
        switch theme.accent {
        case .system: return Color.accentColor
        case .preset(let preset): return preset.color
        case .custom(let hex): return Color(hex: hex)
        }
    }

    static func primary(_ theme: Theme) -> Color {
        theme.bar == .oled ? .white : .primary
    }

    static func secondary(_ theme: Theme) -> Color {
        theme.bar == .oled ? Color(hex: 0xA0A0A0) : .secondary
    }

    static func track(_ theme: Theme) -> Color {
        theme.bar == .oled ? ringTrack : Color.primary.opacity(0.18)
    }

    static func border(_ theme: Theme) -> Color {
        theme.bar == .oled ? Color.white.opacity(0.22) : Color.primary.opacity(0.25)
    }

    static func notch(_ theme: Theme) -> Color {
        switch theme.bar {
        case .oled: return .black
        case .light: return frost
        case .automatic: return Color(nsColor: .windowBackgroundColor)
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue:  Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}
