import SwiftUI
import XCTest
@testable import Drawer

private struct FakeScreen: ScreenDescribing {
    var frameValue: CGRect
    var visibleFrameValue: CGRect
}

/// More cells than fit stay reachable: the bar caps its own length at what the
/// screen holds, and the rest scrolls under the wheel.
@MainActor
final class ScrollTests: XCTestCase {
    func testCardPlacementClearsWhenSourceLeavesVisibleRangeOrIsRemoved() {
        let model = NotchViewModel()
        model.cells = Fixtures.cells(30)
        model.adopt(screen: screen(height: 700))
        model.hoveredIndex = 0
        XCTAssertNotNil(model.cardPlacement(index: 0))
        model.firstVisibleIndex = 1
        XCTAssertNil(model.hoveredIndex)
        XCTAssertNil(model.cardPlacement(index: 0))
        model.hoveredIndex = 1
        model.replaceCells([DrawerCell.add])
        XCTAssertNil(model.hoveredIndex)
    }

    func testCardPlacementHasDetachedBodyAndBridgeForEveryEdge() {
        for edge in NotchEdge.allCases {
            for cellSize in Theme.CellSize.allCases {
                for showsLabels in [false, true] {
                    for cardText in Theme.CardText.allCases {
                        let model = NotchViewModel()
                        model.edge = edge
                        model.theme.cellSize = cellSize
                        model.theme.showsLabels = showsLabels
                        model.theme.cardText = cardText
                        model.cells = Fixtures.cells(3)
                        let place = model.placement
                        for index in 0..<3 {
                            guard let card = model.cardPlacement(index: index) else { return XCTFail("missing card") }
                            let near = min(place.across(of: CGPoint(x: card.body.minX, y: card.body.midY)),
                                           place.across(of: CGPoint(x: card.body.maxX, y: card.body.midY)))
                            XCTAssertEqual(near, model.tooltipInset, accuracy: 0.01)
                            XCTAssertEqual(near - NotchLayout.bodyDepth(for: edge, metrics: model.metrics), NotchLayout.cardGap, accuracy: 0.01)
                            XCTAssertTrue(CGRect(origin: .zero, size: model.panelSize).contains(card.body))
                            XCTAssertGreaterThan(card.bridge.width, 0)
                            XCTAssertGreaterThan(card.bridge.height, 0)
                        }
                    }
                }
            }
        }
    }

    private func screen(width: CGFloat = 1800, height: CGFloat, usableWidth: CGFloat? = nil) -> FakeScreen {
        FakeScreen(
            frameValue: CGRect(x: 0, y: 0, width: width, height: height),
            visibleFrameValue: CGRect(x: 0, y: 0, width: usableWidth ?? width, height: height - 37)
        )
    }

    private func model(edge: NotchEdge = .right, height: CGFloat, usableWidth: CGFloat? = nil) -> NotchViewModel {
        let model = NotchViewModel()
        model.edge = edge
        model.adopt(screen: screen(height: height, usableWidth: usableWidth))
        return model
    }

    // MARK: - fitCount

    /// A screen fits `fitCount` cells and not one more, on every size that
    /// matters: a 14 inch, a 16 inch, and a 5K display.
    private func assertFitsExactly(_ model: NotchViewModel, within limit: CGFloat, file: StaticString = #filePath, line: UInt = #line) {
        let fit = model.fitCount
        let dimension: (Int) -> CGFloat = { n in
            let size = model.panelSize(cellCount: n)
            return size.height
        }
        XCTAssertLessThanOrEqual(dimension(fit), limit, file: file, line: line)
        XCTAssertGreaterThan(dimension(fit + 1), limit, file: file, line: line)
    }

    func testFitCountOnA14Inch() {
        let m = model(height: 982)
        assertFitsExactly(m, within: 982)
    }

    func testOneCellPastTheFitOverflowsA16Inch() {
        let m = model(height: 1117)
        assertFitsExactly(m, within: 1117)
    }

    func testFitCountOnA5K() {
        let m = model(height: 1440)
        assertFitsExactly(m, within: 1440)
    }

    // MARK: - visibleCount and scroll clamping

    func testVisibleCountIsTheCellCountCappedByTheFit() {
        let m = model(height: 982)
        m.cells = Fixtures.cells(3)
        XCTAssertEqual(m.visibleCount, min(3, m.fitCount))

        m.cells = Fixtures.cells(17)
        XCTAssertEqual(m.visibleCount, m.fitCount, "17 should overflow a 14 inch screen")
    }

