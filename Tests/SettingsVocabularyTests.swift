import AppKit
import SwiftUI
import XCTest
@testable import Drawer

/// The row and card vocabulary the settings pages are built from, tested
/// on its own before any page uses it.
@MainActor
final class SettingsVocabularyTests: XCTestCase {
    // MARK: - Helpers

    /// Lays a view out in a real on-screen window, the same path
    /// `SettingsTests` uses, because AppKit-backed controls inside a
    /// hosting view do not lay out off screen.
    private func render<V: View>(_ view: V, width: CGFloat, height: CGFloat) -> NSBitmapImageRep? {
        let hostingView = NSHostingView(rootView: view.frame(width: width, height: height))
        hostingView.appearance = NSAppearance(named: .aqua)
        hostingView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: hostingView.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = hostingView
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        guard let rep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else { return nil }
        hostingView.cacheDisplay(in: hostingView.bounds, to: rep)
        return rep
    }

    /// The height a view asks for at a given width, which is what the row
    /// tests below are actually about.
    private func fittingHeight<V: View>(_ view: V, width: CGFloat) -> CGFloat {
        let hostingView = NSHostingView(rootView: view.frame(width: width))
        return hostingView.fittingSize.height
    }

    private func fittingWidth<V: View>(_ view: V) -> CGFloat {
        NSHostingView(rootView: view).fittingSize.width
    }

    private func isInked(_ rep: NSBitmapImageRep, x: Int, y: Int, unlike background: NSColor) -> Bool {
        guard let colour = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
              let base = background.usingColorSpace(.sRGB) else { return false }
        let delta = abs(colour.redComponent - base.redComponent)
            + abs(colour.greenComponent - base.greenComponent)
            + abs(colour.blueComponent - base.blueComponent)
        return delta > 0.08
    }

    // MARK: - The row

