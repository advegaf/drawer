import AppKit
import SwiftUI
import XCTest
@testable import Drawer

@MainActor
final class SettingsRedesignTests: XCTestCase {
    func testNavigationPreservesEditingContextAndCancelsDrag() {
        let session = SettingsSession()
        let editor = DrawerEditor()
        let item = EditorEntry.shortcut("Sample")
        session.query = "Sam"
        session.category = .shortcuts
        session.background = .dark
        editor.selection = item.id
        editor.ownsUndoFocus = true
        XCTAssertNotNil(editor.beginNative(item, source: .library, items: []))
        session.select(.appearance, editor: editor)
        XCTAssertNil(editor.drag)
        XCTAssertNil(editor.session)
        XCTAssertFalse(editor.ownsUndoFocus)
        session.select(.general, editor: editor)
        session.select(.items, editor: editor)
        XCTAssertEqual(session.query, "Sam")
        XCTAssertEqual(session.category, .shortcuts)
        XCTAssertEqual(session.background, .dark)
        XCTAssertEqual(editor.selection, item.id)
    }

    func testWindowFrameFitsSmallOffsetDisplay() {
        let visible = CGRect(x: -800, y: 35, width: 800, height: 550)
        let frame = CGRect(x: -50, y: -70, width: 960, height: 700)
        XCTAssertEqual(SettingsWindowController.clampedFrame(frame, to: visible), visible)
        let smaller = CGRect(x: -900, y: 600, width: 500, height: 400)
        XCTAssertEqual(SettingsWindowController.clampedFrame(smaller, to: visible),
                       CGRect(x: -800, y: 185, width: 500, height: 400))
    }

    func testUndoAndRedoReplaceStaleEditorFeedback() {
        let editor = DrawerEditor()
        let item = EditorEntry.shortcut("Sample")
        editor.announce("Added Sample.")
        XCTAssertNotNil(editor.beginNative(item, source: .library, items: []))
        editor.historyDidChange(redo: false)
        XCTAssertNil(editor.drag)
        XCTAssertNil(editor.session)
        XCTAssertEqual(editor.status, "Change undone.")
        editor.historyDidChange(redo: true)
        XCTAssertEqual(editor.status, "Change redone.")
    }

