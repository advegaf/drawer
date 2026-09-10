import AppKit
import Combine
import XCTest
@testable import Drawer

@MainActor
final class NativeEditorTests: XCTestCase {
    private let a = DrawerItem.shortcut(name: "A")
    private let b = DrawerItem.shortcut(name: "B")
    private let c = DrawerItem.shortcut(name: "C")

    func testReorderAlwaysUsesOriginalBaselineAndAcceptsOnce() {
        let payload = DrawerDrag(id: "pinned|" + a.id, itemID: a.id, source: .pinned, token: UUID())
        var session = EditorDragSession(input: .local(payload), baseline: [a, b, c], incoming: [a], movingID: a.id)
        XCTAssertTrue(session.propose(.after(c.id), current: [a, b, c]))
        XCTAssertEqual(session.displayed, [b, c, a])
        XCTAssertTrue(session.propose(.before(b.id), current: [a, b, c]))
        XCTAssertEqual(session.displayed, [a, b, c])
        XCTAssertFalse(session.accept(current: [a, b, c]))
        XCTAssertTrue(session.propose(.after(b.id), current: [a, b, c]))
        XCTAssertTrue(session.accept(current: [a, b, c]))
        XCTAssertFalse(session.accept(current: [a, b, c]))
    }

    func testStaleAndCancelledSessionsCannotAccept() {
        let payload = DrawerDrag(id: "pinned|" + a.id, itemID: a.id, source: .pinned, token: UUID())
        var session = EditorDragSession(input: .local(payload), baseline: [a, b], incoming: [a], movingID: a.id)
        XCTAssertFalse(session.propose(.end, current: [b, a]))
        XCTAssertEqual(session.phase, .cancelled)
        XCTAssertFalse(session.accept(current: [a, b]))
    }

    func testLeavingDestinationRestoresBaselineAndAllowsReentry() {
        let payload = DrawerDrag(id: "pinned|" + a.id, itemID: a.id, source: .pinned, token: UUID())
        var session = EditorDragSession(input: .local(payload), baseline: [a, b], incoming: [a], movingID: a.id)
        XCTAssertTrue(session.propose(.end, current: [a, b]))
        XCTAssertEqual(session.displayed, [b, a])
        session.clearProposal()
        XCTAssertEqual(session.displayed, [a, b])
        XCTAssertTrue(session.propose(.end, current: [a, b]))
        XCTAssertTrue(session.accept(current: [a, b]))
    }

    func testFitShowsWholeDrawerAndTransformRoundTrips() {
        let viewport = CGSize(width: 350, height: 400)
        let layout = EditorPreviewLayout(edge: .right, metrics: .default, count: 500)
        let transform = EditorPreviewTransform(layout: layout, viewport: viewport, screenAspect: 1.6)
        XCTAssertLessThan(transform.scale, 0.05)
        let rendered = transform.renderedRect(CGRect(origin: .zero, size: layout.size))
        XCTAssertTrue(CGRect(origin: .zero, size: viewport).contains(rendered))
        let point = layout.center(200)
        let roundTrip = transform.canvasPoint(transform.renderedPoint(point))
        XCTAssertEqual(roundTrip.x, point.x, accuracy: 0.001)
        XCTAssertEqual(roundTrip.y, point.y, accuracy: 0.001)
    }

    func testDisplayAndEdgeAnchorStayFixedAcrossMetricsAndCounts() {
        for edge in NotchEdge.allCases {
            var previousScreen: CGRect?
            var previousAnchor: CGPoint?
            for count in [1, 4, 12, 100] {
                for size in Theme.CellSize.allCases {
                    var theme = Theme.default
                    theme.cellSize = size
                    let layout = EditorPreviewLayout(edge: edge, metrics: theme.metrics, count: count)
                    let transform = EditorPreviewTransform(layout: layout, viewport: CGSize(width: 420, height: 330), screenAspect: 1.6)
                    let bar = transform.renderedRect(layout.bar)
                    let anchor: CGPoint
                    switch edge {
                    case .right: anchor = CGPoint(x: bar.maxX, y: bar.midY)
                    case .left: anchor = CGPoint(x: bar.minX, y: bar.midY)
                    }
                    if let previousScreen { XCTAssertEqual(transform.screenRect, previousScreen) }
                    if let previousAnchor {
                        XCTAssertEqual(anchor.x, previousAnchor.x, accuracy: 0.001)
                        XCTAssertEqual(anchor.y, previousAnchor.y, accuracy: 0.001)
                    }
                    previousScreen = transform.screenRect
                    previousAnchor = anchor
                }
            }
        }
    }