    /// All four parts of a row draw, and each in its own band: the symbol
    /// on the leading edge, the title beside it, the control hard right.
    /// Sampling bands rather than exact pixels because the glyph and the
    /// text metrics are the system's, not ours.
    func testRowDrawsItsSymbolTitleAndControl() throws {
        let row = SettingsRow("Brightness", symbol: "sun.max", subtitle: "Screen brightness") {
            Text("Ninety")
        }
        .padding(.horizontal, 16)
        .background(Color.white)

        let rep = try XCTUnwrap(render(row, width: 400, height: 60), "row produced no image")
        let scale = CGFloat(rep.pixelsWide) / 400
        func inkedColumn(from: CGFloat, to: CGFloat) -> Bool {
            for x in stride(from: Int(from * scale), to: Int(to * scale), by: 1) {
                for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
                    if isInked(rep, x: x, y: y, unlike: .white) { return true }
                }
            }
            return false
        }
        // The symbol sits in its own 24pt column starting at the padding.
        XCTAssertTrue(inkedColumn(from: 16, to: 40), "no symbol in the leading column")
        // The title and subtitle share the band after the 16pt gap.
        XCTAssertTrue(inkedColumn(from: 56, to: 200), "no title in the label column")
        // The control is pushed to the trailing edge by the spacer.
        XCTAssertTrue(inkedColumn(from: 320, to: 384), "no control on the trailing edge")
    }

    /// A subtitle is a second line inside the row, so the row gets taller
    /// rather than the subtitle being dropped or clipped.
    func testASubtitleMakesTheRowTaller() {
        let bare = SettingsRow("Edge", symbol: "rectangle.righthalf.inset.filled") { Text("Right") }
        let withSubtitle = SettingsRow("Edge", symbol: "rectangle.righthalf.inset.filled",
                                       subtitle: "Which side of the screen the drawer lives on") { Text("Right") }
        XCTAssertGreaterThan(fittingHeight(withSubtitle, width: 400),
                             fittingHeight(bare, width: 400),
                             "the subtitle did not add a line")
    }

    /// A row with a tall control grows to hold it. The finish thumbnails
    /// are the real case: they are far taller than a toggle and must not
    /// be clipped to a toggle's row height.
    func testATallControlGrowsTheRowInsteadOfBeingClipped() {
        let row = SettingsRow("Finish", symbol: "circle.lefthalf.filled") {
            Color.clear.frame(width: 120, height: 80)
        }
        XCTAssertGreaterThanOrEqual(fittingHeight(row, width: 400), 80,
                                    "the row clipped its control instead of growing")
    }

    /// A long subtitle wraps onto another line rather than truncating,
    /// which is what `fixedSize(horizontal:vertical:)` on it is for.
    func testALongSubtitleWrapsRatherThanTruncating() {
        let short = SettingsRow("Show", symbol: "eye", subtitle: "Always") { Text("On") }
        let long = SettingsRow("Show", symbol: "eye",
                               subtitle: String(repeating: "Show the drawer whenever the pointer reaches the edge. ", count: 3)) { Text("On") }
        XCTAssertGreaterThan(fittingHeight(long, width: 400), fittingHeight(short, width: 400),
                             "the long subtitle was truncated to one line")
    }

    // MARK: - The card

    /// The card paints its own surface and rounds its corners, so the very
    /// corner pixel is still the page behind it rather than card fill.
    func testCardPaintsItsSurfaceAndRoundsItsCorners() throws {
        let page = SettingsCard { Color.clear.frame(height: 80) }
            .padding(20)
            .background(Color.black)

        let rep = try XCTUnwrap(render(page, width: 300, height: 160), "card produced no image")
        let scale = CGFloat(rep.pixelsWide) / 300

        let middle = try XCTUnwrap(rep.colorAt(x: Int(150 * scale), y: Int(80 * scale))?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(middle.brightnessComponent, 0.5, "the card did not paint its own surface")

        // One point inside the card's bounding box at its top-left corner,
        // which a 12pt radius has cut away.
        let corner = try XCTUnwrap(rep.colorAt(x: Int(21 * scale), y: Int(21 * scale))?.usingColorSpace(.sRGB))
        XCTAssertLessThan(corner.brightnessComponent, 0.5, "the card's corner is square, not rounded")
    }

    // MARK: - Tokens

    /// Every colour role resolves to a different value in light and dark.
    /// A role that came out identical in both would be one somebody forgot
    /// to give a dark value, and it would go unnoticed until a capture.
    func testEveryColourRoleResolvesDifferentlyInLightAndDark() throws {
        let roles: [(String, Color)] = [
            ("canvas", SettingsStyle.canvas), ("ink", SettingsStyle.ink),
            ("display", SettingsStyle.display), ("accent", SettingsStyle.accent),
            ("textSecondary", SettingsStyle.textSecondary), ("textTertiary", SettingsStyle.textTertiary),
            ("border", SettingsStyle.border), ("surfaceHover", SettingsStyle.surfaceHover),
            ("sidebar", SettingsStyle.sidebar),
        ]
        let light = try XCTUnwrap(NSAppearance(named: .aqua))
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        for (name, role) in roles {
            var lightColour: NSColor?
            var darkColour: NSColor?
            light.performAsCurrentDrawingAppearance { lightColour = NSColor(role).usingColorSpace(.sRGB) }
            dark.performAsCurrentDrawingAppearance { darkColour = NSColor(role).usingColorSpace(.sRGB) }
            XCTAssertNotEqual(lightColour, darkColour, "\(name) is the same in light and dark")
        }
    }

    /// `settingsFont` has to carry the tracking as well as the size, since
    /// a call site that took only the font would silently lose it.
    func testSettingsFontAppliesBothSizeAndTracking() {
        let sample = "MMMMMMMM"
        let plain = fittingWidth(Text(sample).settingsFont(SettingsStyle.micro))
        let tracked = fittingWidth(Text(sample).settingsFont(
            SettingsStyle.Style(size: SettingsStyle.micro.size,
                                weight: SettingsStyle.micro.weight,
                                tracking: SettingsStyle.micro.tracking + 4)))
        XCTAssertGreaterThan(tracked, plain, "tracking was not applied")

        let big = fittingWidth(Text(sample).settingsFont(SettingsStyle.sectionHeading))
        XCTAssertGreaterThan(big, plain, "the size was not applied")
    }

    /// The scale is ordered and has no duplicates. A repeated or reversed
    /// step would let two different gaps render identically and quietly
    /// undo the reason for having a scale at all.
    func testTheSpacingAndRadiusScalesAreStrictlyIncreasing() {
        let spacing = [SettingsStyle.s2, SettingsStyle.s4, SettingsStyle.s6, SettingsStyle.s8,
                       SettingsStyle.s12, SettingsStyle.s16, SettingsStyle.s20, SettingsStyle.s24,
                       SettingsStyle.s32, SettingsStyle.s48, SettingsStyle.s64, SettingsStyle.s80]
        XCTAssertEqual(spacing, spacing.sorted())
        XCTAssertEqual(Set(spacing).count, spacing.count)

        let radius = [SettingsStyle.r4, SettingsStyle.r6, SettingsStyle.r8,
                      SettingsStyle.r12, SettingsStyle.r16, SettingsStyle.pill]
        XCTAssertEqual(radius, radius.sorted())
        XCTAssertEqual(Set(radius).count, radius.count)
    }
}
