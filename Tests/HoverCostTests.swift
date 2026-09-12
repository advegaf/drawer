import SwiftUI
import XCTest
@testable import Drawer

/// What the drawer costs per frame, counted rather than timed.
///
/// The report was that everything gets slower as more actions are pinned:
/// hovering between cells, the open and close, dragging a level, scrolling.
/// The animation's own timing never changed, so what grew was work, and the
/// work that grew was AppKit text layout: `fitCount` walks up to 200 panel
/// sizes, each of which measured every cell's card.
///
/// These count `NotchLayout`'s text measurements across one render and one
/// pointer move at three cell counts. A count, not a stopwatch: a millisecond
/// figure on a machine doing other things says more about the machine than
/// about the change, and the whole point of this round is that the same
/// picture should cost less.
@MainActor
final class HoverCostTests: XCTestCase {
    /// A 14 inch MacBook Pro in points, which is the display this was
    /// reported on and the one that makes `fitCount` walk furthest.
    private let screen = CGSize(width: 1512, height: 982)

    private func model(cells count: Int) -> NotchViewModel {
        let model = NotchViewModel()
        model.edge = .right
        model.isExpanded = true
        model.screenSize = screen
        model.screenUsableSize = screen
        model.cells = Fixtures.cells(count)
        return model
    }

    private func measuring(_ work: () -> Void) -> Int {
        NotchLayout.textMeasurements = 0
        work()
        return NotchLayout.textMeasurements
    }

    /// One render of the real view, which is what a hover change, a fold, a
    /// scroll step and a level drag each cause several of.
    private func renderCost(cells count: Int) -> Int {
        let model = model(cells: count)
        model.hoveredIndex = min(1, count - 1)
        let size = model.panelSize
        // Warm anything AppKit caches on first use, so the count is the cost
        // of a frame rather than the cost of the first frame.
        _ = ImageRenderer(content: NotchRootView(model: model)
            .frame(width: size.width, height: size.height)).cgImage
        return measuring {
            let renderer = ImageRenderer(content: NotchRootView(model: model)
                .frame(width: size.width, height: size.height))
            renderer.scale = 1
            _ = renderer.cgImage
        }
    }

    /// One pointer move over the open drawer, which arrives at up to 120Hz.
    private func pointerCost(cells count: Int) -> Int? {
        let controller = NotchWindowController()
        controller.show()
        defer { controller.stop() }
        controller.model.cells = Fixtures.cells(count)
        controller.model.isExpanded = true
        guard let frame = controller.panelFrameForTesting else { return nil }
        let rect = controller.notchRect
        let local = CGPoint(x: rect.midX, y: rect.midY)
        let point = CGPoint(x: local.x + frame.minX, y: frame.maxY - local.y)
        controller.cursorLocation = { point }
        controller.pointerMoved(at: point, fromMonitor: true)   // warm
        return measuring { controller.pointerMoved(at: point, fromMonitor: true) }
    }

    func testTextMeasurementsPerRender() {
        var line: [String] = []
        for count in [3, 8, 17] {
            let cost = renderCost(cells: count)
            line.append("\(count) cells: \(cost)")
            XCTAssertLessThan(
                cost, 400,
                "\(count) cells: a single render laid out text \(cost) times. "
                + "One card's worth is two, so this is the fitCount walk leaking into the frame."
            )
        }
        print("[hover cost] render  " + line.joined(separator: ", "))
    }

    func testTextMeasurementsPerPointerMove() {
        var line: [String] = []
        for count in [3, 8, 17] {
            guard let cost = pointerCost(cells: count) else {
                XCTFail("\(count) cells: no panel to move a pointer over")
                continue
            }
            line.append("\(count) cells: \(cost)")
            XCTAssertLessThan(
                cost, 200,
                "\(count) cells: one mouse move laid out text \(cost) times, and these arrive at 120Hz."
            )
        }
        print("[hover cost] pointer " + line.joined(separator: ", "))
    }

    /// The unit underneath both. `panelSize` still measures every cell for its
    /// depth, which is deliberate: that is the room the window reserves for the
    /// widest card any pinned cell could ever open, and it is computed on
    /// layout rather than per frame, since the controller's own `placement`
    /// reads the panel's real frame. What must stay free of text is the half
    /// the fit walk runs up to 200 times.
    func testTheHalfOfThePanelTheFitWalkTestsMeasuresNoText() {
        let model = model(cells: 17)
        _ = model.panelLength(cellCount: 8)   // warm
        let cost = measuring { _ = model.panelLength(cellCount: 8) }
        XCTAssertEqual(
            cost, 0,
            "panelLength laid out text \(cost) times at 17 cells. "
            + "fitCount calls it up to 200 times per read and is read dozens of times per frame, "
            + "so nothing on this path may measure a string."
        )
    }

    /// The walk itself, which every geometry getter on the model bottoms out
    /// in. Reading it must not cost a text measurement per cell per step.
    func testTheFitWalkIsNotProportionalToCellCount() {
        let small = model(cells: 3)
        let large = model(cells: 17)
        _ = small.fitCount
        _ = large.fitCount
        let smallCost = measuring { _ = small.fitCount }
        let largeCost = measuring { _ = large.fitCount }
        XCTAssertLessThanOrEqual(
            largeCost, smallCost + 40,
            "the fit walk cost \(smallCost) measurements at 3 cells and \(largeCost) at 17. "
            + "It is read dozens of times per frame, so it cannot grow with the list."
        )
    }
}