    func testLibraryProbeHidesLegacyScrollbarsWithoutDisablingScrolling() {
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        scroll.scrollerStyle = .legacy
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        let document = NSView(frame: CGRect(x: 0, y: 0, width: 300, height: 2000))
        scroll.documentView = document
        let probe = ScrollIndicatorProbe(frame: document.bounds)
        document.addSubview(probe)
        XCTAssertFalse(scroll.hasVerticalScroller)
        XCTAssertFalse(scroll.hasHorizontalScroller)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 100))
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 100)
        scroll.hasVerticalScroller = true
        probe.layout()
        XCTAssertFalse(scroll.hasVerticalScroller)
        XCTAssertNil(probe.hitTest(.zero))
    }

    func testMockBackgroundPreviewsFollowMacOSInBothDirections() {
        var theme = Theme()
        theme.bar = .automatic
        XCTAssertEqual(theme.resolved(system: PreviewBackground.light.colorScheme).bar, .light)
        XCTAssertEqual(theme.resolved(system: PreviewBackground.dark.colorScheme).bar, .oled)
        XCTAssertEqual(theme.bar, .automatic)
    }

    func testWiderPreviewKeepsScreenAnchorForEveryEdge() {
        for edge in NotchEdge.allCases {
            let viewport = CGSize(width: 600, height: 400)
            let small = EditorPreviewLayout(edge: edge, metrics: .default, count: 3)
            let large = EditorPreviewLayout(edge: edge, metrics: .default, count: 15)
            let a = EditorPreviewTransform(layout: small, viewport: viewport, screenAspect: 1.6)
            let b = EditorPreviewTransform(layout: large, viewport: viewport, screenAspect: 1.6)
            XCTAssertEqual(a.screenRect, b.screenRect)
            func anchor(_ layout: EditorPreviewLayout, _ transform: EditorPreviewTransform) -> CGPoint {
                let rect = transform.renderedRect(layout.bar)
                switch edge {
                case .left: return CGPoint(x: rect.minX, y: rect.midY)
                case .right: return CGPoint(x: rect.maxX, y: rect.midY)
                }
            }
            XCTAssertEqual(anchor(small, a).x, anchor(large, b).x, accuracy: 0.001)
            XCTAssertEqual(anchor(small, a).y, anchor(large, b).y, accuracy: 0.001)
        }
    }

    /// The canvas is a fraction of the page, under a ceiling, and never
    /// more than the page has left after everything else on it.
    ///
    /// The third bound replaced a 380 floor this round. A floor is what put
    /// 380pt of canvas in a page with 279 to spare, and the overflow rode
    /// up over the traffic lights.
    func testTheCanvasIsAFractionOfThePageUnderACeilingAndUnderWhatIsLeft() {
        XCTAssertEqual(ItemsPage.canvasHeight(pageHeight: 954), 954 * 0.45, accuracy: 0.001)
        XCTAssertEqual(ItemsPage.canvasHeight(pageHeight: 4000), 620, "a tall page should stop at the ceiling")
        let short = SettingsStyle.windowMinimum.height - SettingsStyle.titlebarInset
        XCTAssertEqual(ItemsPage.canvasHeight(pageHeight: short), short - SettingsStyle.itemsPageReserve, accuracy: 0.001,
                       "at the smallest window the canvas should take what is left, not a floor")
        // Only reachable on a display too short for the window's own
        // minimum, where something has to give; a negative canvas is the
        // one answer that would crash rather than look bad.
        XCTAssertEqual(ItemsPage.canvasHeight(pageHeight: 300), 160, "a page shorter than the window minimum should still get a canvas")
    }

    /// The drop target grows with the window, and how big it actually is.
    ///
    /// The ring is what a drag has to land on, and it is drawn at
    /// `ringDiameter` times the transform's scale. That scale is set by
    /// the whole drawer having to fit inside the canvas beside a display
    /// of the screen's aspect, so a long drawer shrinks every ring in it:
    /// at eleven items, the count the user runs, the ring measures 10.6pt
    /// on a window at its fixed minimum, 16.7pt at the height settings
    /// opens at, and 19.0pt on a window taller than this screen. At eight,
    /// the shipped count, it is 13.5pt, 21.2pt and 24.2pt. The old flat
    /// 260pt canvas put eleven items near 10pt at any size.
    ///
    /// The first of those numbers is the price of a fixed minimum: the
    /// canvas gives its height back to the rest of the page on a small
    /// window, so the smallest window has the smallest drop target. It is
    /// a window the user has to drag down to deliberately.
    ///
    /// Those numbers are also the argument for a different preview rather
    /// than a taller one: no window on this display reaches a 22pt ring at
    /// eleven items, because the limit is the drawer's length and not the
    /// canvas. Written down here so the next attempt starts from the
    /// measurement.
    func testTheDropTargetGrowsWithTheWindow() {
        func ring(pageHeight: CGFloat, count: Int) -> CGFloat {
            let layout = EditorPreviewLayout(edge: .right, metrics: .default, count: count)
            let transform = EditorPreviewTransform(
                layout: layout, viewport: CGSize(width: 730, height: ItemsPage.canvasHeight(pageHeight: pageHeight)),
                screenAspect: 1800.0 / 1169.0
            )
            return NotchLayout.ringDiameter(.default) * transform.scale
        }
        // The three heights the page actually takes: the fixed minimum,
        // the default, and a window taller than this screen.
        let minimum = SettingsStyle.windowMinimum.height - SettingsStyle.titlebarInset
        XCTAssertLessThan(ring(pageHeight: minimum, count: 11), ring(pageHeight: 948, count: 11))
        XCTAssertLessThan(ring(pageHeight: 948, count: 11), ring(pageHeight: 1200, count: 11))
        XCTAssertGreaterThan(ring(pageHeight: 948, count: 11), 16, "the ring at the default height regressed")
        XCTAssertGreaterThan(ring(pageHeight: 948, count: 8), 21, "the ring at the shipped default count regressed")
        XCTAssertGreaterThan(ring(pageHeight: minimum, count: 8), 13, "the ring at the smallest window regressed")
    }

    /// Add and Added come out the same size, so the library's right edge
    /// does not jog as rows change state.
    ///
    /// Measured rather than eyeballed: the first attempt put a minimum
    /// width on each *frame* instead of on the label inside the chip,
    /// which centred a narrow Add chip inside a wide frame and left the
    /// two chips ending about 13pt apart. Every capture that round
    /// happened to show only Added rows, so nothing caught it.
    func testAddAndAddedAreTheSameChip() {
        func size<V: View>(_ view: V) -> CGSize {
            let host = NSHostingView(rootView: view)
            host.layoutSubtreeIfNeeded()
            return host.fittingSize
        }
        let add = size(Button(action: {}) { LibraryAddColumn.addLabel }
            .buttonStyle(SettingsSecondaryButtonStyle()).controlSize(.small))
        let added = size(LibraryAddColumn.added)
        let remove = size(LibraryAddColumn.remove)
        XCTAssertEqual(add.width, added.width, accuracy: 0.5, "Add and Added are different widths")
        // Remove is the third state of the same chip: it replaces Added
        // under the pointer, so a different width would jog the column at
        // exactly the moment the pointer is over it.
        XCTAssertEqual(added.width, remove.width, accuracy: 0.5, "Added and Remove are different widths")
        XCTAssertEqual(added.height, remove.height, accuracy: 0.5, "Added and Remove are different heights")
        XCTAssertGreaterThan(add.width, LibraryAddColumn.labelWidth, "the chip lost its padding")
    }

    /// Remove takes the row's own item out, whatever is selected in the
    /// preview, and leaves the selection alone unless it was that item.
    func testRemovingFromTheLibraryTakesOutThatRowsItem() {
        let name = "LibraryRemoveTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let preferences = Preferences(defaults: defaults)
        preferences.items = [.action("wifi"), .action("bluetooth")]
        let undo = UndoManager()

        XCTAssertTrue(preferences.commit(.remove(id: EditorEntry.action(.bluetooth).id), undoManager: undo))
        XCTAssertEqual(preferences.items, [.action("wifi")])

        // And Command Z puts it back where it was, which is why the chip
        // asks nothing before it removes.
        undo.undo()
        XCTAssertEqual(preferences.items, [.action("wifi"), .action("bluetooth")])
    }

    // MARK: - The window's fixed minimum

    /// The Items page still works at the smallest window anyone can drag.
    ///
    /// This is the test the round is for. The canvas used to be floored at
    /// 380, which is more than a small window has to spare once the rest of
    /// the page is counted, so the library card fell off the bottom and the
    /// page rode up over the traffic lights. The canvas now gives back
    /// whatever `SettingsStyle.itemsPageReserve` says the rest of the page
    /// needs, and this holds that: at the minimum, two library rows are
    /// still on screen and the preview is still worth looking at.
    ///
    /// It fails if a row is added anywhere on the page without the reserve
    /// being updated, which is the drift the number is exposed to. The
    /// window is titled and `fullSizeContentView`, like the real one: a
    /// borderless test window has no titlebar safe area and would pass with
    /// 52pt the app does not have.
    func testItemsPageFitsTheSmallestWindow() throws {
        let page = SettingsStyle.windowMinimum.height - SettingsStyle.titlebarInset
        let width = SettingsStyle.windowMinimum.width - SettingsStyle.sidebarWidth - 8
        let host = layOutItemsPage(width: width, height: page)
        let list = try XCTUnwrap(findScrollView(in: host), "the library list is not in the view tree")
        // Two rows of the library. A row is 41pt, measured off the running
        // window's accessibility tree.
        XCTAssertGreaterThanOrEqual(list.frame.height, 82,
                                    "the library shows under two rows at the smallest window")
        let canvas = ItemsPage.canvasHeight(pageHeight: page)
        XCTAssertGreaterThanOrEqual(canvas, 260, "the preview at the smallest window is smaller than the old flat canvas")
        XCTAssertLessThanOrEqual(canvas + SettingsStyle.itemsPageReserve, page,
                                 "the page needs more height than the smallest window has")
    }

    /// The reserve only binds on a small window. At the height the window
    /// actually opens at, the canvas is still the 45 percent rule, so this
    /// round changed nothing about the size anybody sees first.
    func testTheReserveDoesNotBiteAtTheDefaultHeight() {
        let page = 1000 - SettingsStyle.titlebarInset
        XCTAssertEqual(ItemsPage.canvasHeight(pageHeight: page), page * 0.45, accuracy: 0.5)
        XCTAssertGreaterThan(page - SettingsStyle.itemsPageReserve, page * 0.45,
                             "the reserve is binding at the default height, so the window opens smaller than it looks")
    }

    /// The window's floor is one number in one place. The controller reads
    /// it, and only a display too short to hold it changes the answer.
    func testTheWindowMinimumIsFixedAndClampsOnlyToTheDisplay() {
        XCTAssertEqual(SettingsWindowController.minimum(fitting: CGSize(width: 1800, height: 1042)),
                       SettingsStyle.windowMinimum)
        XCTAssertEqual(SettingsWindowController.minimum(fitting: CGSize(width: 1440, height: 760)),
                       CGSize(width: SettingsStyle.windowMinimum.width, height: 760))
    }

    /// Lays the page out in a window the shape of the real one and hands
    /// back the hosting view, so a test can read what actually got laid
    /// out rather than what the view asked for.
    private func layOutItemsPage(width: CGFloat, height: CGFloat) -> NSView {
        let name = "SettingsMinimumTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let preferences = Preferences(defaults: defaults)
        let page = ItemsPage(preferences: preferences, shortcuts: ShortcutsCatalog(), apps: AppCatalog(),
                             editor: DrawerEditor(), session: SettingsSession(page: .items))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        let host = NSHostingView(rootView: page)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        // A display pass, for the same reason the render tests do one:
        // `layoutSubtreeIfNeeded` alone leaves a `GeometryReader`
        // descendant's frame unsettled, and the canvas height is read
        // through one.
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
        }
        host.layoutSubtreeIfNeeded()
        return host
    }

    private func findScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for subview in view.subviews {
            if let found = findScrollView(in: subview) { return found }
        }
        return nil
    }
}