    func testReplaceCellsWithFewerThanFitResetsToTheTop() {
        let m = model(height: 982)
        m.cells = Fixtures.cells(17)
        m.firstVisibleIndex = m.cells.count - m.visibleCount
        XCTAssertGreaterThan(m.firstVisibleIndex, 0, "setup: needs to start scrolled")

        m.replaceCells(Fixtures.cells(2))
        XCTAssertEqual(m.firstVisibleIndex, 0)
    }

    func testShrinkingTheListClampsFirstVisibleIndex() {
        let m = model(height: 982)
        m.cells = Fixtures.cells(17)
        m.firstVisibleIndex = m.cells.count - m.visibleCount
        let fit = m.visibleCount

        m.replaceCells(Fixtures.cells(fit))
        XCTAssertEqual(m.firstVisibleIndex, 0)
    }

    func testClampScrollAfterAnEdgeChangeStaysInRange() {
        let m = model(height: 982)
        m.cells = Fixtures.cells(17)
        m.firstVisibleIndex = m.cells.count - m.visibleCount

        m.edge = .left
        m.adopt(screen: screen(height: 1169, usableWidth: 900))
        m.clampScroll()

        XCTAssertLessThanOrEqual(m.firstVisibleIndex, max(0, m.cells.count - m.visibleCount))
    }

    func testFoldingResetsScrollToTheTop() {
        let controller = NotchWindowController()
        controller.model.isExpanded = true
        controller.model.firstVisibleIndex = 5

        controller.foldForAction()

        XCTAssertEqual(controller.model.firstVisibleIndex, 0)
    }

    // MARK: - geometricIndex

    func testGeometricIndexIsNilForAHiddenCell() {
        let m = model(height: 982)
        m.cells = Fixtures.cells(17)
        m.firstVisibleIndex = 2
        XCTAssertLessThan(m.firstVisibleIndex + m.visibleCount, m.cells.count,
                          "setup: needs cells past the window too")

        XCTAssertEqual(m.geometricIndex(of: 2), 0)
        XCTAssertNil(m.geometricIndex(of: 0), "scrolled behind the window")
        XCTAssertNil(m.geometricIndex(of: m.cells.count - 1), "past the window")
    }

    // MARK: - wheel

    private func expandedController(cellCount: Int = 17, height: CGFloat = 982) -> NotchWindowController {
        let controller = NotchWindowController()
        controller.model.edge = .right
        controller.model.adopt(screen: screen(height: height))
        controller.model.cells = Fixtures.cells(cellCount)
        controller.model.isExpanded = true
        return controller
    }

    func testAPreciseDeltaStepsOncePerHalfPitch() {
        let c = expandedController()
        let threshold = NotchLayout.cellPitch(for: .right) / 2

        c.wheel(deltaAlong: threshold, precise: true, momentum: false)

        XCTAssertEqual(c.model.firstVisibleIndex, 1)
    }

    func testAMouseNotchStepsOncePerEvent() {
        let c = expandedController()

        c.wheel(deltaAlong: 1, precise: false, momentum: false)
        XCTAssertEqual(c.model.firstVisibleIndex, 1)
        c.wheel(deltaAlong: 1, precise: false, momentum: false)
        XCTAssertEqual(c.model.firstVisibleIndex, 2)
    }

    func testMomentumIsIgnored() {
        let c = expandedController()

        c.wheel(deltaAlong: 1000, precise: true, momentum: true)

        XCTAssertEqual(c.model.firstVisibleIndex, 0)
    }

    func testWheelIsIgnoredWhileFolded() {
        let c = expandedController()
        c.model.isExpanded = false

        c.wheel(deltaAlong: 1, precise: false, momentum: false)

        XCTAssertEqual(c.model.firstVisibleIndex, 0)
    }

    func testScrollingPastTheEndBouncesAndSettles() {
        let c = expandedController()
        let maxStart = c.model.cells.count - c.model.visibleCount
        XCTAssertGreaterThan(maxStart, 0, "setup: needs room to scroll")

        for _ in 0..<maxStart {
            c.wheel(deltaAlong: 1, precise: false, momentum: false)
        }
        XCTAssertEqual(c.model.firstVisibleIndex, maxStart)
        XCTAssertEqual(c.model.overscroll, 0, "landing exactly at the end is not an overscroll")

        c.wheel(deltaAlong: 1, precise: false, momentum: false)
        XCTAssertNotEqual(c.model.overscroll, 0, "pushing past the end should bounce")

        let settled = expectation(description: "overscroll returns to zero")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { settled.fulfill() }
        wait(for: [settled], timeout: 1)
        XCTAssertEqual(c.model.overscroll, 0)
    }

