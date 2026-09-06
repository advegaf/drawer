import SwiftUI
import XCTest
@testable import Drawer

/// `Theme` round trips through `Preferences`, the same way every other
/// stored preference does: a throwaway `UserDefaults` suite, absent means
/// default, garbage means default.
@MainActor
final class ThemePreferencesTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "ThemePreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testAbsentKeyGivesTheDefaultTheme() {
        XCTAssertEqual(Preferences(defaults: defaults()).theme, .default)
    }

    func testGarbageDataFallsBackToTheDefaultTheme() {
        let store = defaults()
        store.set(Data([0xFF, 0x00, 0x12]), forKey: "theme")
        XCTAssertEqual(Preferences(defaults: store).theme, .default)
    }

    func testLegacyGraphitePreferenceKeepsOtherAppearanceChoices() throws {
        let store = defaults()
        var expected = Theme.default
        expected.accent = .preset(.purple)
        expected.cellSize = .large
        expected.showsLabels = true
        expected.cardText = .large
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(expected)) as? [String: Any])
        object["bar"] = "graphite"
        store.set(try JSONSerialization.data(withJSONObject: object), forKey: "theme")
        XCTAssertEqual(Preferences(defaults: store).theme, expected)
    }

    /// The migration a real user's saved theme depends on: a `bar` of
    /// `"material"`, the old Liquid Glass finish, has to decode to a real
    /// `BarStyle` rather than throw, or `Preferences`'s `try?` around the
    /// whole decode would discard the accent, cell size, labels and card
    /// text alongside it.
    func testStoredMaterialFinishMigratesToFollowMacOSWithoutLosingOtherFields() throws {
        let store = defaults()
        var expected = Theme.default
        expected.accent = .preset(.orange)
        expected.bar = .automatic
        expected.cellSize = .large
        expected.showsLabels = true
        expected.cardText = .large
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(expected)) as? [String: Any])
        object["bar"] = "material"
        store.set(try JSONSerialization.data(withJSONObject: object), forKey: "theme")
        XCTAssertEqual(Preferences(defaults: store).theme, expected)
    }

    func testAChoiceSurvivesARestart() {
        let store = defaults()
        var theme = Theme.default
        theme.accent = .preset(.purple)
        theme.bar = .light
        theme.cellSize = .large
        theme.showsLabels = true
        theme.cardText = .large
        Preferences(defaults: store).theme = theme
        XCTAssertEqual(Preferences(defaults: store).theme, theme)
    }
}

/// Every preset actually offered, and the demo string that a screenshot's
/// `DRAWER_THEME` env var uses.
final class ThemeDemoStringTests: XCTestCase {
    func testEveryPresetIsOffered() {
        XCTAssertEqual(Theme.Preset.allCases.count, 8)
    }

    /// Round tripped field by field, since a single fixed theme would only
    /// prove the fields it happens to set.
    func testTheDemoStringRoundTripsEveryField() {
        var themes: [Theme] = [.default]

        for preset in Theme.Preset.allCases {
            var theme = Theme.default
            theme.accent = .preset(preset)
            themes.append(theme)
        }
        var custom = Theme.default
        custom.accent = .custom(hex: 0x336699)
        themes.append(custom)

        for bar in Theme.BarStyle.allCases {
            var theme = Theme.default
            theme.bar = bar
            themes.append(theme)
        }
        for size in Theme.CellSize.allCases {
            var theme = Theme.default
            theme.cellSize = size
            themes.append(theme)
        }
        for text in Theme.CardText.allCases {
            var theme = Theme.default
            theme.cardText = text
            themes.append(theme)
        }
        var labeled = Theme.default
        labeled.showsLabels = true
        themes.append(labeled)

        for theme in themes {
            XCTAssertEqual(Theme(demoString: theme.demoString), theme, "\(theme.demoString)")
        }
    }

    func testAnEmptyStringDoesNotParse() {
        XCTAssertNil(Theme(demoString: ""))
    }

    func testTheMakefileExampleParses() {
        let theme = Theme(demoString: "accent=purple,bar=oled,cell=large,labels=1,card=large")
        XCTAssertEqual(theme?.accent, .preset(.purple))
        XCTAssertEqual(theme?.bar, .oled)
        XCTAssertEqual(theme?.cellSize, .large)
        XCTAssertEqual(theme?.showsLabels, true)
        XCTAssertEqual(theme?.cardText, .large)
    }
}

/// The geometry a cell-size change actually moves.
final class ThemeLayoutTests: XCTestCase {
    func testRingDiameterGrowsWithCellSize() {
        var theme = Theme.default
        theme.cellSize = .compact
        let compact = NotchLayout.ringDiameter(theme.metrics)
        theme.cellSize = .regular
        let regular = NotchLayout.ringDiameter(theme.metrics)
        theme.cellSize = .large
        let large = NotchLayout.ringDiameter(theme.metrics)
        XCTAssertLessThan(compact, regular)
        XCTAssertLessThan(regular, large)
    }

    func testCardTitleLineHeightGrowsWithCardTextSize() {
        var theme = Theme.default
        let regular = NotchLayout.cardTitleLineHeight(theme.metrics)
        theme.cardText = .large
        XCTAssertLessThan(regular, NotchLayout.cardTitleLineHeight(theme.metrics))
    }

    @MainActor
    func testFitCountIsNonIncreasingAsCellsGrow() {
        let model = NotchViewModel()
        model.edge = .right
        model.adopt(screen: FakeScreen(
            frameValue: CGRect(x: 0, y: 0, width: 1800, height: 1169),
            visibleFrameValue: CGRect(x: 0, y: 59, width: 1800, height: 1071)
        ))

        var theme = Theme.default
        theme.cellSize = .compact
        model.theme = theme
        let compact = model.fitCount

        theme.cellSize = .regular
        model.theme = theme
        let regular = model.fitCount

        theme.cellSize = .large
        model.theme = theme
        let large = model.fitCount

        XCTAssertGreaterThanOrEqual(compact, regular, "a smaller cell should fit at least as many")
        XCTAssertGreaterThanOrEqual(regular, large, "a bigger cell should fit no more")
    }
}

