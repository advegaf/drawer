import AppKit
import SwiftUI
import XCTest
@testable import Drawer

@MainActor
final class SettingsTests: XCTestCase {
    private func freshPreferences() -> Preferences {
        let name = "SettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return Preferences(defaults: defaults)
    }

    // MARK: - AppCatalog enumeration

    /// A minimal fake `.app`: enough of a bundle structure for `Bundle(url:)`
    /// to read `CFBundleIdentifier` and a name back out, no real binary.
    private func makeFakeApp(at url: URL, bundleID: String, name: String) throws {
        let contents = url.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleName": name,
            "CFBundlePackageType": "APPL",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
    }

    func testEntriesDedupeByBundleIDAndSortByName() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let dirA = root.appendingPathComponent("A")
        let dirB = root.appendingPathComponent("B")
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // The same bundle id in both directories: the first directory
        // passed to `entries(in:)`, dirA, should be the one that wins.
        try makeFakeApp(at: dirA.appendingPathComponent("Shared.app"), bundleID: "com.example.shared", name: "Shared App")
        try makeFakeApp(at: dirB.appendingPathComponent("SharedAgain.app"), bundleID: "com.example.shared", name: "Shared App Duplicate")
        try makeFakeApp(at: dirA.appendingPathComponent("Zeta.app"), bundleID: "com.example.zeta", name: "Zeta")

        let entries = AppCatalog.entries(in: [dirA, dirB])

