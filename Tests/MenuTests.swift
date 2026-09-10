import AppKit
import XCTest
@testable import Drawer

/// The bar's own items never touch AppKit geometry, so these build the
/// controller bare, without `show()`, and read `contextMenu(atLocal:)`
/// straight off it, the same way the cell menu's tests need a local point to
/// land on a real cell.
@MainActor
final class MenuTests: XCTestCase {
    private func localPoint(_ controller: NotchWindowController, index: Int) -> CGPoint {
        let place = controller.model.placement
        let along = controller.model.slack + controller.model.ringCenter(visible: index)
        return place.point(along: along, across: controller.model.notchDepth / 2)
    }

    func testTheBarMenuHasItsFourTitlesInOrderWithASeparatorBeforeQuit() {
        let controller = NotchWindowController()
        let menu = controller.contextMenu(atLocal: nil)

        XCTAssertEqual(menu.items.map(\.title), ["Keep open", "Show drawer", "Settings…", "", "Quit Drawer"])
        XCTAssertTrue(menu.items[3].isSeparatorItem, "no separator ahead of Quit")
    }

    func testShowDrawerCarriesEachPresetsChordInTurn() {
        let controller = NotchWindowController()
        for preset in HotKeyPreset.allCases {
            let chord = preset.chord
            controller.hotKeyChord = chord
            let showDrawer = controller.contextMenu(atLocal: nil).item(withTitle: "Show drawer")
            XCTAssertEqual(showDrawer?.keyEquivalent, chord.menuKeyEquivalent.key)
            XCTAssertEqual(showDrawer?.keyEquivalentModifierMask, chord.menuKeyEquivalent.modifiers)
        }
    }

    func testACellHitPrependsRemoveAndASeparator() {
        let controller = NotchWindowController()
        controller.model.cells = Fixtures.cells(3)
        controller.model.isExpanded = true

        let menu = controller.contextMenu(atLocal: localPoint(controller, index: 0))

        XCTAssertEqual(menu.items.first?.title, "Remove wifi")
        XCTAssertTrue(menu.items[1].isSeparatorItem)
        XCTAssertEqual(menu.items[2].title, "Keep open")
    }

    func testTheAddCellGetsNoRemove() {
        let controller = NotchWindowController()
        controller.model.cells = [DrawerCell.add]
        controller.model.isExpanded = true

        let menu = controller.contextMenu(atLocal: localPoint(controller, index: 0))

        XCTAssertEqual(menu.items.first?.title, "Keep open", "the add tile should not offer Remove")
    }

    func testChoosingRemoveCallsOnRemoveWithTheCellID() {
        let controller = NotchWindowController()
        controller.model.cells = Fixtures.cells(1)
        controller.model.isExpanded = true
        var removed: String?
        controller.onRemove = { removed = $0 }

        let menu = controller.contextMenu(atLocal: localPoint(controller, index: 0))
        let removeItem = menu.items[0]
        (removeItem.target as? MenuActions)?.removeCell(removeItem)

        XCTAssertEqual(removed, "fixture-0")
    }
}
