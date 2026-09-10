import AppKit
import SwiftUI

enum SettingsStyle {
    static let canvas = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? .windowBackgroundColor : NSColor(srgbRed: 245/255, green: 245/255, blue: 247/255, alpha: 1)
    })
    static let ink = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? .labelColor : NSColor(srgbRed: 29/255, green: 29/255, blue: 31/255, alpha: 1)
    })
    static let display = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? .controlBackgroundColor : .white
    })
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? .systemBlue : NSColor(srgbRed: 0, green: 113/255, blue: 227/255, alpha: 1)
    })

    // Text and surface roles the four colours above do not cover. Built
    // with the same dynamic provider so a light-to-dark switch repaints
    // them live rather than at the next window rebuild.

    /// Captions, subtitles, and a row's leading symbol.
    static let textSecondary = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 163/255, green: 158/255, blue: 152/255, alpha: 1)
            : NSColor(srgbRed: 97/255, green: 93/255, blue: 89/255, alpha: 1)
    })

    /// The faintest readable text: the sidebar's version and copyright
    /// lines. Light and dark are the two `textSecondary` values swapped,
    /// which is what keeps it a step quieter than `textSecondary` in both.
    static let textTertiary = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 97/255, green: 93/255, blue: 89/255, alpha: 1)
            : NSColor(srgbRed: 163/255, green: 158/255, blue: 152/255, alpha: 1)
    })

    /// The one colour that means the click takes something away. Only the
    /// library's Remove chip uses it, and it is the system red rather than a
    /// picked one so it reads as danger in both appearances and follows an
    /// increased-contrast setting.
    static let danger = Color(nsColor: .systemRed)

    /// A card's outline. Thin enough to read as a division rather than a
    /// frame: any heavier and a page of cards looks like a table.
    static let border = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.08) : NSColor(white: 0, alpha: 0.10)
    })

    /// The fill under a pointer resting on a sidebar row.
    static let surfaceHover = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 51/255, green: 49/255, blue: 41/255, alpha: 1)
            : NSColor(srgbRed: 240/255, green: 238/255, blue: 235/255, alpha: 1)
    })

    /// The sidebar's own fill. Lighter than `canvas` in light mode on
    /// purpose: the column reads as the near surface and the pages behind
    /// it as the far one, which is the opposite of a stock macOS sidebar
    /// and is what stops the window looking like two grey panels.
    static let sidebar = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 27/255, green: 26/255, blue: 25/255, alpha: 1) : .white
    })

    // MARK: - Spacing

    // One scale for the whole settings window. Every gap and inset comes
    // from here, which is what makes the pages line up with each other
    // instead of each one picking its own numbers.
    static let s2: CGFloat = 2
    static let s4: CGFloat = 4
    static let s6: CGFloat = 6
    static let s8: CGFloat = 8
    static let s12: CGFloat = 12
    static let s16: CGFloat = 16
    static let s20: CGFloat = 20
    static let s24: CGFloat = 24
    static let s32: CGFloat = 32
    static let s48: CGFloat = 48
    static let s64: CGFloat = 64
    static let s80: CGFloat = 80

    // MARK: - Corner radius

    static let r4: CGFloat = 4
    static let r6: CGFloat = 6
    static let r8: CGFloat = 8
    static let r12: CGFloat = 12
    static let r16: CGFloat = 16
    /// Large enough that any control this clips comes out a capsule.
    static let pill: CGFloat = 999

    /// Width of the settings window's left column. Only the sidebar reads
    /// it now: the pages fill whatever is left beside it rather than
    /// pinning their own controls to the same width.
    static let sidebarWidth: CGFloat = 220

    /// The app icon beside the wordmark at the top of the sidebar.
    ///
    /// Measured rather than chosen. macOS normalises an app icon to its own
    /// grid and leaves a transparent margin around the artwork, so the frame
    /// is always larger than what gets drawn: at 32 the sidebar drew 26pt of
    /// icon, which reads small beside a 17pt wordmark. At 38 it draws 31, and
    /// macOS still reaches for the 64 pixel export, so nothing is upscaled.
    static let brandIcon: CGFloat = 38

    /// The smallest the settings window goes, and the only place that
    /// number lives: the window controller and the split view both read it,
    /// so they cannot drift apart.
    ///
    /// Fixed rather than per page, because a floor that moves as you switch
    /// pages resizes the window under the pointer. The height is what an
    /// Items page needs with a preview worth looking at: 800 leaves a 279pt
    /// canvas and two library rows, where 700 would leave 165pt, smaller
    /// than a canvas the user has already called too small. It also stays
    /// under the roughly 850pt a 13 inch display leaves free.
    static let windowMinimum = CGSize(width: 900, height: 800)

    /// The height of the titlebar SwiftUI insets a `fullSizeContentView`
    /// window's content by.
    ///
    /// It matters because a minimum set on the split view is a minimum for
    /// what sits *below* the titlebar, so the window's own floor comes out
    /// this much taller: measured on the running app, a 600 minimum on the
    /// view gave a window that stopped at 652.
    static let titlebarInset: CGFloat = 52

    /// What an Items page needs beside its preview canvas, measured off the
    /// running window's accessibility tree at the default size: 48 of page
    /// padding, 188 of preview card around the canvas (32 padding, a 44
    /// header, two 12 gaps and the 88 block under the canvas), the 24
    /// between the cards, and 125 of library card above its list (32
    /// padding, a 24 header, a 32 search field, a divider and three 12
    /// gaps), plus 84 for two library rows so the library is still a
    /// library.
    ///
    /// `ItemsPage.canvasHeight` subtracts it, which is what keeps the page
    /// inside the window at every height rather than only at the default.
    static let itemsPageReserve: CGFloat = 469
}

