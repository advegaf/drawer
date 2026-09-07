import AppKit
import XCTest
@testable import Drawer

@MainActor
final class ResolverTests: XCTestCase {
    func testABogusBundleIdResolvesToNotInstalledWithoutThrowing() async {
        let resolver = ItemResolver()
        let cells = await resolver.resolve([.app(bundleID: "com.advegaf.definitely-not-a-real-app")])
        XCTAssertEqual(cells.count, 1)
        XCTAssertEqual(cells[0].state, .notInstalled)
    }

    func testFinderResolvesToALaunchCellWithAnImageIconAndATitle() async {
        let resolver = ItemResolver()
        let cells = await resolver.resolve([.app(bundleID: "com.apple.finder")])
        XCTAssertEqual(cells.count, 1)
        let cell = cells[0]
        XCTAssertEqual(cell.kind, .launch)
        XCTAssertFalse(cell.title.isEmpty)
        guard case .image = cell.icon else {
            XCTFail("expected an image icon for Finder")
            return
        }
    }

    func testAnUnknownActionRawResolvesToUnavailable() async {
        let resolver = ItemResolver()
        let cells = await resolver.resolve([.action("not-a-real-action")])
        XCTAssertEqual(cells[0].state, .unavailable)
    }

    func testAKnownActionWithAnUnavailableRowResolvesToUnavailableWithTheRegistryTitle() async {
        let resolver = ItemResolver(controlFor: { _ in .unavailable })
        let cells = await resolver.resolve([.action("bluetooth")])
        XCTAssertEqual(cells[0].state, .unavailable)
        XCTAssertEqual(cells[0].title, ActionRegistry.spec(for: .bluetooth).title)
    }

    func testAShortcutResolvesToShortcutAndReady() async {
        let resolver = ItemResolver()
        let cells = await resolver.resolve([.shortcut(name: "Focus Mode")])
        XCTAssertEqual(cells[0].kind, .shortcut)
        XCTAssertEqual(cells[0].state, .ready)
    }

    func testOrderIsPreserved() async {
        // Ordering does not depend on a real control, and .action("bluetooth")
        // would otherwise read the actual Bluetooth power state on whatever
        // Mac runs this suite.
        let resolver = ItemResolver(controlFor: { _ in .unavailable })
        let items: [DrawerItem] = [.action("wifi"), .action("bluetooth"), .action("volume"), .shortcut(name: "X")]
        let cells = await resolver.resolve(items)
        XCTAssertEqual(cells.map(\.id), items.map(\.id))
    }

    func testReplaceCellsPreservesHoveredIdentityAndClearsRemovedSource() {
        let model = NotchViewModel()
        model.cells = [
            DrawerCell(id: "a", title: "A", icon: .symbol("wifi"), kind: .toggle, state: .on),
            DrawerCell(id: "b", title: "B", icon: .symbol("wifi"), kind: .toggle, state: .on),
            DrawerCell(id: "c", title: "C", icon: .symbol("wifi"), kind: .toggle, state: .on),
        ]
        model.hoveredIndex = 1

        let reordered = [model.cells[2], model.cells[0], model.cells[1]]
        model.replaceCells(reordered)
        XCTAssertEqual(model.hoveredIndex, 2, "cell b moved to index 2, hover should follow it")

        let withoutB = [reordered[0], reordered[1]]
        model.replaceCells(withoutB)
        XCTAssertNil(model.hoveredIndex, "removing the source dismisses its card")
    }

    func testHundredItemsResolveUnder50msWarm() async {
        let resolver = ItemResolver()
        let items = (0..<100).map { _ in DrawerItem.app(bundleID: "com.apple.finder") }
        _ = await resolver.resolve(items)   // warms the icon cache

        let start = Date()
        _ = await resolver.resolve(items)
        let elapsedMs = Date().timeIntervalSince(start) * 1000

        XCTAssertLessThan(elapsedMs, 50, "warm resolve of 100 identical app items took \(elapsedMs)ms")
    }

    func testAReadThatNeverAnswersIsWrittenOffAsUnavailable() async {
        ItemResolver.wedged.removeAll()
        ItemResolver.readTimeout = .milliseconds(200)
        defer { ItemResolver.readTimeout = .seconds(2); ItemResolver.wedged.removeAll() }
        let hung: ActionSpec.Control = .toggle(
            read: { try? await Task.sleep(for: .seconds(30)); return true },
            write: { _ in }, observe: nil
        )
        let resolver = ItemResolver(controlFor: { _ in hung })

        let started = Date()
        let cells = await resolver.resolve([.action("wifi")])
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5, "the resolver must not wait on a hung read")
        XCTAssertEqual(cells.first?.state, .unavailable)
        XCTAssertTrue(ItemResolver.wedged.contains(.wifi))

        let again = Date()
        let second = await resolver.resolve([.action("wifi")])
        XCTAssertLessThan(Date().timeIntervalSince(again), 0.1, "a wedged action is not read again")
        XCTAssertEqual(second.first?.state, .unavailable)
    }
}