        XCTAssertEqual(entries.count, 2, "the duplicate bundle id should have collapsed to one entry")
        XCTAssertEqual(entries.map(\.name), ["Shared App", "Zeta"], "results should sort by name")
        XCTAssertEqual(entries.first?.bundleID, "com.example.shared")
        XCTAssertEqual(entries.first?.name, "Shared App", "the first directory's copy should win")
    }

    /// S208: neither `CFBundleDisplayName` nor `CFBundleName` in the
    /// Info.plist, unlike `testEntriesDedupeByBundleIDAndSortByName`'s
    /// fixtures, which always set `CFBundleName`, so nothing else in this
    /// suite reaches `entries(in:)`'s third fallback.
    func testAnAppWithNoDisplayNameFallsBackToItsFilename() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = root.appendingPathComponent("Mystery App.app/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "com.example.mystery", "CFBundlePackageType": "APPL"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))

        let entries = AppCatalog.entries(in: [root])

        XCTAssertEqual(entries.first?.name, "Mystery App",
                       "with neither CFBundleDisplayName nor CFBundleName, the filename should be used")
    }

    // MARK: - Filtering

    func testFilteredIsCaseInsensitiveAndMatchesSubstrings() {
        let catalog = AppCatalog()
        catalog.apps = [
            AppEntry(bundleID: "com.a", name: "Notes", url: URL(fileURLWithPath: "/tmp/Notes.app")),
            AppEntry(bundleID: "com.b", name: "Terminal", url: URL(fileURLWithPath: "/tmp/Terminal.app")),
        ]

        XCTAssertEqual(catalog.filtered("not").map(\.name), ["Notes"])
        XCTAssertEqual(catalog.filtered("TERM").map(\.name), ["Terminal"])
        XCTAssertEqual(catalog.filtered("").count, 2, "an empty query should not filter anything out")
        XCTAssertEqual(catalog.filtered("zzz").count, 0)
    }

    func testEditorRejectsPayloadWithoutCurrentLocalSession() {
        let editor = DrawerEditor()
        let payload = DrawerDrag(id: "library|shortcut:Example", itemID: "shortcut:Example", source: .library, token: UUID())
        XCTAssertFalse(editor.prepare(.local(payload), items: [], library: [EditorEntry.shortcut("Example")]))
    }

    func testCanceledTransferCannotCommitLater() throws {
        let preferences = freshPreferences()
        preferences.items = []
        let editor = DrawerEditor()
        let entry = EditorEntry.shortcut("Example")
        let drag = try XCTUnwrap(editor.beginNative(entry, source: .library, items: []))
        editor.cancel()
        XCTAssertFalse(editor.commitNative(.local(drag.payload), preferences: preferences, library: [entry], undoManager: nil))
        XCTAssertTrue(preferences.items.isEmpty)
    }

    func testEditorDropRevalidatesNeighbor() throws {
        let preferences = freshPreferences()
        preferences.items = [.shortcut(name: "First")]
        let editor = DrawerEditor()
        let entry = EditorEntry.shortcut("Example")
        let drag = try XCTUnwrap(editor.beginNative(entry, source: .library, items: preferences.items))
        XCTAssertTrue(editor.session!.propose(.before("shortcut:First"), current: preferences.items))
        preferences.items = []
        XCTAssertFalse(editor.commitNative(.local(drag.payload), preferences: preferences, library: [entry], undoManager: nil))
        XCTAssertTrue(preferences.items.isEmpty)
    }

    func testEditorDropCommitsAndSelectsStableItem() throws {
        let preferences = freshPreferences()
        preferences.items = []
        let editor = DrawerEditor()
        let entry = EditorEntry.shortcut("Example")
        let drag = try XCTUnwrap(editor.beginNative(entry, source: .library, items: []))
        XCTAssertTrue(editor.session!.propose(.end, current: []))
        XCTAssertTrue(editor.commitNative(.local(drag.payload), preferences: preferences, library: [entry], undoManager: nil))
        XCTAssertEqual(preferences.items, [entry.item])
        XCTAssertEqual(editor.selection, entry.id)
        XCTAssertNil(editor.drag)
    }

    func testRemovalSelectionUsesNextThenPreviousThenEmpty() {
        let items: [DrawerItem] = [.shortcut(name: "A"), .shortcut(name: "B")]
        XCTAssertEqual(DrawerEditor.nextSelection(afterRemoving: items[0].id, from: items), items[1].id)
        XCTAssertEqual(DrawerEditor.nextSelection(afterRemoving: items[1].id, from: items), items[0].id)
        XCTAssertNil(DrawerEditor.nextSelection(afterRemoving: items[0].id, from: [items[0]]))
    }

    func testPreviewInsertionAcrossEveryEdge() {
        let entries = [EditorEntry.shortcut("A"), EditorEntry.shortcut("B")]
        for edge in NotchEdge.allCases {
            let layout = EditorPreviewLayout(edge: edge, metrics: .default, count: entries.count)
            let start = layout.placement.point(along: 0, across: 20)
            let end = layout.placement.point(along: layout.length, across: 20)
            XCTAssertEqual(layout.insertion(at: start, entries: entries, excluding: nil), entries[0].id)
            XCTAssertNil(layout.insertion(at: end, entries: entries, excluding: nil))
            XCTAssertEqual(layout.insertion(at: start, entries: entries, excluding: entries[0].id), entries[1].id)
        }
    }

    func testMissingPreviewEntryRetainsIdentityAndCannotRun() {
        let item = DrawerItem.app(bundleID: "com.example.removed")
        let entry = EditorEntry.missing(item)
        XCTAssertEqual(entry.item, item)
        XCTAssertEqual(entry.cell.id, item.id)
        XCTAssertEqual(entry.cell.state, .notInstalled)
        XCTAssertFalse(entry.available)
    }

    // MARK: - Action registry

    func testOrderedCoversEveryActionInRegistryRowOrder() {
        XCTAssertEqual(ActionRegistry.ordered.count, ActionID.allCases.count)
        for id in ActionID.allCases {
            XCTAssertTrue(ActionRegistry.ordered.contains(id), "\(id) is missing from ordered")
        }
    }

    func testEverySpecHasANonEmptyDetail() {
        for id in ActionID.allCases {
            XCTAssertFalse(ActionRegistry.spec(for: id).detail.isEmpty, "\(id) has no detail")
        }
    }

    // MARK: - Pages

    func testSettingsPageHasThreeCases() {
        XCTAssertEqual(SettingsPage.allCases.count, 3)
    }
}