// MARK: - Type

extension SettingsStyle {
    /// One rung of the settings window's type ladder. Tracking travels with
    /// the size because the two are not separable: the large sizes need
    /// negative tracking to stop reading as loose, and the small ones need
    /// a touch of positive tracking to stay legible.
    struct Style {
        let size: CGFloat
        let weight: Font.Weight
        let tracking: CGFloat
        var swiftUIFont: Font { .system(size: size, weight: weight, design: .default) }
    }

    static let displayHero = Style(size: 36, weight: .bold, tracking: -1.2)
    static let displayLarge = Style(size: 28, weight: .bold, tracking: -0.8)
    static let displayMedium = Style(size: 24, weight: .bold, tracking: -0.6)
    static let sectionHeading = Style(size: 20, weight: .bold, tracking: -0.4)
    static let cardTitle = Style(size: 17, weight: .semibold, tracking: -0.2)
    static let bodyLarge = Style(size: 15, weight: .medium, tracking: 0)
    static let body = Style(size: 13, weight: .regular, tracking: 0)
    static let bodyMedium = Style(size: 13, weight: .medium, tracking: 0)
    static let bodySemibold = Style(size: 13, weight: .semibold, tracking: 0)
    static let nav = Style(size: 13, weight: .semibold, tracking: 0)
    static let caption = Style(size: 11, weight: .medium, tracking: 0)
    static let captionLight = Style(size: 11, weight: .regular, tracking: 0)
    static let badge = Style(size: 10, weight: .semibold, tracking: 0.3)
    static let micro = Style(size: 10, weight: .regular, tracking: 0.2)
}

extension View {
    /// Size, weight and tracking in one call, so no call site can take the
    /// font from the ladder and then forget the tracking that goes with it.
    func settingsFont(_ style: SettingsStyle.Style) -> some View {
        font(style.swiftUIFont).tracking(style.tracking)
    }
}

struct SettingsSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(SettingsStyle.ink.opacity(isEnabled ? 1 : 0.4))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(isFocused ? SettingsStyle.accent.opacity(0.16) : SettingsStyle.ink.opacity(configuration.isPressed ? 0.13 : 0.07), in: RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .leading) {
                Capsule().fill(SettingsStyle.accent).frame(width: 3, height: 14)
                    .opacity(isFocused ? 1 : 0)
            }
            .contentShape(Rectangle())
    }
}
