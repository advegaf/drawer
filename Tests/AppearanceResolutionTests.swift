import SwiftUI
import XCTest
@testable import Drawer

final class AppearanceResolutionTests: XCTestCase {
    func testAutomaticUsesTheSystemAppearanceWithoutChangingSavedTheme() {
        let theme = Theme(bar: .automatic, cellSize: .large, showsLabels: true)
        XCTAssertEqual(theme.resolved(system: .light).bar, .light)
        XCTAssertEqual(theme.resolved(system: .dark).bar, .oled)
        XCTAssertEqual(theme.bar, .automatic)
        XCTAssertEqual(theme.resolved(system: .light).metrics, theme.metrics)
    }

    func testExplicitFinishesIgnoreSystemAppearance() {
        for finish in [Theme.BarStyle.oled, .light] {
            let theme = Theme(accent: .custom(hex: 0x123456), bar: finish,
                              cellSize: .compact, showsLabels: true, cardText: .large)
            for system in [ColorScheme.light, .dark] {
                XCTAssertEqual(theme.resolved(system: system), theme)
            }
        }
    }

    func testLegacyThemesWithoutNewFieldsPreserveEveryExistingChoice() throws {
        for (legacy, finish) in [("black", Theme.BarStyle.oled), ("material", .automatic)] {
            let expected = Theme(accent: .preset(.pink), bar: finish, cellSize: .large,
                                 showsLabels: true, cardText: .large)
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(expected)) as? [String: Any])
            object["bar"] = legacy
            let data = try JSONSerialization.data(withJSONObject: object)
            XCTAssertEqual(try JSONDecoder().decode(Theme.self, from: data), expected)
        }
    }

    func testEveryAppearanceChoiceRoundTripsThroughPersistenceAndDemoInput() throws {
        for finish in Theme.BarStyle.allCases {
            let theme = Theme(accent: .custom(hex: 0x789ABC), bar: finish,
                              cellSize: .compact, showsLabels: true, cardText: .large)
            XCTAssertEqual(try JSONDecoder().decode(Theme.self, from: JSONEncoder().encode(theme)), theme)
            XCTAssertEqual(Theme(demoString: theme.demoString), theme)
        }
    }
}
