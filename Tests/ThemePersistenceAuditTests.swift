import Combine
import Foundation
import XCTest
@testable import Drawer

@MainActor
final class ThemePersistenceAuditTests: XCTestCase {
    private let items: [DrawerItem] = [
        .shortcut(name: "Review 'draft' & archive"),
        .app(bundleID: "com.example.unavailable-app"),
        .action("future-action"),
        .action("brightness"),
    ]

    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let name = "ThemePersistenceAuditTests.\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        store.removePersistentDomain(forName: name)
        defer { store.removePersistentDomain(forName: name) }
        store.set(true, forKey: "hasLaunchedBefore")
        store.set(DrawerItem.encodeList(items), forKey: "items")
        try body(store)
    }

    func testInvalidPreferenceEnumsFallBackWithoutResettingOtherChoices() throws {
        for key in ["notchEdge", "notchVisibility", "appPresence", "hotKeyChord"] {
            for invalid in ["", "future-unsupported-value"] {
                try withDefaults { store in
                    let saved = Preferences(defaults: store)
                    saved.notchEdge = .left
                    saved.notchVisibility = .alwaysShow
                    saved.appPresence = .menuBar
                    saved.hotKey = HotKeyPreset.optionBacktick.chord
                    var theme = Theme.default
                    theme.bar = .light
                    theme.accent = .custom(hex: 0x345678)
                    saved.theme = theme
                    let itemData = try XCTUnwrap(store.data(forKey: "items"))
                    let themeData = try XCTUnwrap(store.data(forKey: "theme"))
                    store.set(invalid, forKey: key)

                    let restored = Preferences(defaults: store)

                    XCTAssertEqual(restored.notchEdge, key == "notchEdge" ? .right : .left, key)
                    XCTAssertEqual(restored.notchVisibility, key == "notchVisibility" ? .onHover : .alwaysShow, key)
                    XCTAssertEqual(restored.appPresence, key == "appPresence" ? .dock : .menuBar, key)
                    XCTAssertEqual(restored.hotKey, key == "hotKeyChord" ? .default : HotKeyPreset.optionBacktick.chord, key)
                    XCTAssertEqual(restored.theme, theme, key)
                    XCTAssertEqual(restored.items, items, key)
                    XCTAssertEqual(store.data(forKey: "items"), itemData, key)
                    XCTAssertEqual(store.data(forKey: "theme"), themeData, key)
                    XCTAssertEqual(store.string(forKey: key), invalid, "Loading must not rewrite an unsupported value")
                }
            }
        }
    }

    /// The top edge is gone, but a copy of the app that saved `"top"` before
    /// this build is still out there. That value now falls back to the
    /// default like any other unsupported one, and nothing else it saved moves.
    func testATopEdgeSavedBeforeItWasRemovedFallsBackToRight() throws {
        try withDefaults { store in
            let saved = Preferences(defaults: store)
            saved.notchVisibility = .alwaysShow
            saved.appPresence = .menuBar
            saved.hotKey = HotKeyPreset.optionBacktick.chord
            var theme = Theme.default
            theme.bar = .light
            theme.accent = .custom(hex: 0x345678)
            saved.theme = theme
            let itemData = try XCTUnwrap(store.data(forKey: "items"))
            let themeData = try XCTUnwrap(store.data(forKey: "theme"))
            store.set("top", forKey: "notchEdge")

            let restored = Preferences(defaults: store)

            XCTAssertEqual(restored.notchEdge, .right)
            XCTAssertEqual(restored.notchVisibility, .alwaysShow)
            XCTAssertEqual(restored.appPresence, .menuBar)
            XCTAssertEqual(restored.hotKey, HotKeyPreset.optionBacktick.chord)
            XCTAssertEqual(restored.theme, theme)
            XCTAssertEqual(restored.items, items)
            XCTAssertEqual(store.data(forKey: "items"), itemData)
            XCTAssertEqual(store.data(forKey: "theme"), themeData)
        }
    }

    func testCorruptThemeFallsBackWithoutOverwritingThemeOrItems() throws {
        for payload in [Data([0xFF, 0x00, 0x12]), Data("[1,2,3]".utf8), Data("{\"showsLabels\":\"yes\"}".utf8)] {
            try withDefaults { store in
                let saved = Preferences(defaults: store)
                saved.notchEdge = .left
                saved.appPresence = .hidden
                saved.hotKey = HotKeyPreset.controlOptionSpace.chord
                let itemData = try XCTUnwrap(store.data(forKey: "items"))
                store.set(payload, forKey: "theme")

                for _ in 0..<2 {
                    let restored = Preferences(defaults: store)
                    XCTAssertEqual(restored.theme, .default)
                    XCTAssertEqual(restored.items, items)
                    XCTAssertEqual(restored.notchEdge, .left)
                    XCTAssertEqual(restored.appPresence, .hidden)
                    XCTAssertEqual(restored.hotKey, HotKeyPreset.controlOptionSpace.chord)
                    XCTAssertEqual(store.data(forKey: "items"), itemData)
                    XCTAssertEqual(store.data(forKey: "theme"), payload)
                }
            }
        }
    }

    func testUnknownThemeEnumsFallBackWithoutChangingPinnedIdentities() throws {
        for key in ["bar", "cellSize", "cardText"] {
            try withDefaults { store in
                let encoded = try JSONEncoder().encode(Theme.default)
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
                object[key] = "future-unsupported-value"
                let payload = try JSONSerialization.data(withJSONObject: object)
                let itemData = try XCTUnwrap(store.data(forKey: "items"))
                store.set(payload, forKey: "theme")

                let restored = Preferences(defaults: store)

                XCTAssertEqual(restored.theme, .default, key)
                XCTAssertEqual(restored.items.map(\.id), items.map(\.id), key)
                XCTAssertEqual(store.data(forKey: "items"), itemData, key)
                XCTAssertEqual(store.data(forKey: "theme"), payload, key)
            }
        }
    }

    func testAppearanceAndNavigationPreserveItemsAndUnrelatedPreferences() throws {
        try withDefaults { store in
            let preferences = Preferences(defaults: store)
            preferences.notchEdge = .left
            preferences.notchVisibility = .hidden
            preferences.appPresence = .menuBar
            preferences.hotKey = HotKeyPreset.controlOptionSpace.chord
            let itemData = try XCTUnwrap(store.data(forKey: "items"))
            let session = SettingsSession()
            let editor = DrawerEditor()
            editor.selection = items[1].id
            var itemPublications = 0
            let subscription = preferences.$items.dropFirst().sink { _ in itemPublications += 1 }
            defer { subscription.cancel() }

            for finish in Theme.BarStyle.allCases {
                var theme = preferences.theme
                theme.bar = finish
                theme.accent = .custom(hex: 0x3478AB)
                theme.cellSize = .large
                theme.showsLabels = true
                theme.cardText = .large
                preferences.theme = theme
                for page in SettingsPage.allCases { session.select(page, editor: editor) }

                let restored = Preferences(defaults: store)
                XCTAssertEqual(restored.theme, theme)
                XCTAssertEqual(restored.items, items)
                XCTAssertEqual(restored.notchEdge, .left)
                XCTAssertEqual(restored.notchVisibility, .hidden)
                XCTAssertEqual(restored.appPresence, .menuBar)
                XCTAssertEqual(restored.hotKey, HotKeyPreset.controlOptionSpace.chord)
                XCTAssertEqual(store.data(forKey: "items"), itemData)
                XCTAssertEqual(editor.selection, items[1].id)
            }
            XCTAssertEqual(preferences.items, items)
            XCTAssertEqual(itemPublications, 0, "Appearance and navigation must not republish pinned items")
        }
    }
}