    func testNativeGhostHasOpaqueResolvedSurfaceInBothAppearances() throws {
        let symbol = try XCTUnwrap(NSImage(systemSymbolName: "wifi", accessibilityDescription: nil))
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let image = NativeEditorDragView.badge(image: symbol, appearance: try XCTUnwrap(NSAppearance(named: name)))
            let data = try XCTUnwrap(image.tiffRepresentation)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
            let surface = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 8))
            XCTAssertEqual(surface.alphaComponent, 1, accuracy: 0.01)
            XCTAssertFalse(image.isTemplate)
        }
    }

    func testInitialGhostFrameStaysInsideSourceForLargeFirstDragMovement() {
        let visible = CGRect(x: 0, y: 0, width: 211, height: 34)
        let frame = NativeEditorDragView.initialFrame(at: CGPoint(x: 52, y: 16.5), visibleRect: visible)
        XCTAssertTrue(visible.contains(frame))
        XCTAssertEqual(frame.width, 34)
        XCTAssertEqual(frame.midX, 52, accuracy: 0.001)
        let edge = NativeEditorDragView.initialFrame(at: CGPoint(x: 210, y: 33), visibleRect: visible)
        XCTAssertTrue(visible.contains(edge))
    }

    func testNativeCompletionCapturesOriginalCallbackOnce() throws {
        let view = NativeEditorDragView()
        let payload = DrawerDrag(id: "library|" + a.id, itemID: a.id, source: .library, token: UUID())
        view.begin = { _ in NativeEditorDrag(payload: payload, image: NSImage()) }
        var original = 0
        var replacement = 0
        view.ended = { _ in original += 1 }
        _ = try XCTUnwrap(view.prepareDrag(at: .zero))
        view.ended = { _ in replacement += 1 }
        view.finishDrag()
        view.finishDrag()
        XCTAssertEqual(original, 1)
        XCTAssertEqual(replacement, 0)
    }

    func testRemovedPinnedSourceCannotBeginDrag() {
        let editor = DrawerEditor()
        XCTAssertNil(editor.beginNative(EditorEntry.shortcut("Removed"), source: .pinned, items: [a]))
        XCTAssertNil(editor.session)
        XCTAssertNil(editor.drag)
    }

    func testAppBatchPublishesOnceAndUndoPreservesUnrelatedEdit() {
        let defaults = UserDefaults(suiteName: "NativeEditorTests.\(UUID().uuidString)")!
        let preferences = Preferences(defaults: defaults)
        preferences.items = [a, b]
        let undo = UndoManager()
        undo.groupsByEvent = false
        let first = DrawerItem.app(bundleID: "example.first")
        let second = DrawerItem.app(bundleID: "example.second")
        var publications = 0
        let observation = preferences.$items.dropFirst().sink { _ in publications += 1 }
        undo.beginUndoGrouping()
        XCTAssertTrue(preferences.commitApps([first, second], before: b.id, undoManager: undo))
        undo.endUndoGrouping()
        XCTAssertEqual(publications, 1)
        XCTAssertEqual(preferences.items, [a, first, second, b])
        XCTAssertTrue(preferences.commit(.add(c, before: nil)))
        undo.undo()
        XCTAssertEqual(preferences.items, [a, b, c])
        undo.redo()
        XCTAssertEqual(preferences.items, [a, first, second, b, c])
        withExtendedLifetime(observation) {}
    }

    func testInvalidBatchDoesNotPartiallyMutate() {
        let defaults = UserDefaults(suiteName: "NativeEditorTests.\(UUID().uuidString)")!
        let preferences = Preferences(defaults: defaults)
        preferences.items = [a]
        XCTAssertFalse(preferences.commitApps([.app(bundleID: "example.app"), b], before: nil))
        XCTAssertEqual(preferences.items, [a])
    }

    func testFinderValidationPreservesOrderDeduplicatesAndRejectsMixedInput() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try makeApp(root: root, name: "Z", id: "example.z")
        let second = try makeApp(root: root, name: "A", id: "example.a")
        let duplicate = try makeApp(root: root, name: "Z2", id: "example.z")
        XCTAssertEqual(FinderAppValidation.entries([first, second, duplicate])?.map(\.bundleID), ["example.z", "example.a"])
        XCTAssertNil(FinderAppValidation.entries([first, root.appendingPathComponent("missing.app")]))
        XCTAssertNil(FinderAppValidation.entries([URL(string: "https://example.com/A.app")!]))
        XCTAssertNil(FinderAppValidation.entries([]))
    }

    func testCancelledFinderSequenceCannotRestartButNextDragCan() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try makeApp(root: root, name: "A", id: "example.cancel")
        let editor = DrawerEditor()
        let input = EditorDragInput.files([app], sequence: 41)
        XCTAssertTrue(editor.prepare(input, items: [], library: []))
        editor.cancel()
        XCTAssertFalse(editor.prepare(input, items: [], library: []))
        XCTAssertTrue(editor.prepare(.files([app], sequence: 42), items: [], library: []))
    }

    func testMidpointTargetsOnEveryEdgeExcludeMovingPlaceholder() {
        let entries = [EditorEntry.shortcut("A"), EditorEntry.shortcut("B"), EditorEntry.shortcut("C")]
        for edge in NotchEdge.allCases {
            let layout = EditorPreviewLayout(edge: edge, metrics: .default, count: 3)
            let along = layout.placement.along(of: layout.center(1))
            let point = layout.placement.point(along: along + 1, across: 20)
            XCTAssertEqual(layout.position(at: point, entries: entries, excluding: [a.id]), .after(b.id))
            XCTAssertEqual(layout.position(at: point, entries: [], excluding: []), .end)
        }
    }

    private func makeApp(root: URL, name: String, id: String) throws -> URL {
        let url = root.appendingPathComponent(name + ".app")
        let contents = url.appendingPathComponent("Contents")
        let executable = contents.appendingPathComponent("MacOS/Test")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        let plist = ["CFBundleIdentifier": id, "CFBundleName": name, "CFBundlePackageType": "APPL", "CFBundleExecutable": "Test"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        try Data("fixture".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return url
    }
}