/// The room a label claims goes to the dimension the stack actually runs
/// along, and not to the other one.
final class ThemeLabelGeometryTests: XCTestCase {
    private var labeled: Metrics {
        var theme = Theme.default
        theme.showsLabels = true
        return theme.metrics
    }

    func testLabelsWidenCellExtentOnAVerticalEdge() {
        let plain = NotchLayout.cellExtent()
        let withLabels = NotchLayout.cellExtent(labeled)
        XCTAssertEqual(withLabels - plain, NotchLayout.labelGap + NotchLayout.cellLabelLineHeight, accuracy: 0.001)
        XCTAssertEqual(NotchLayout.cellAlong(for: .right, metrics: labeled), withLabels, accuracy: 0.001)
    }

    /// Reversed from an earlier pass, which kept a vertical edge's
    /// `bodyDepth` fixed and shrank the label to fit inside it instead. That
    /// truncated real titles too hard to read ("Bluetooth" to "Bluet...");
    /// the bar grows to fit the label now, not the other way round (see
    /// `docs/qa/decisions.md` Phase 24).
    func testLabelsDeepenBodyDepthOnAVerticalEdgeToFitTheLabelInstead() {
        let labeledDepth = NotchLayout.bodyDepth(for: .right, metrics: labeled)
        let margin = NotchLayout.ringMargin(for: .right, metrics: labeled)

        // The label's own frame, at the ring's clearance on both sides.
        XCTAssertEqual(labeledDepth, NotchLayout.cellLabelWidth + 2 * margin, accuracy: 0.001)
        // The ring itself does not move: its margin from the bezel is the
        // same with labels on or off, so the extra room lands on the inner
        // side, where the card lobe attaches, not the bezel side.
        XCTAssertEqual(margin, NotchLayout.ringMargin(for: .right), accuracy: 0.001)
    }
}

/// A rendered cell, checked for ink rather than trusted on layout maths
/// alone, the same idiom `CellRenderTests` uses for the whole column.
@MainActor
final class ThemeLabelRenderTests: XCTestCase {
    private func render(_ view: some View, size: CGSize) -> NSBitmapImageRep? {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = 1
        guard let image = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: image)
    }

    func testALabelPaintsInkBelowTheRing() {
        var theme = Theme.default
        theme.showsLabels = true
        let metrics = theme.metrics
        let cell = Fixtures.cells(1)[0]
        // Wide enough to hold the label's own frame: narrower than
        // `cellLabelWidth` would let the render clip the very ink this test
        // is checking for.
        let size = CGSize(width: NotchLayout.cellLabelWidth, height: NotchLayout.cellExtent(metrics))

        guard let rep = render(DrawerCellView(cell: cell, theme: theme), size: size) else {
            XCTFail("the labelled cell produced no image at all")
            return
        }

        let ringBottom = Int(NotchLayout.ringDiameter(metrics))
        var inked = false
        for y in stride(from: ringBottom, to: Int(size.height), by: 1) where !inked {
            for x in stride(from: 0, to: Int(size.width), by: 3) {
                if let colour = rep.colorAt(x: x, y: y), colour.alphaComponent > 0.1 {
                    inked = true
                    break
                }
            }
        }
        XCTAssertTrue(inked, "no ink was painted below the ring with labels on")
    }
}

/// `ScreenDescribing` faked for a test.
private struct FakeScreen: ScreenDescribing {
    var frameValue: CGRect
    var visibleFrameValue: CGRect
}

final class ThemeFinishCompatibilityTests: XCTestCase {
    func testOnlySupportedFinishesAreOfferedWithExplicitLabels() {
        XCTAssertEqual(Theme.BarStyle.allCases, [.automatic, .oled, .light])
        XCTAssertEqual(Theme.BarStyle.allCases.map(\.title), ["Follow macOS", "OLED", "Light"])
    }

    func testLegacyAndAliasInputsPreserveOtherFields() throws {
        var expected = Theme.default
        expected.accent = .custom(hex: 0x123456)
        expected.cellSize = .large
        expected.showsLabels = true
        expected.cardText = .large
        let data = try JSONEncoder().encode(expected)
        for (input, finish) in [("black", Theme.BarStyle.oled), ("graphite", .oled), ("oled", .oled),
                                 ("material", .automatic), ("liquidGlass", .automatic), ("adaptive", .automatic)] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            object["bar"] = input
            expected.bar = finish
            let decoded = try JSONDecoder().decode(Theme.self, from: JSONSerialization.data(withJSONObject: object))
            XCTAssertEqual(decoded, expected)
            XCTAssertEqual(Theme(demoString: "accent=0x123456,bar=\(input),cell=large,labels=1,card=large"), expected)
        }
    }

    func testEncodingRemainsReadableByOldFinishDecoder() throws {
        enum OldFinish: String, Decodable { case black, graphite, material }
        struct OldTheme: Decodable { let bar: OldFinish }
        for (finish, old) in [(Theme.BarStyle.oled, OldFinish.black)] {
            var theme = Theme.default
            theme.bar = finish
            let data = try JSONEncoder().encode(theme)
            XCTAssertEqual(try JSONDecoder().decode(OldTheme.self, from: data).bar, old)
            XCTAssertTrue(theme.demoString.contains("bar=\(old.rawValue)"))
        }
    }
}
