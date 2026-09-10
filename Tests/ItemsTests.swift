import XCTest
@testable import Drawer

@MainActor
final class ItemsTests: XCTestCase {
    func testTheFirstLaunchIsAnnouncedExactlyOnce() {
        let name = "ItemsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)

        XCTAssertTrue(Preferences(defaults: defaults).isFirstLaunch)
        XCTAssertFalse(Preferences(defaults: defaults).isFirstLaunch,
                       "a returning user would be introduced to the app again")
    }

    func testChoicesSurviveARestart() {
        let name = "ItemsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)

        Preferences(defaults: defaults).notchEdge = .left
        XCTAssertEqual(Preferences(defaults: defaults).notchEdge, .left)
    }

    private func freshDefaults() -> UserDefaults {
        let name = "ItemsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testAllThreeItemKindsRoundTrip() {
        let items: [DrawerItem] = [
            .app(bundleID: "com.apple.finder"), .action("wifi"), .shortcut(name: "Focus"),
        ]
        XCTAssertEqual(DrawerItem.decodeList(DrawerItem.encodeList(items)), items)
    }

    func testAMalformedElementIsDroppedAndSurvivorsKept() {
        let json = """
        [
            {"kind": "action", "value": "wifi"},
            {"kind": "bogus", "value": "x"},
            {"kind": "action", "value": "bluetooth"}
        ]
        """
        XCTAssertEqual(
            DrawerItem.decodeList(Data(json.utf8)),
            [.action("wifi"), .action("bluetooth")]
        )
    }

    func testAnUnknownActionRawValueSurvivesDecoding() {
        let items: [DrawerItem] = [.action("some-future-action")]
        XCTAssertEqual(DrawerItem.decodeList(DrawerItem.encodeList(items)), items)
    }

    func testDuplicatesAreDroppedOnDecodeAndRefusedOnAdd() {
        let json = """
        [
            {"kind": "action", "value": "wifi"},
            {"kind": "action", "value": "wifi"}
        ]
        """
        XCTAssertEqual(DrawerItem.decodeList(Data(json.utf8)), [.action("wifi")])

        // A fresh suite seeds eight items on first launch, so pick an id
        // outside that seed to test a clean add-then-refuse.
        let prefs = Preferences(defaults: freshDefaults())
        XCTAssertTrue(prefs.add(.action("lockScreen")))
        let beforeRetry = prefs.items
        XCTAssertFalse(prefs.add(.action("lockScreen")), "adding the same id twice should be refused")
        XCTAssertEqual(prefs.items, beforeRetry, "a refused add should leave the list untouched")
    }

    func testRemoveByIdWorks() {
        let prefs = Preferences(defaults: freshDefaults())
        prefs.add(.action("lockScreen"))
        prefs.remove(id: DrawerItem.action("lockScreen").id)
        XCTAssertFalse(prefs.items.contains { $0.id == DrawerItem.action("lockScreen").id })
    }

    func testRemoveThenAddReAddsAtTheEnd() {
        let prefs = Preferences(defaults: freshDefaults())
        let item = DrawerItem.action("lockScreen")
        prefs.add(item)
        prefs.remove(id: item.id)
        XCTAssertTrue(prefs.add(item))
        XCTAssertEqual(prefs.items.last, item, "re-adding after a remove should land at the end")
    }

    /// `ItemsPage`'s `.onMove` does nothing but `items.move(fromOffsets:toOffset:)`
    /// on `preferences.items`; the drag gesture that calls it stays a hands-on
    /// check (S096/S137), but the reorder-then-persist path underneath it does
    /// not need the drag to prove itself.
    func testReorderedItemsKeepTheirNewOrderAcrossARelaunch() {
        let name = "ItemsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)

        let beforeQuit = Preferences(defaults: defaults)
        beforeQuit.items.move(fromOffsets: IndexSet(integer: beforeQuit.items.count - 1), toOffset: 0)
        let reordered = beforeQuit.items

        let afterRelaunch = Preferences(defaults: defaults)
        XCTAssertEqual(afterRelaunch.items, reordered, "the reordered list should read back in the same order")
    }

    func testSeedHappensWhenNothingWasEverPinned() {
        let defaults = freshDefaults()
        let expected: [DrawerItem] = [
            .action("wifi"), .action("bluetooth"), .action("darkMode"), .action("nightShift"),
            .action("volume"), .action("brightness"), .action("keepAwake"), .action("mute"),
        ]

        let first = Preferences(defaults: defaults)
        XCTAssertEqual(first.items, expected)

        let second = Preferences(defaults: defaults)
        XCTAssertFalse(second.isFirstLaunch)
        XCTAssertEqual(second.items, expected, "the seed should persist rather than reappear or vanish")
    }

    func testSeedAlsoHappensOnAnUpgradeThatPredatesItems() {
        let defaults = freshDefaults()
        defaults.set(true, forKey: "hasLaunchedBefore")

        let prefs = Preferences(defaults: defaults)
        XCTAssertFalse(prefs.isFirstLaunch)
        XCTAssertEqual(prefs.items.count, 8, "a copy that ran before items existed still gets the seed")
    }

    func testALaterEmptyListStaysEmpty() {
        let defaults = freshDefaults()
        let first = Preferences(defaults: defaults)
        for item in first.items { first.remove(id: item.id) }
        XCTAssertEqual(first.items, [])

        let second = Preferences(defaults: defaults)
        XCTAssertEqual(second.items, [])
    }

    func testAWholeBlobDecodeFailureDoesNotOverwriteStoredData() {
        let defaults = freshDefaults()
        let garbage = Data("not json".utf8)
        defaults.set(garbage, forKey: "items")

        let prefs = Preferences(defaults: defaults)
        XCTAssertEqual(prefs.items, [], "a blob that fails to decode should read as empty for this run")
        XCTAssertEqual(defaults.data(forKey: "items"), garbage, "the stored blob should be left untouched")
    }
}
