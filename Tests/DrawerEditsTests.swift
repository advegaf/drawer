import Combine
import XCTest
@testable import Drawer

final class DrawerEditsTests: XCTestCase {
    private let a = DrawerItem.action("wifi")
    private let b = DrawerItem.app(bundleID: "missing.app")
    private let c = DrawerItem.shortcut(name: "Unavailable shortcut")

    func testEveryKindInsertsAtBeginningMiddleAndEnd() {
        for item in [a, b, c] {
            let existing = [a, b, c].filter { $0 != item }
            XCTAssertEqual(DrawerEdit.add(item, before: existing[0].id).applying(to: existing), [item] + existing)
            XCTAssertEqual(DrawerEdit.add(item, before: existing[1].id).applying(to: existing), [existing[0], item, existing[1]])
            XCTAssertEqual(DrawerEdit.add(item, before: nil).applying(to: existing), existing + [item])
        }
    }

    func testMovesUseNeighborAfterRemovingSource() {
        let items = [a, b, c]
        XCTAssertEqual(DrawerEdit.move(id: a.id, before: nil).applying(to: items), [b, c, a])
        XCTAssertEqual(DrawerEdit.move(id: c.id, before: a.id).applying(to: items), [c, a, b])
        XCTAssertEqual(DrawerEdit.move(id: a.id, before: c.id).applying(to: items), [b, a, c])
        XCTAssertEqual(DrawerEdit.move(id: c.id, before: b.id).applying(to: items), [a, c, b])
    }

    func testInvalidAndUnchangedEditsReturnNoList() {
        let items = [a, b, c]
        let edits: [DrawerEdit] = [
            .add(a, before: nil), .add(.action("new"), before: "gone"),
            .move(id: "gone", before: a.id), .move(id: a.id, before: "gone"),
            .move(id: a.id, before: a.id), .move(id: a.id, before: b.id),
            .move(id: c.id, before: nil), .remove(id: "gone")
        ]
        for edit in edits { XCTAssertNil(edit.applying(to: items), "\(edit)") }
    }

    func testRemovalAndEmptyList() {
        XCTAssertEqual(DrawerEdit.remove(id: b.id).applying(to: [a, b, c]), [a, c])
        XCTAssertEqual(DrawerEdit.remove(id: a.id).applying(to: [a]), [])
        XCTAssertEqual(DrawerEdit.add(a, before: nil).applying(to: []), [a])
        XCTAssertNil(DrawerEdit.move(id: a.id, before: nil).applying(to: []))
    }
}

@MainActor
final class DrawerEditPreferencesTests: XCTestCase {
    private func preferences() -> (Preferences, UserDefaults) {
        let name = "DrawerEditPreferencesTests.\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        store.removePersistentDomain(forName: name)
        return (Preferences(defaults: store), store)
    }

    func testEachCommittedEditUndoesAndRedoesWithPersistence() {
        let a = DrawerItem.action("wifi")
        let b = DrawerItem.shortcut(name: "Missing")
        let c = DrawerItem.app(bundleID: "missing.app")
        let edits: [DrawerEdit] = [.add(c, before: a.id), .move(id: a.id, before: nil), .remove(id: b.id)]
        for edit in edits {
            let (preferences, store) = preferences()
            preferences.items = [a, b]
            let undo = UndoManager()
            undo.groupsByEvent = false
            undo.beginUndoGrouping()
            XCTAssertTrue(preferences.commit(edit, undoManager: undo))
            undo.endUndoGrouping()
            let committed = preferences.items
            XCTAssertEqual(Preferences(defaults: store).items, committed)
            undo.undo()
            XCTAssertEqual(preferences.items, [a, b])
            XCTAssertEqual(Preferences(defaults: store).items, [a, b])
            XCTAssertFalse(undo.canUndo)
            undo.redo()
            XCTAssertEqual(preferences.items, committed)
            XCTAssertEqual(Preferences(defaults: store).items, committed)
        }
    }

    func testNoOpDoesNotPublishPersistOrRegisterUndo() {
        let (preferences, store) = preferences()
        let a = DrawerItem.action("wifi")
        preferences.items = [a]
        let saved = store.data(forKey: "items")
        var publications = 0
        let subscription = preferences.$items.dropFirst().sink { _ in publications += 1 }
        let undo = UndoManager()
        XCTAssertFalse(preferences.commit(.add(a, before: nil), undoManager: undo))
        XCTAssertFalse(preferences.commit(.move(id: a.id, before: nil), undoManager: undo))
        XCTAssertFalse(preferences.commit(.remove(id: "gone"), undoManager: undo))
        XCTAssertEqual(publications, 0)
        XCTAssertEqual(store.data(forKey: "items"), saved)
        XCTAssertFalse(undo.canUndo)
        withExtendedLifetime(subscription) {}
    }

    func testUndoRestoresUnavailableItemAndPreservesUnrelatedEdits() {
        let (preferences, _) = preferences()
        let a = DrawerItem.action("wifi")
        let missing = DrawerItem.app(bundleID: "no.longer.installed")
        let c = DrawerItem.shortcut(name: "Gone")
        let extra = DrawerItem.action("volume")
        preferences.items = [a, missing, c]
        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        preferences.commit(.remove(id: missing.id), undoManager: undo)
        undo.endUndoGrouping()
        preferences.commit(.add(extra, before: c.id))
        preferences.commit(.remove(id: a.id))
        undo.undo()
        XCTAssertEqual(preferences.items, [extra, missing, c])
        undo.redo()
        XCTAssertEqual(preferences.items, [extra, c])
    }

    func testUndoUsesPreviousNeighborWhenNextDisappears() {
        let (preferences, _) = preferences()
        let a = DrawerItem.action("wifi")
        let b = DrawerItem.action("volume")
        let c = DrawerItem.action("brightness")
        preferences.items = [a, b, c]
        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        preferences.commit(.remove(id: b.id), undoManager: undo)
        undo.endUndoGrouping()
        preferences.commit(.remove(id: c.id))
        undo.undo()
        XCTAssertEqual(preferences.items, [a, b])
    }
}