/// The layout maths can be right and still put nothing on screen; these
/// render the real page views and count what actually painted, the same
/// idiom `NotchRenderTests` uses for the notch itself.
@MainActor
final class SettingsRenderTests: XCTestCase {
    private func freshPreferences() -> Preferences {
        let name = "SettingsRenderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return Preferences(defaults: defaults)
    }

    private func seededApps() -> AppCatalog {
        let catalog = AppCatalog()
        catalog.apps = [
            AppEntry(bundleID: "com.a", name: "Notes", url: URL(fileURLWithPath: "/tmp/Notes.app")),
            AppEntry(bundleID: "com.b", name: "Terminal", url: URL(fileURLWithPath: "/tmp/Terminal.app")),
        ]
        return catalog
    }

    private func seededShortcuts() -> ShortcutsCatalog {
        ShortcutsCatalog(loader: { ShellResult(status: 0, stdout: "A", stderr: "") })
    }

    /// Fraction of sampled pixels that are painted at all.
    private func inkedFraction(_ rep: NSBitmapImageRep) -> Double {
        var inked = 0, total = 0
        for x in stride(from: 0, to: rep.pixelsWide, by: 5) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 5) {
                total += 1
                if let colour = rep.colorAt(x: x, y: y), colour.alphaComponent > 0.5 { inked += 1 }
            }
        }
        return total == 0 ? 0 : Double(inked) / Double(total)
    }

    /// `ImageRenderer` skips AppKit-backed controls (`List`, `Form`,
    /// `TextField`, a switch `Toggle`, a segmented `Picker`), which is most
    /// of a Settings page, so it renders these pages as an off-screen
    /// `NSHostingView` and asks AppKit to composite it instead, the same
    /// path a real window uses.
    private func render<V: View>(_ view: V, width: CGFloat = 1000, height: CGFloat = 680) -> NSBitmapImageRep? {
        let hostingView = NSHostingView(rootView: view.frame(width: width, height: height))
        hostingView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        guard let rep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else { return nil }
        hostingView.cacheDisplay(in: hostingView.bounds, to: rep)
        return rep
    }

    /// `render(_:)`'s offscreen `cacheDisplay` never actually lays out a
    /// `List`'s row content (confirmed by hand: two renders with different
    /// `preferences.items` came back byte-identical), so this puts the
    /// hosting view in a real on-screen window instead, the one thing that
    /// reliably drives AppKit's table view layout. AppKit also never builds
    /// an accessibility tree for a `List` in the offscreen host (tried
    /// walking `accessibilityChildren()`; it came back empty even for a page
    /// known to have text on it), which is why the test below reads the
    /// pixels rather than an accessibility label.
    private func renderOnScreen<V: View>(_ view: V, width: CGFloat = 1000, height: CGFloat = 680) -> NSBitmapImageRep? {
        let hostingView = NSHostingView(rootView: view.frame(width: width, height: height))
        hostingView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = hostingView
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        guard let rep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else { return nil }
        hostingView.cacheDisplay(in: hostingView.bounds, to: rep)
        return rep
    }

    /// `ItemsPage.pinnedSection` swaps a whole `Text` row for the `ForEach`
    /// of pinned rows depending on `preferences.items.isEmpty`; nothing else
    /// about the page differs between the two renders below (same seeded
    /// apps and shortcuts, same `isFirstLaunch` caption). An empty list must
    /// still paint something where the row is, and that something must not
    /// be pixel-identical to a real pinned row's icon-plus-title, the only
    /// other thing the branch can draw there. That confirms the placeholder
    /// row renders; it does not pin the exact wording of it.
    func testItemsPageShowsAPlaceholderRowWhenNothingIsPinned() {
        let empty = freshPreferences()
        empty.items = []
        guard let emptyRep = renderOnScreen(ItemsPage(preferences: empty, shortcuts: seededShortcuts(), apps: seededApps()))
        else { return XCTFail("Items page produced no image") }
        XCTAssertGreaterThan(inkedFraction(emptyRep), 0, "an empty Pinned section should still paint a placeholder row, not a blank hole")

        let pinned = freshPreferences()
        pinned.items = [.action("bluetooth")]
        guard let pinnedRep = renderOnScreen(ItemsPage(preferences: pinned, shortcuts: seededShortcuts(), apps: seededApps()))
        else { return XCTFail("Items page produced no image") }

        var differing = 0
        for x in stride(from: 0, to: emptyRep.pixelsWide, by: 3) {
            for y in stride(from: 0, to: emptyRep.pixelsHigh, by: 3) {
                if emptyRep.colorAt(x: x, y: y) != pinnedRep.colorAt(x: x, y: y) { differing += 1 }
            }
        }
        XCTAssertGreaterThan(differing, 50, "the empty-list placeholder row should look different from a populated Pinned row")
    }

    func testItemsPagePaints() {
        let preferences = freshPreferences()
        guard let rep = render(ItemsPage(preferences: preferences, shortcuts: seededShortcuts(), apps: seededApps()))
        else { return XCTFail("Items page produced no image") }
        XCTAssertGreaterThan(inkedFraction(rep), 0, "Items page painted nothing")
    }

    func testAppearancePagePaints() {
        guard let rep = render(AppearancePage(preferences: freshPreferences()))
        else { return XCTFail("Appearance page produced no image") }
        XCTAssertGreaterThan(inkedFraction(rep), 0, "Appearance page painted nothing")
    }

    func testGeneralPagePaints() {
        guard let rep = render(GeneralPage(preferences: freshPreferences()))
        else { return XCTFail("General page produced no image") }
        XCTAssertGreaterThan(inkedFraction(rep), 0, "General page painted nothing")
    }

    /// The icon and the name that sit above the About card's rows.
    func testAboutHeaderPaints() {
        guard let rep = render(AboutHeader(), width: 280, height: 100)
        else { return XCTFail("About header produced no image") }
        XCTAssertGreaterThan(inkedFraction(rep), 0, "About header painted nothing")
    }

    /// `AboutView.versionLine` is what the About row actually calls with
    /// `Bundle.main.infoDictionary`; driving it here with a fake
    /// dictionary proves it reads `CFBundleShortVersionString` back out
    /// rather than showing a fixed string, which a render of the real
    /// bundle's own version could not tell apart from a hardcoded one.
    func testAboutViewVersionLineReadsTheBundleDictionaryNotAHardcodedString() {
        XCTAssertEqual(AboutView.versionLine(["CFBundleShortVersionString": "9.9.9"]), "Version 9.9.9")
        XCTAssertEqual(AboutView.versionLine([:]), "Version ?")
    }

    // MARK: - Sidebar

    /// The sidebar is rendered on its own here rather than inside
    /// `SettingsView`, and that is not a shortcut. Its column in a
    /// `NavigationSplitView` does not come through `cacheDisplay` at all:
    /// every pixel of it reads back white while the detail beside it
    /// reads back correctly. The column's contents are this view and
    /// nothing else, so rendering it directly tests the same thing and
    /// tests it honestly.
    private func renderSidebar(page: SettingsPage) -> NSBitmapImageRep? {
        renderOnScreen(SettingsSidebar(session: SettingsSession(page: page), editor: DrawerEditor()),
                       width: SettingsStyle.sidebarWidth, height: 680)
    }

    /// The wordmark and the icon have to land on the sidebar's own fill
    /// rather than on the page's, or the two surfaces meet with nothing
    /// between them and stop telling each other apart, which is the exact
    /// bug the header this replaced once had.
    func testTheSidebarPaintsOnEachOfTheThreePages() {
        for page in SettingsPage.allCases {
            guard let rep = renderSidebar(page: page) else {
                XCTFail("\(page.title) produced no image"); continue
            }
            let scale = CGFloat(rep.pixelsWide) / SettingsStyle.sidebarWidth
            // The icon is inset 16pt across and 8pt down, so (24, 20) is
            // inside it at any brand icon size this uses. 180pt is past the
            // wordmark but still inside the 220pt column.
            let onIcon = rep.colorAt(x: Int(24 * scale), y: Int(20 * scale))
            let pastText = rep.colorAt(x: Int(180 * scale), y: Int(20 * scale))
            XCTAssertNotEqual(onIcon, pastText, "\(page.title) sidebar is not where it should be")
        }
    }

    /// The selected page's row is tinted and the other two are not, which
    /// is the only thing in the window that says where you are now that
    /// the titlebar carries nothing but the collapse button.
    func testTheSidebarMarksTheSelectedPage() {
        var seen: [SettingsPage: NSColor] = [:]
        for page in SettingsPage.allCases {
            guard let rep = renderSidebar(page: page) else {
                XCTFail("\(page.title) produced no image"); continue
            }
            let scale = CGFloat(rep.pixelsWide) / SettingsStyle.sidebarWidth
            // Inside the first row's pill. Derived rather than a fixed
            // number, because the header's height is the brand icon plus its
            // padding and this moved down when the icon grew: the row starts
            // under the header, and the rows are 8pt in from the column's
            // edge.
            let headerHeight = SettingsStyle.s8 + SettingsStyle.brandIcon + SettingsStyle.s12
            guard let fill = rep.colorAt(x: Int(150 * scale), y: Int((headerHeight + 4) * scale)) else {
                XCTFail("\(page.title) had no pixel where the first row should be"); continue
            }
            seen[page] = fill
        }
        // Items is the first row, so its own page tints that pixel and the
        // other two leave it as plain sidebar fill.
        XCTAssertNotEqual(seen[.items], seen[.appearance], "the first row looks the same selected and not")
        XCTAssertEqual(seen[.appearance], seen[.general], "an unselected row is tinted")
    }

    // MARK: - Preview canvas size

    /// Recursively finds the on-screen preview canvas: the one
    /// `NativeEditorDragView` under `view` that accepts drops. Library
    /// rows install their own `NativeEditorDragView` too, with drops
    /// turned off (`ItemsPage.libraryRow`), which is what tells the
    /// canvas apart from them.
    private func findPreviewCanvas(in view: NSView) -> NativeEditorDragView? {
        if let dragView = view as? NativeEditorDragView, dragView.receivesDrops { return dragView }
        for subview in view.subviews {
            if let found = findPreviewCanvas(in: subview) { return found }
        }
        return nil
    }

    /// The preview canvas's on-screen frame, in window coordinates, for a
    /// given page and selection state. Goes through a real on-screen
    /// window for the same reason `renderOnScreen` does: AppKit only lays
    /// out its own views, `NativeEditorDragView` included, once the
    /// hosting view actually sits in a window.
    private func previewCanvasFrame(page: SettingsPage, selected: Bool) -> CGRect? {
        let preferences = freshPreferences()
        let editor = DrawerEditor()
        if selected {
            preferences.items = [.action("bluetooth")]
            editor.selection = preferences.items[0].id
        }
        let session = SettingsSession(page: page)
        let hostingView = NSHostingView(rootView: ItemsPage(
            preferences: preferences, shortcuts: seededShortcuts(), apps: seededApps(), editor: editor, session: session
        ).frame(width: 1000, height: 1000))
        hostingView.frame = NSRect(x: 0, y: 0, width: 1000, height: 1000)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 1000), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hostingView
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        hostingView.layoutSubtreeIfNeeded()
        // `layoutSubtreeIfNeeded` alone left this unreliable in practice:
        // an actual display pass is what settles a `GeometryReader`
        // descendant's frame, same reason `renderOnScreen` above does
        // this before reading anything back.
        if let rep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) {
            hostingView.cacheDisplay(in: hostingView.bounds, to: rep)
        }
        guard let canvas = findPreviewCanvas(in: hostingView) else { return nil }
        return canvas.convert(canvas.bounds, to: nil)
    }

    /// Exactly one surface in the window accepts a drop. Library rows
    /// install a `NativeEditorDragView` of their own so they can start a
    /// drag, but with drops turned off. If a second one ever started
    /// accepting them, `findPreviewCanvas` would return whichever the
    /// view walk reached first and every drag test in this file would be
    /// asserting against the wrong view rather than failing outright.
    func testThePreviewIsTheOnlySurfaceThatAcceptsADrop() throws {
        let hostingView = NSHostingView(rootView: SettingsView(
            preferences: freshPreferences(), shortcuts: seededShortcuts(),
            apps: seededApps(), initialPage: .items
        ).frame(width: 1000, height: 760))
        hostingView.frame = NSRect(x: 0, y: 0, width: 1000, height: 760)
        let window = NSWindow(contentRect: hostingView.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = hostingView
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        hostingView.layoutSubtreeIfNeeded()
        if let rep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) {
            hostingView.cacheDisplay(in: hostingView.bounds, to: rep)
        }

        var receiving = 0
        var total = 0
        func walk(_ view: NSView) {
            if let dragView = view as? NativeEditorDragView {
                total += 1
                if dragView.receivesDrops { receiving += 1 }
            }
            view.subviews.forEach(walk)
        }
        walk(hostingView)

        // Only the count that accepts drops is asserted. How many library
        // rows have materialised depends on the lazy stack, which is not
        // what this is about.
        XCTAssertGreaterThanOrEqual(total, 1, "no drag surface at all")
        XCTAssertEqual(receiving, 1, "\(receiving) surfaces accept drops, not one")
    }

    /// The row below the canvas (selection detail, the Items-only
    /// move/remove row, the status line) used to change height with the
    /// page and the selection, and the canvas absorbed the difference.
    /// `ItemsPage.belowCanvas` now reserves one fixed height for that
    /// whole row, so the canvas above it must come out identical here in
    /// all four combinations.
    ///
    /// Rendered at 1000 by 1000, the height settings opens at rather than
    /// the file's usual 680. The canvas is a fraction of the page now, and
    /// a page too short to hold everything overflows: the size stays equal
    /// either way, but the two pages then centre their overflow
    /// differently and the origins stop matching, which is a fact about a
    /// window smaller than the app ever opens rather than about the
    /// canvas.
    func testPreviewCanvasIsTheSameSizeOnItemsAndAppearanceRegardlessOfSelection() throws {
        let itemsEmpty = try XCTUnwrap(previewCanvasFrame(page: .items, selected: false), "no canvas found for Items")
        let itemsSelected = try XCTUnwrap(previewCanvasFrame(page: .items, selected: true), "no canvas found for Items, selected")
        let appearanceEmpty = try XCTUnwrap(previewCanvasFrame(page: .appearance, selected: false), "no canvas found for Appearance")
        let appearanceSelected = try XCTUnwrap(previewCanvasFrame(page: .appearance, selected: true), "no canvas found for Appearance, selected")

        // A canvas that never actually laid out would report `.zero` on
        // all four calls and pass every equality check below for the
        // wrong reason, so pin down that it is a real, sized rectangle
        // first.
        XCTAssertGreaterThan(itemsEmpty.width, 200, "canvas width looks unlaid-out: \(itemsEmpty)")
        XCTAssertGreaterThan(itemsEmpty.height, 200, "canvas height looks unlaid-out: \(itemsEmpty)")

        XCTAssertEqual(itemsEmpty, itemsSelected, "selecting an item must not resize the canvas")
        XCTAssertEqual(itemsEmpty, appearanceEmpty, "the canvas must be the same size on Items and Appearance")
        XCTAssertEqual(itemsEmpty, appearanceSelected, "the canvas must be the same size on Items and Appearance, selected")

        // Printed for the phase report; grep the test log for these.
        print("PHASE30_CANVAS_ITEMS=\(itemsEmpty)")
        print("PHASE30_CANVAS_APPEARANCE=\(appearanceEmpty)")
    }

    // MARK: - Delete key removes the selected preview item (S098)

    /// `onDeleteCommand`'s closure only exists in the rendered tree once
    /// real SwiftUI focus has moved onto the preview canvas, so a
    /// hand-set `editor.selection` proves nothing: the bug this pins was
    /// exactly a Delete press never reaching a handler that was only ever
    /// gated on focus. Going through `NativeEditorSurface.select`, the
    /// same callback a real click uses, is what actually moves focus.
    /// `findPreviewCanvas` and the on-screen window are
    /// `previewCanvasFrame`'s above; the point math mirrors
    /// `DrawerEditorPreview.body`'s own `layout`/`transform` construction
    /// so the click lands on the same cell the view itself would compute.
    /// A `.borderless` window never becomes key here (confirmed by hand:
    /// `NSApp.isActive` stays false even after `activate(ignoringOtherApps:)`
    /// in an unattended `xcodebuild test` run), yet `select` still moves
    /// real focus (`window.firstResponder` becomes a real `SwiftUI.KeyViewProxy`)
    /// and `hostingView.tryToPerform(_:with:)` below still walks the real
    /// chain from it, key status or not.
    func testDeleteKeyRemovesTheSelectedPreviewItem() throws {
        let preferences = freshPreferences()
        let a = DrawerItem.action("bluetooth")
        let b = DrawerItem.action("wifi")
        preferences.items = [a, b]
        let editor = DrawerEditor()
        let session = SettingsSession(page: .items)
        let hostingView = NSHostingView(rootView: ItemsPage(
            preferences: preferences, shortcuts: seededShortcuts(), apps: seededApps(), editor: editor, session: session
        ).frame(width: 1000, height: 1000))
        hostingView.frame = NSRect(x: 0, y: 0, width: 1000, height: 1000)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 1000), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hostingView
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        hostingView.layoutSubtreeIfNeeded()
        if let rep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) {
            hostingView.cacheDisplay(in: hostingView.bounds, to: rep)
        }
        let canvas = try XCTUnwrap(findPreviewCanvas(in: hostingView), "no preview canvas to click")

        let theme = preferences.theme.resolved(system: session.background.colorScheme)
        let layout = EditorPreviewLayout(edge: preferences.notchEdge, metrics: theme.metrics, count: preferences.items.count)
        let screen = NotchGeometry.preferredScreen(from: NSScreen.screens)
        let aspect = screen.map { $0.frame.width / max(1, $0.frame.height) } ?? 1.6
        let transform = EditorPreviewTransform(layout: layout, viewport: canvas.bounds.size, screenAspect: aspect)
        canvas.select(transform.renderedPoint(layout.center(1)))   // the second pinned item, not whatever onAppear already selected
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(editor.selection, b.id, "setup: the click should have selected the second pinned item")

        // `NSApp.sendAction(_:to: nil, from:)` resolves its target through
        // `NSApp.keyWindow`, which an unattended `xcodebuild test` run never
        // grants (confirmed by hand: `NSApp.isActive` stays false even after
        // `activate(ignoringOtherApps:)`, so nothing is ever key here). A
        // non-nil target sent that way skips the chain instead of walking
        // it (confirmed too: it throws "unrecognized selector" straight at
        // that one object). `tryToPerform`, called on the hosting view
        // itself, is the real chain walk AppKit does for a key event,
        // independent of key-window status.
        // A return of true here only means something in the chain implements
        // `deleteBackward:` at all, not that it was `onDeleteCommand`
        // specifically (confirmed by hand: it still comes back true with
        // that modifier deleted, some other AppKit control upstream answers
        // too); the items assertion below is what actually pins the fix,
        // confirmed to fail without `onDeleteCommand` in place.
        XCTAssertTrue(hostingView.tryToPerform(#selector(NSResponder.deleteBackward(_:)), with: nil),
                      "Delete never reached any responder at all")
        // Half a second, not a tenth. This failed once in a full suite run
        // and passed twice on its own straight afterwards, which is what a
        // run loop wait too short for a loaded machine looks like. The
        // removal is synchronous once SwiftUI delivers the command, so a
        // longer wait costs nothing when it is not needed.
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))

        XCTAssertEqual(preferences.items, [a], "Delete should have removed the selected preview item and left the other one")
    }

    // MARK: - Finish thumbnails

    /// Each finish (Follow macOS, OLED, Light) paints a real drawer surface
    /// at thumbnail size, not a blank tile.
    func testEachFinishThumbnailPaints() {
        for style in Theme.BarStyle.allCases {
            guard let rep = render(FinishThumbnail(style: style),
                                   width: FinishThumbnail.size.width, height: FinishThumbnail.size.height)
            else { XCTFail("\(style.title) thumbnail produced no image"); continue }
            XCTAssertGreaterThan(inkedFraction(rep), 0, "\(style.title) thumbnail painted nothing")
        }
    }

    /// Follow macOS has no single surface: `FinishThumbnail` splits it
    /// diagonally into a frost half and a black half, `DiagonalHalf`
    /// running from the tile's top-right corner to its bottom-left, so the
    /// top-left corner sits in the light half and the bottom-right corner
    /// sits in the dark half. Reading brightness (rather than comparing
    /// `NSColor`s directly, which can disagree across colour spaces) and
    /// giving each threshold room for the ring drawn over it is what tells
    /// an actual split apart from one flat colour covering the tile.
    func testFollowMacOSThumbnailPaintsALightRegionAndADarkRegion() throws {
        guard let rep = render(FinishThumbnail(style: .automatic),
                               width: FinishThumbnail.size.width, height: FinishThumbnail.size.height)
        else { return XCTFail("Follow macOS thumbnail produced no image") }

        func brightness(_ x: CGFloat, _ y: CGFloat) throws -> CGFloat {
            let scale = CGFloat(rep.pixelsWide) / FinishThumbnail.size.width
            let colour = try XCTUnwrap(rep.colorAt(x: Int(x * scale), y: Int(y * scale)), "no colour sampled at (\(x), \(y))")
            XCTAssertGreaterThan(colour.alphaComponent, 0.5, "(\(x), \(y)) should be inside the rounded tile")
            return try XCTUnwrap(colour.usingColorSpace(.sRGB), "sampled colour has no sRGB conversion").brightnessComponent
        }

        let light = try brightness(6, 6)
        let dark = try brightness(FinishThumbnail.size.width - 6, FinishThumbnail.size.height - 6)
        XCTAssertGreaterThan(light, 0.7, "top-left corner should be the frost half")
        XCTAssertLessThan(dark, 0.25, "bottom-right corner should be the black half")
    }

    // The brief also asks for a render proving the selected thumbnail
    // carries the accessibility selected trait and the others do not.
    // Spiked first: neither `hostingView.accessibilityChildren()` (offscreen
    // or on an on-screen `NSWindow`, with and without a run loop pump after
    // `makeKeyAndOrderFront`) nor a recursive `subviews` walk exposes it.
    // The subview walk does show AppKit-bridged controls this page already
    // has (`Checkbox`, `SystemSegmentedControl`, `BridgedColorPicker`), but
    // none carries a propagated `accessibilityLabel`, and the plain
    // `Button`-wrapped tiles here produce no accessibility-bearing subview
    // at all: SwiftUI never materializes their accessibility elements in
    // this offscreen host, the same limit this file's own `renderOnScreen`
    // comment already documents for `List`. Not something a test in this
    // harness can check; verified instead by reading the two `phase31-*`
    // screenshots for a single accent ring around the selected tile.
}