    // MARK: - cellIndex

    func testCellIndexReturnsFirstVisiblePlusSlot() {
        let c = expandedController()
        c.model.firstVisibleIndex = 2

        let slot0 = c.model.slack + c.model.ringCenter(visible: 0)
        let slot1 = c.model.slack + c.model.ringCenter(visible: 1)

        XCTAssertEqual(c.cellIndex(along: slot0), 2)
        XCTAssertEqual(c.cellIndex(along: slot1), 3)
    }

    // MARK: - tooltipRect

    func testTooltipRectIsNilForAHiddenCell() {
        let c = expandedController()
        c.model.firstVisibleIndex = 2
        XCTAssertLessThan(c.model.firstVisibleIndex + c.model.visibleCount, c.model.cells.count,
                          "setup: needs cells past the window too")

        XCTAssertNil(c.tooltipRect(index: 0), "scrolled behind the window")
        XCTAssertNotNil(c.tooltipRect(index: c.model.firstVisibleIndex))
    }
}

/// The chevrons are the only thing that says there is more to see. They have
/// to actually paint, in the band they are meant to, and nowhere else.
@MainActor
final class ScrollChevronRenderTests: XCTestCase {
    private func render(_ model: NotchViewModel) -> NSBitmapImageRep? {
        let size = model.panelSize
        let renderer = ImageRenderer(
            content: NotchRootView(model: model).frame(width: size.width, height: size.height)
        )
        renderer.scale = 1
        guard let image = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: image)
    }

    private func model(firstVisibleIndex: Int = 0) -> NotchViewModel {
        let model = NotchViewModel()
        model.edge = .right
        model.screenSize = CGSize(width: 1800, height: 982)
        model.screenUsableSize = CGSize(width: 1800, height: 945)
        model.isExpanded = true
        model.cells = Fixtures.cells(17)
        model.firstVisibleIndex = firstVisibleIndex
        return model
    }

    private func startBand(_ model: NotchViewModel) -> ClosedRange<CGFloat> {
        let start = model.slack + NotchLayout.curlRadius
        return start...(start + NotchLayout.padStart(for: model.edge))
    }

    private func endBand(_ model: NotchViewModel) -> ClosedRange<CGFloat> {
        let end = model.slack + model.shapeLength - NotchLayout.curlRadius
        return (end - NotchLayout.padEnd(for: model.edge))...end
    }

    /// A chevron paints `Palette.textSecondary`, a mid grey; the notch behind
    /// it is plain black. Red tells the two apart.
    private func chevronVisible(_ model: NotchViewModel, rep: NSBitmapImageRep, along: ClosedRange<CGFloat>) -> Bool {
        let place = NotchPlacement(edge: model.edge, panelSize: model.panelSize)
        let glyphExtent = NotchLayout.scrollHintGlyph + 2
        let band = place.rect(
            along: (along.lowerBound + along.upperBound - glyphExtent) / 2,
            across: (NotchLayout.bodyDepth(for: model.edge) - glyphExtent) / 2,
            length: glyphExtent,
            depth: glyphExtent
        )
        for x in stride(from: max(0, band.minX), to: min(CGFloat(rep.pixelsWide), band.maxX), by: 1) {
            for y in stride(from: max(0, band.minY), to: min(CGFloat(rep.pixelsHigh), band.maxY), by: 1) {
                guard let colour = rep.colorAt(x: Int(x), y: Int(y)) else { continue }
                if colour.alphaComponent > 0.1, colour.redComponent > 0.25 { return true }
            }
        }
        return false
    }

    func testTheDownChevronPaintsAtTheTopAndTheUpOneDoesNot() {
        let m = model(firstVisibleIndex: 0)
        guard let rep = render(m) else { return XCTFail("no image") }

        XCTAssertFalse(chevronVisible(m, rep: rep, along: startBand(m)),
                       "nothing is scrolled behind the first cell")
        XCTAssertTrue(chevronVisible(m, rep: rep, along: endBand(m)),
                      "17 cells overflow the fit, so there is more below")
    }

    func testBothChevronsPaintOnceScrolledIntoTheMiddle() {
        let m = model()
        let maxStart = max(0, m.cells.count - m.visibleCount)
        m.firstVisibleIndex = maxStart / 2
        XCTAssertGreaterThan(m.firstVisibleIndex, 0, "setup: needs to actually be scrolled")
        guard let rep = render(m) else { return XCTFail("no image") }

        XCTAssertTrue(chevronVisible(m, rep: rep, along: startBand(m)))
        XCTAssertTrue(chevronVisible(m, rep: rep, along: endBand(m)))
    }
}
