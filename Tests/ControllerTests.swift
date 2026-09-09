import AppKit
import Combine
import XCTest
@testable import Drawer

/// Drives the controller through its pointer seam with an injected cursor,
/// rather than a real mouse, so hover, fold and click behaviour can be
/// checked without one.
@MainActor
final class ControllerTests: XCTestCase {
    private func pump(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// The inverse of the controller's own screen-to-panel conversion, so a
    /// test can turn a point from `pillRect`, `notchRect` or `liveRect` into
    /// the screen point `pointerMoved(at:)` expects.
    private func screenPoint(local: CGPoint, frame: CGRect) -> CGPoint {
        CGPoint(x: local.x + frame.minX, y: frame.maxY - local.y)
    }

    func testPointerInsidePillHotZoneExpandsTheNotch() {
        let controller = NotchWindowController()
        controller.show()
        defer { controller.stop() }
        guard let frame = controller.panelFrameForTesting else {
            XCTFail("no panel frame to build a screen point from")
            return
        }

        let point = screenPoint(
            local: CGPoint(x: controller.pillRect.midX, y: controller.pillRect.midY),
            frame: frame
        )
        controller.cursorLocation = { point }
        controller.dwell = 0.02
        controller.pointerMoved(at: point, fromMonitor: true)
        pump(0.05)

        XCTAssertTrue(controller.model.isExpanded, "a pointer in the pill's hot zone should open it")
    }

    func testItFoldsAfterTheFoldGraceOnceThePointerLeaves() {
        let controller = NotchWindowController()
        controller.show()
        defer { controller.stop() }
        guard let frame = controller.panelFrameForTesting else {
            XCTFail("no panel frame to build a screen point from")
            return
        }

        let inside = screenPoint(
            local: CGPoint(x: controller.pillRect.midX, y: controller.pillRect.midY),
            frame: frame
        )
        controller.cursorLocation = { inside }
        controller.dwell = 0.02
        controller.pointerMoved(at: inside, fromMonitor: true)
        pump(0.05)
        XCTAssertTrue(controller.model.isExpanded, "setup: it should be open before it can fold")

        // Far outside the panel altogether, so it is outside every rect
        // regardless of edge or cell count.
        let outside = CGPoint(x: frame.minX - 500, y: frame.minY - 500)
        controller.cursorLocation = { outside }
        controller.pointerMoved(at: outside)
        pump(0.6)   // past foldGrace's 0.45s, with margin for a busy scheduler

        XCTAssertFalse(controller.model.isExpanded, "it should have folded once the grace period passed")
    }

    func testPointerDownOnTheOpenBarAwayFromACellOrTheOrbTogglesPinned() {
        let controller = NotchWindowController()
        controller.show()
        defer { controller.stop() }
        guard let frame = controller.panelFrameForTesting else {
            XCTFail("no panel frame to build a screen point from")
            return
        }

        let hover = screenPoint(
            local: CGPoint(x: controller.pillRect.midX, y: controller.pillRect.midY),
            frame: frame
        )
        controller.cursorLocation = { hover }
        controller.dwell = 0.02
        controller.pointerMoved(at: hover, fromMonitor: true)
        pump(0.05)
        XCTAssertTrue(controller.model.isExpanded, "setup: the bar has to be open for a click on it to pin")
        XCTAssertFalse(controller.model.isPinned)

        // The near corner of the notch: with no cells there is nothing to
        // hit, and the orb sits at the far end of the stack, so this is on
        // the open bar but away from either.
        let notch = controller.notchRect
        let onTheBar = screenPoint(local: CGPoint(x: notch.minX + 2, y: notch.minY + 2), frame: frame)
        controller.pointerDown(at: onTheBar)

        XCTAssertTrue(controller.model.isPinned, "a click on the open bar, away from a cell or the orb, should pin it")
    }

    /// `pointerDown(at:)` itself is location-blind while folded: `handleClick`
    /// always read that way, and turning that into a stub-level position
    /// check would be a behaviour change this phase does not make. What
    /// actually keeps a stray click outside the live region from doing
    /// anything is one layer up, in `NotchPanel.mouseDown` and
    /// `NotchHostingView.hitTest`, which refuse the event before `onClick` (and
    /// so `pointerDown(at:)`) is ever called. This test exercises that gate
    /// directly, the same way `NotchPanel.mouseDown` does, rather than calling
    /// `pointerDown(at:)` and bypassing it.
    func testAPointOutsideLiveRectIsNotHitTestableWhileFolded() {
        let controller = NotchWindowController()
        controller.show()
        defer { controller.stop() }
        guard let frame = controller.panelFrameForTesting else {
            XCTFail("no panel frame to build a screen point from")
            return
        }
        XCTAssertFalse(controller.model.isExpanded)

        let inside = screenPoint(
            local: CGPoint(x: controller.pillRect.midX, y: controller.pillRect.midY),
            frame: frame
        )
        let outside = CGPoint(x: frame.minX - 500, y: frame.minY - 500)

        // `event.locationInWindow` is a screen point relative to the window's
        // own origin, with no axis flip; that is what `NotchPanel.mouseDown`
        // hands to `contentView.hitTest`.
        let insideWindowPoint = CGPoint(x: inside.x - frame.minX, y: inside.y - frame.minY)
        let outsideWindowPoint = CGPoint(x: outside.x - frame.minX, y: outside.y - frame.minY)

        XCTAssertNotNil(
            controller.panelContentViewForTesting?.hitTest(insideWindowPoint),
            "sanity check: the pill itself must still be hit-testable"
        )
        XCTAssertNil(
            controller.panelContentViewForTesting?.hitTest(outsideWindowPoint),
            "a point outside the live region should never reach onClick at all"
        )
        XCTAssertFalse(controller.model.isExpanded)
        XCTAssertFalse(controller.model.isPinned)
    }

    /// The poll and the two monitors used to be interchangeable. Now only the
    /// monitor path may arm the dwell that opens the notch on hover; the poll
    /// is there purely to notice a pointer that never moved.
    func testDwellOpensAfterTheIntervalOfMonitorMovesAndNotBefore() {
        let controller = NotchWindowController()
        controller.show()
        defer { controller.stop() }
        controller.dwell = 0.1
        guard let frame = controller.panelFrameForTesting else {
            XCTFail("no panel frame to build a screen point from")
            return
        }
        let point = screenPoint(
            local: CGPoint(x: controller.pillRect.midX, y: controller.pillRect.midY),
            frame: frame
        )
        controller.cursorLocation = { point }
        controller.pointerMoved(at: point, fromMonitor: true)

        XCTAssertFalse(controller.model.isExpanded, "it opened before the dwell had elapsed")
        pump(0.2)
        XCTAssertTrue(controller.model.isExpanded, "it never opened once the dwell elapsed")
    }

    func testAPollTickAloneNeverOpensTheNotch() {
        let controller = NotchWindowController()
        controller.show()
        defer { controller.stop() }
        controller.dwell = 0.02
        guard let frame = controller.panelFrameForTesting else {
            XCTFail("no panel frame to build a screen point from")
            return
        }
        let point = screenPoint(
            local: CGPoint(x: controller.pillRect.midX, y: controller.pillRect.midY),
            frame: frame
        )
        controller.cursorLocation = { point }
        controller.pointerMoved(at: point, fromMonitor: false)   // stands in for the poll
        pump(0.1)

        XCTAssertFalse(controller.model.isExpanded, "a poll tick armed the dwell on its own")
    }

    func testADragNeverArmsTheDwell() {
        let controller = NotchWindowController()
        controller.show()
        defer { controller.stop() }
        controller.dwell = 0.02
        guard let frame = controller.panelFrameForTesting else {
            XCTFail("no panel frame to build a screen point from")
            return
        }
        let point = screenPoint(
            local: CGPoint(x: controller.pillRect.midX, y: controller.pillRect.midY),
            frame: frame
        )
        controller.cursorLocation = { point }
        controller.pointerDragged(at: point)
        pump(0.1)

        XCTAssertFalse(controller.model.isExpanded, "a drag should never arm the dwell")
    }

    func testLeavingThePillCancelsTheDwell() {
        let controller = NotchWindowController()
        controller.show()
        defer { controller.stop() }
        controller.dwell = 0.05
        guard let frame = controller.panelFrameForTesting else {
            XCTFail("no panel frame to build a screen point from")
            return
        }
        let inside = screenPoint(
            local: CGPoint(x: controller.pillRect.midX, y: controller.pillRect.midY),
            frame: frame
        )
        controller.cursorLocation = { inside }
        controller.pointerMoved(at: inside, fromMonitor: true)

        let outside = CGPoint(x: frame.minX - 500, y: frame.minY - 500)
        controller.cursorLocation = { outside }
        controller.pointerMoved(at: outside, fromMonitor: true)
        pump(0.15)

        XCTAssertFalse(controller.model.isExpanded, "leaving the pill should have cancelled the dwell")
    }

    func testPointerDownOnThePillOpensAtOnceRegardlessOfTheDwell() {
        let controller = NotchWindowController()
        controller.show()
        defer { controller.stop() }
        controller.dwell = 5   // long enough that only the click, not the dwell, could open it
        guard let frame = controller.panelFrameForTesting else {
            XCTFail("no panel frame to build a screen point from")
            return
        }
        let point = screenPoint(
            local: CGPoint(x: controller.pillRect.midX, y: controller.pillRect.midY),
            frame: frame
        )
        controller.pointerDown(at: point)

        XCTAssertTrue(controller.model.isExpanded, "a click on the pill should open it without waiting on the dwell")
    }

    /// S018: on hover is folded until the pointer actually reaches the
    /// pill, driven through `apply(_:)` rather than a bare property set,
    /// since that is the entry point Settings itself uses.
    func testOnHoverDefaultAppliedThroughApplyStaysFoldedUntilThePointerReachesThePill() {
        let controller = NotchWindowController()
        controller.show()
        defer { controller.stop() }
        controller.apply(.onHover)
        guard let frame = controller.panelFrameForTesting else {
            XCTFail("no panel frame to build a screen point from")
            return
        }

        let outside = CGPoint(x: frame.minX - 500, y: frame.minY - 500)
        controller.cursorLocation = { outside }
        controller.pointerMoved(at: outside, fromMonitor: true)
        XCTAssertFalse(controller.model.isExpanded, "on hover, a point outside every rect should leave it folded")

        controller.dwell = 0.02
        let point = screenPoint(local: CGPoint(x: controller.pillRect.midX, y: controller.pillRect.midY), frame: frame)
        controller.cursorLocation = { point }
        controller.pointerMoved(at: point, fromMonitor: true)
        pump(0.05)
        XCTAssertTrue(controller.model.isExpanded, "on hover, dwelling on the pill should open it")
    }

    /// S010/S005: the 0.2s default is asserted directly (every other dwell
    /// test overrides it for speed, so nothing else pins the constant
    /// itself), then latency is timed wall-clock, in this test process,
    /// from the first `pointerMoved` to `onActivate` firing for a real
    /// click on a cell. `pointerDown` opens rather than activates while
    /// still folded (see `handleClick`'s own comment), so the poll below
    /// waits for the dwell to actually land before clicking.
    func testOpenLatencyFromPointerReachingThePillToFirstCellClickableIsUnderTheBudget() {
        let controller = NotchWindowController()
        controller.show()
        defer { controller.stop() }
        XCTAssertEqual(controller.dwell, 0.2, "the shipped dwell default should be about 0.2s")
        controller.model.cells = Fixtures.cells(3)
        controller.relocate(cellCount: 3)
        guard let frame = controller.panelFrameForTesting else {
            XCTFail("no panel frame to build a screen point from")
            return
        }
        let point = screenPoint(local: CGPoint(x: controller.pillRect.midX, y: controller.pillRect.midY), frame: frame)
        controller.cursorLocation = { point }

        let start = Date()
        controller.pointerMoved(at: point, fromMonitor: true)
        let budget: TimeInterval = 0.35
        while !controller.model.isExpanded, Date().timeIntervalSince(start) < budget {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(controller.model.isExpanded, "the notch never opened within the 0.35s budget")

        var activated: DrawerCell?
        controller.onActivate = { activated = $0 }
        controller.pointerDown(at: cellScreenPoint(controller, index: 0, frame: frame))
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertNotNil(activated, "the first cell should have been clickable once the notch opened")
        XCTAssertLessThanOrEqual(elapsed, budget, "open-to-clickable latency (wall clock in this test process) exceeded 0.35s")
    }

    /// A cell click folds the notch through `foldForAction`, not through
    /// hover leaving. The pointer is usually still sitting right where it
    /// was, and that must not reopen the notch out from under the click.
    func testAfterFoldForActionHoverCannotReopenUntilThePointerHasLeftAndAClickStillOpens() {
        let controller = NotchWindowController()
        controller.show()
        defer { controller.stop() }
        controller.dwell = 0.02
        guard let frame = controller.panelFrameForTesting else {
            XCTFail("no panel frame to build a screen point from")
            return
        }
        let inside = screenPoint(
            local: CGPoint(x: controller.pillRect.midX, y: controller.pillRect.midY),
            frame: frame
        )
        controller.cursorLocation = { inside }
        controller.pointerMoved(at: inside, fromMonitor: true)
        pump(0.05)
        XCTAssertTrue(controller.model.isExpanded, "setup: it should be open before folding for an action")

        controller.foldForAction()
        XCTAssertFalse(controller.model.isExpanded)

        controller.pointerMoved(at: inside, fromMonitor: true)   // still parked on the pill
        pump(0.05)
        XCTAssertFalse(controller.model.isExpanded, "hover reopened the notch right after the action folded it")

        controller.pointerDown(at: inside)
        XCTAssertTrue(controller.model.isExpanded, "a click should still open it while hover cannot")

        controller.foldForAction()
        let outside = CGPoint(x: frame.minX - 500, y: frame.minY - 500)
        controller.cursorLocation = { outside }
        controller.pointerMoved(at: outside, fromMonitor: true)
        controller.cursorLocation = { inside }
        controller.pointerMoved(at: inside, fromMonitor: true)
        pump(0.05)
        XCTAssertTrue(controller.model.isExpanded, "hover should reopen it once the pointer had left the pill")
    }

    func testFoldForActionUnderAlwaysShowDoesNotFold() {
        let controller = NotchWindowController()
        controller.apply(.alwaysShow)
        XCTAssertTrue(controller.model.isExpanded)

        controller.foldForAction()

        XCTAssertTrue(controller.model.isExpanded, "Always show should not be undone by an action folding")
    }

    /// `unfold`'s spring leaves the shape visibly open well after
    /// `isExpanded` has already flipped to false. If the hit regions
    /// collapsed to the pill on that same instant, a click aimed at a cell
    /// that is still on screen would land on nothing.
    func testInteractiveRectsStayOpenUntilTheFoldSpringActuallyFinishes() {
        let controller = NotchWindowController()
        controller.show()
        defer { controller.stop() }
        controller.dwell = 0.02
        guard let frame = controller.panelFrameForTesting else {
            XCTFail("no panel frame to build a screen point from")
            return
        }
        let inside = screenPoint(
            local: CGPoint(x: controller.pillRect.midX, y: controller.pillRect.midY),
            frame: frame
        )
        controller.cursorLocation = { inside }
        controller.pointerMoved(at: inside, fromMonitor: true)
        pump(0.05)
        XCTAssertTrue(controller.model.isExpanded, "setup: it should be open before folding")
        let openRect = controller.notchRect

        controller.foldForAction()

        XCTAssertFalse(controller.model.isExpanded, "the model flips at once")
        XCTAssertTrue(
            controller.interactiveRectsForTesting.contains(openRect),
            "the hit region should still be the open one immediately after the fold begins, not the pill"
        )

        // And it has to let go again once the spring is actually done, or a
        // click anywhere the open shape used to be would keep landing on the
        // panel forever instead of whatever app is really behind it there.
        pump(0.8)   // past unfold's completion on a 0.42 response spring
        XCTAssertFalse(
            controller.interactiveRectsForTesting.contains(openRect),
            "the open rect should be gone once the fold has actually finished"
        )
        XCTAssertTrue(controller.interactiveRectsForTesting.contains(controller.pillRect))
    }

    private func cellScreenPoint(_ controller: NotchWindowController, index: Int, frame: CGRect) -> CGPoint {
        let place = NotchPlacement(edge: controller.model.edge, panelSize: frame.size)
        let local = place.point(along: controller.model.slack + controller.model.ringCenter(index: index),
                                 across: controller.model.notchDepth / 2)
        return screenPoint(local: local, frame: frame)
    }

    func testPointerDownOnAPendingCellDoesNotActivate() {
        let controller = NotchWindowController()
        controller.show()
        defer { controller.stop() }
        var activated: DrawerCell?
        controller.onActivate = { activated = $0 }

        controller.model.cells = [
            DrawerCell(id: "fixture-pending", title: "Pending", icon: .symbol("wifi"), kind: .toggle, state: .pending),
        ]
        controller.model.isExpanded = true
        controller.relocate(cellCount: 1)
        guard let frame = controller.panelFrameForTesting else {
            XCTFail("no panel frame to build a screen point from")
            return
        }

        controller.pointerDown(at: cellScreenPoint(controller, index: 0, frame: frame))

        XCTAssertNil(activated, "a pending cell should ignore the click")
    }

    func testPointerDownOnALevelCellDoesNotActivate() {
        let controller = NotchWindowController()
        controller.show()
        defer { controller.stop() }
        var activated: DrawerCell?
        controller.onActivate = { activated = $0 }

        controller.model.cells = [
            DrawerCell(id: "fixture-level", title: "Volume", icon: .symbol("speaker.wave.2.fill"), kind: .level, state: .level(0.5)),
        ]
        controller.model.isExpanded = true
        controller.relocate(cellCount: 1)
        guard let frame = controller.panelFrameForTesting else {
            XCTFail("no panel frame to build a screen point from")
            return
        }

        controller.pointerDown(at: cellScreenPoint(controller, index: 0, frame: frame))

        XCTAssertNil(activated, "a level cell's click should be left to the slider")
    }

    // MARK: - Slider drag

    private func levelController(value: Double = 0.5) -> NotchWindowController {
        let controller = NotchWindowController()
        controller.show()
        controller.model.cells = [
            DrawerCell(id: "fixture-level", title: "Volume", icon: .symbol("speaker.wave.2.fill"),
                      kind: .level, state: .level(value)),
        ]
        controller.model.isExpanded = true
        controller.relocate(cellCount: 1)
        controller.model.hoveredIndex = 0
        return controller
    }

    func testLevelInteractionEndsOnceUsingTheOriginalCell() {
        let controller = levelController()
        defer { controller.stop() }
        let frame = controller.panelFrameForTesting!
        let band = controller.sliderBand(for: 0)!
        let point = screenPoint(local: CGPoint(x: band.midX, y: band.midY), frame: frame)
        var events: [String] = []
        controller.onBeginLevelInteraction = { events.append("begin:" + $0.id) }
        controller.onEndLevelInteraction = { events.append("end:" + $0.id) }
        controller.pointerDown(at: point)
        controller.model.hoveredIndex = nil
        controller.pointerUp(at: point)
        controller.stop()
        XCTAssertEqual(events, ["begin:fixture-level", "end:fixture-level"])
    }

    func testWheelDoesNotMoveTheSourceDuringLevelDrag() {
        let controller = levelController()
        defer { controller.stop() }
        let frame = controller.panelFrameForTesting!
        let band = controller.sliderBand(for: 0)!
        controller.pointerDown(at: screenPoint(local: CGPoint(x: band.midX, y: band.midY), frame: frame))
        controller.wheel(deltaAlong: 1000, precise: true, momentum: false)
        XCTAssertEqual(controller.model.firstVisibleIndex, 0)
        XCTAssertTrue(controller.isDragging)
    }

    func testRemovedSourceStopsWritesBeforeNextDragEvent() {
        let controller = levelController()
        defer { controller.stop() }
        let frame = controller.panelFrameForTesting!
        let band = controller.sliderBand(for: 0)!
        let point = screenPoint(local: CGPoint(x: band.midX, y: band.midY), frame: frame)
        controller.pointerDown(at: point)
        var writes = 0
        var ends = 0
        controller.onSetLevel = { _, _ in writes += 1 }
        controller.onEndLevelInteraction = { _ in ends += 1 }
        controller.model.cells = []
        controller.pointerDragged(at: point)
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(ends, 1)
        XCTAssertFalse(controller.isDragging)
    }

    func testHidingDrawerEndsLevelInteraction() {
        let controller = levelController()
        defer { controller.stop() }
        let frame = controller.panelFrameForTesting!
        let band = controller.sliderBand(for: 0)!
        var ended = 0
        controller.onEndLevelInteraction = { _ in ended += 1 }
        controller.pointerDown(at: screenPoint(local: CGPoint(x: band.midX, y: band.midY), frame: frame))
        controller.apply(.hidden)
        XCTAssertFalse(controller.isDragging)
        XCTAssertEqual(ended, 1)
    }

    func testPresentedCardIsSharedByHitTestingAndSliderCapture() {
        let controller = levelController()
        defer { controller.stop() }
        let target = controller.model.targetCardPlacement(index: 0)!
        let shown = NotchViewModel.CardPlacement(body: target.body.offsetBy(dx: 0, dy: 20),
                                                bridge: target.bridge.offsetBy(dx: 0, dy: 20),
                                                pointerOffset: target.pointerOffset)
        controller.model.presentedCardPlacement = shown
        XCTAssertEqual(controller.tooltipRect(index: 0), shown.body)
        let band = controller.sliderBand(for: 0)!
        let frame = controller.panelFrameForTesting!
        controller.pointerDown(at: screenPoint(local: CGPoint(x: band.midX, y: band.midY), frame: frame))
        XCTAssertTrue(controller.isDragging)
        XCTAssertEqual(controller.model.cardPlacement(index: 0), shown)
        controller.pointerUp(at: screenPoint(local: CGPoint(x: band.midX, y: band.midY), frame: frame))
        XCTAssertNil(controller.model.presentedCardPlacement)
    }

    func testPointerDownInsideTheLevelBandStartsADragAndSetsAValue() {
        let controller = levelController()
        defer { controller.stop() }
        guard let frame = controller.panelFrameForTesting, let band = controller.sliderBand(for: 0) else {
            XCTFail("no slider band")
            return
        }
        var reported: (DrawerCell, Double)?
        controller.onSetLevel = { reported = ($0, $1) }

        let point = screenPoint(local: CGPoint(x: band.midX, y: band.midY), frame: frame)
        controller.pointerDown(at: point)

        XCTAssertTrue(controller.isDragging, "a click inside the band should start a drag")
        guard let reported else {
            XCTFail("onSetLevel was never called")
            return
        }
        XCTAssertGreaterThanOrEqual(reported.1, 0)
        XCTAssertLessThanOrEqual(reported.1, 1)
    }

    func testPointerDraggedReportsTheValueAtTheNewPosition() {
        let controller = levelController()
        defer { controller.stop() }
        guard let frame = controller.panelFrameForTesting, let band = controller.sliderBand(for: 0) else {
            XCTFail("no slider band")
            return
        }
        // A point just inside each edge, not the edge itself: the round trip
        // through a screen point and back can land an epsilon outside a
        // boundary that was exact only on paper.
        let start = screenPoint(local: CGPoint(x: band.minX + 2, y: band.midY), frame: frame)
        controller.pointerDown(at: start)

        var values: [Double] = []
        controller.onSetLevel = { values.append($1) }
        let end = screenPoint(local: CGPoint(x: band.maxX - 2, y: band.midY), frame: frame)
        controller.pointerDragged(at: end)

        guard let last = values.last else {
            XCTFail("onSetLevel was never called from the drag")
            return
        }
        XCTAssertGreaterThan(last, 0.9, "the far end of the band should read close to 1")
    }

    func testIsDraggingStaysTrueWhenThePointerLeavesTheCard() {
        let controller = levelController()
        defer { controller.stop() }
        guard let frame = controller.panelFrameForTesting, let band = controller.sliderBand(for: 0) else {
            XCTFail("no slider band")
            return
        }
        controller.pointerDown(at: screenPoint(local: CGPoint(x: band.midX, y: band.midY), frame: frame))
        XCTAssertTrue(controller.isDragging)

        let outside = CGPoint(x: frame.minX - 500, y: frame.minY - 500)
        controller.pointerDragged(at: outside)

        XCTAssertTrue(controller.isDragging, "a drag should survive the pointer leaving the card")
    }

    func testADragNeverFoldsEvenPastTheFoldGrace() {
        let controller = levelController()
        defer { controller.stop() }
        guard let frame = controller.panelFrameForTesting, let band = controller.sliderBand(for: 0) else {
            XCTFail("no slider band")
            return
        }
        controller.pointerDown(at: screenPoint(local: CGPoint(x: band.midX, y: band.midY), frame: frame))

        let outside = CGPoint(x: frame.minX - 500, y: frame.minY - 500)
        controller.pointerDragged(at: outside)
        pump(0.6)   // past foldGrace's 0.45s

        XCTAssertTrue(controller.model.isExpanded, "a live drag should never let the notch fold")
        XCTAssertTrue(controller.isDragging)
    }

    func testPointerUpEndsTheDragAndTheGraceFoldThenApplies() {
        let controller = levelController()
        defer { controller.stop() }
        guard let frame = controller.panelFrameForTesting, let band = controller.sliderBand(for: 0) else {
            XCTFail("no slider band")
            return
        }
        controller.pointerDown(at: screenPoint(local: CGPoint(x: band.midX, y: band.midY), frame: frame))
        XCTAssertTrue(controller.isDragging)

        let outside = CGPoint(x: frame.minX - 500, y: frame.minY - 500)
        controller.cursorLocation = { outside }
        controller.pointerUp(at: outside)
        XCTAssertFalse(controller.isDragging, "pointerUp should end the drag")

        pump(0.6)   // past foldGrace
        XCTAssertFalse(controller.model.isExpanded, "the ordinary grace fold should apply once the drag ends")
    }

    func testTheWatchdogEndsAStalledDragAfterOneSecond() {
        let controller = levelController()
        controller.pressedMouseButtons = { 0 }
        defer { controller.stop() }
        guard let frame = controller.panelFrameForTesting, let band = controller.sliderBand(for: 0) else {
            XCTFail("no slider band")
            return
        }
        let point = screenPoint(local: CGPoint(x: band.midX, y: band.midY), frame: frame)
        controller.cursorLocation = { point }
        controller.pointerDown(at: point)
        XCTAssertTrue(controller.isDragging)

        pump(1.2)   // past the watchdog's 1s

        XCTAssertFalse(controller.isDragging, "a drag that stopped receiving events should end on its own")
    }

    func testWatchdogKeepsStationaryHeldDragAndEndsAfterRelease() {
        let controller = levelController()
        defer { controller.stop() }
        var buttons = 1
        controller.pressedMouseButtons = { buttons }
        var endings = 0
        controller.onEndLevelInteraction = { _ in endings += 1 }
        guard let frame = controller.panelFrameForTesting, let band = controller.sliderBand(for: 0) else {
            XCTFail("no slider band")
            return
        }
        let point = screenPoint(local: CGPoint(x: band.midX, y: band.midY), frame: frame)
        controller.cursorLocation = { point }
        controller.pointerDown(at: point)
        pump(1.2)
        XCTAssertTrue(controller.isDragging)
        XCTAssertEqual(endings, 0)
        buttons = 0
        pump(1.2)
        XCTAssertFalse(controller.isDragging)
        XCTAssertEqual(endings, 1)
        controller.pointerUp(at: point)
        XCTAssertEqual(endings, 1)
    }

    func testPointerDownOutsideTheBandOnALevelCellStillDoesNothing() {
        let controller = levelController()
        defer { controller.stop() }
        guard let frame = controller.panelFrameForTesting else {
            XCTFail("no panel frame")
            return
        }
        var activated: DrawerCell?
        controller.onActivate = { activated = $0 }
        var setLevelCalled = false
        controller.onSetLevel = { _, _ in setLevelCalled = true }

        controller.pointerDown(at: cellScreenPoint(controller, index: 0, frame: frame))

        XCTAssertFalse(controller.isDragging, "the ring, not the band, was clicked")
        XCTAssertFalse(setLevelCalled)
        XCTAssertNil(activated)
    }

    func testTooltipHasGapAndContainsSliderBand() {
        let controller = levelController()
        defer { controller.stop() }
        guard let card = controller.tooltipRect(index: 0), let band = controller.sliderBand(for: 0) else {
            return XCTFail("no card or slider band")
        }
        XCTAssertEqual(controller.notchRect.minX - card.maxX, NotchLayout.cardGap, accuracy: 0.01)
        XCTAssertGreaterThan(NotchLayout.cardGap, NotchLayout.pointerDepth)
        XCTAssertTrue(card.contains(band))
    }

    func testBridgeRetainsHoverWithoutActionOrSliderCapture() {
        let controller = levelController()
        defer { controller.stop() }
        controller.model.hoveredIndex = 0
        guard let frame = controller.panelFrameForTesting,
              let placement = controller.model.cardPlacement(index: 0, panelSize: frame.size) else {
            return XCTFail("missing placement")
        }
        let point = screenPoint(local: CGPoint(x: placement.bridge.midX, y: placement.bridge.midY), frame: frame)
        controller.cursorLocation = { point }
        var activated = false
        controller.onActivate = { _ in activated = true }
        controller.pointerMoved(at: point)
        controller.pointerDown(at: point)
        XCTAssertEqual(controller.model.hoveredIndex, 0)
        XCTAssertTrue(controller.model.isExpanded)
        XCTAssertFalse(controller.model.isPinned)
        XCTAssertFalse(controller.isDragging)
        XCTAssertFalse(activated)
    }

    // MARK: - Demo hover

    func testHoldHoverKeepsHoveredIndexAcrossPollTicks() {
        let controller = NotchWindowController()
        controller.show()
        defer { controller.stop() }
        controller.model.cells = Fixtures.cells(3)
        controller.relocate(cellCount: 3)
        controller.model.isExpanded = true
        controller.model.isAlwaysOn = true   // holds it open regardless of the fold grace
        controller.model.hoveredIndex = 1
        controller.holdHover = true

        guard let frame = controller.panelFrameForTesting else {
            XCTFail("no panel frame")
            return
        }
        let outside = CGPoint(x: frame.minX - 500, y: frame.minY - 500)
        controller.cursorLocation = { outside }
        controller.pointerMoved(at: outside, fromMonitor: false)   // stands in for the poll

        XCTAssertEqual(controller.model.hoveredIndex, 1, "holdHover should keep the poll from clearing it")
    }

    /// Hovering ring 2 then gliding to ring 3 should move `hoveredIndex`
    /// straight across, once, with the card landing exactly where
    /// `NotchRootView.tooltipCentre` positions it for the new index. The
    /// glide is several intermediate `pointerMoved` calls along the path
    /// between the two rings, not one jump straight from ring 2 to ring 3:
    /// a single jump would make "changes exactly once" trivially true
    /// without checking for flicker along the way. What this cannot pin is
    /// the frame-by-frame look of the animated glide itself; that stays a
    /// hands-on check (S121's notes).
    func testHoverGlideFromRingTwoToRingThreeMovesTheHighlightOnceAndPositionsTheCard() {
        let controller = NotchWindowController()
        controller.show()
        defer { controller.stop() }
        controller.model.cells = Fixtures.vocabulary()
        controller.relocate(cellCount: controller.model.cells.count)
        controller.model.isExpanded = true
        guard let frame = controller.panelFrameForTesting else {
            XCTFail("no panel frame to build a screen point from")
            return
        }

        let ring2 = cellScreenPoint(controller, index: 2, frame: frame)
        controller.pointerMoved(at: ring2, fromMonitor: true)
        XCTAssertEqual(controller.model.hoveredIndex, 2, "setup: should be hovering ring 2 before the glide")

        var changes: [Int?] = []
        let cancellable = controller.model.$hoveredIndex.dropFirst().sink { changes.append($0) }
        defer { cancellable.cancel() }

        let ring3 = cellScreenPoint(controller, index: 3, frame: frame)
        for step in 1...4 {
            let t = CGFloat(step) / 4
            let point = CGPoint(x: ring2.x + (ring3.x - ring2.x) * t, y: ring2.y + (ring3.y - ring2.y) * t)
            controller.pointerMoved(at: point, fromMonitor: true)
        }

        XCTAssertEqual(controller.model.hoveredIndex, 3, "gliding to ring 3 should move the highlight there")
        XCTAssertEqual(changes, [3], "the glide from ring 2 to ring 3 should move hoveredIndex exactly once, straight to 3, with no flicker through nil or another cell along the way")

        controller.cursorLocation = { ring3 }
        pump(0.2)
        guard let slot = controller.model.geometricIndex(of: 3), let card = controller.tooltipRect(index: 3) else {
            XCTFail("no card for ring 3")
            return
        }
        let place = NotchPlacement(edge: controller.model.edge, panelSize: frame.size)
        let cell = controller.model.cells[3]
        // The same `card` NotchRootView.tooltipCentre positions the card
        // with: the width, not the height, since across is how far the card
        // reaches from the bar into the screen.
        let cardAcross = NotchLayout.cardWidth
        let expectedCentre = place.point(
            along: controller.model.slack + controller.model.ringCenter(visible: slot),
            across: controller.model.tooltipInset + cardAcross / 2
        )
        XCTAssertEqual(card.midX, expectedCentre.x, accuracy: 0.01, "the card should be centred where NotchRootView positions it for ring 3")
        XCTAssertEqual(card.midY, expectedCentre.y, accuracy: 0.01, "the card should be centred where NotchRootView positions it for ring 3")
    }

    // MARK: - Chord

    func testChordOpensPinnedExpandedAndKeyed() {
        let controller = NotchWindowController()
        controller.show()
        defer { controller.stop() }

        controller.toggleFromHotKey()

        XCTAssertTrue(controller.model.isPinned)
        XCTAssertTrue(controller.model.isExpanded)
        XCTAssertEqual(controller.model.hoverSource, .keyboard)
        XCTAssertTrue(controller.panelAcceptsKeyForTesting)
    }

    func testEscapeClosesTheChord() {
        let controller = NotchWindowController()
        controller.show()
        defer { controller.stop() }
        controller.toggleFromHotKey()

        controller.key(.escape)

        XCTAssertFalse(controller.model.isExpanded)
        XCTAssertFalse(controller.model.isPinned)
        XCTAssertFalse(controller.panelAcceptsKeyForTesting)
    }

    func testResignKeyWhileOpenByChordClosesIt() {
        let controller = NotchWindowController()
        controller.show()
        defer { controller.stop() }
        controller.toggleFromHotKey()
        XCTAssertTrue(controller.model.isExpanded)

        controller.simulateResignKeyForTesting()

        XCTAssertFalse(controller.model.isExpanded)
        XCTAssertFalse(controller.model.isPinned)
        XCTAssertFalse(controller.panelAcceptsKeyForTesting)
    }

    func testResignKeyWhileNotOpenByChordDoesNothing() {
        let controller = NotchWindowController()
        controller.show()
        defer { controller.stop() }
        controller.togglePinned()   // pinned by an ordinary click, not the chord
        XCTAssertTrue(controller.model.isExpanded)

        controller.simulateResignKeyForTesting()

        XCTAssertTrue(controller.model.isExpanded, "resigning key should only close a chord-opened drawer")
    }

    func testASecondChordCloses() {
        let controller = NotchWindowController()
        controller.show()
        defer { controller.stop() }
        controller.toggleFromHotKey()
        XCTAssertTrue(controller.model.isExpanded)

        controller.toggleFromHotKey()

        XCTAssertFalse(controller.model.isExpanded)
        XCTAssertFalse(controller.panelAcceptsKeyForTesting)
    }

    func testChordShowsAHiddenPanelAndClosingReHidesIt() {
        let controller = NotchWindowController()
        controller.show()
        defer { controller.stop() }
        controller.apply(.hidden)
        XCTAssertFalse(controller.panelIsVisibleForTesting, "setup: hidden should have ordered the panel out")

        controller.toggleFromHotKey()
        XCTAssertTrue(controller.panelIsVisibleForTesting, "the chord should reveal a hidden panel")

        controller.closeChord()
        XCTAssertFalse(controller.panelIsVisibleForTesting, "closing should re-hide it")
    }

    func testAlwaysShowSurvivesTheChord() {
        let controller = NotchWindowController()
        controller.show()
        defer { controller.stop() }
        controller.apply(.alwaysShow)
        XCTAssertTrue(controller.model.isExpanded)

        controller.toggleFromHotKey()
        controller.closeChord()

        XCTAssertTrue(controller.model.isExpanded, "Always show should survive a chord opening and closing")
    }

    /// S087: `NotchPanel.performKeyEquivalent` is what swallows Cmd-Q; it
    /// answers `true` for any Command chord while `acceptsKey` holds,
    /// which stops AppKit from ever routing the event on to the app's own
    /// Quit menu item. Reaching the panel window through
    /// `panelContentViewForTesting?.window` avoids needing a testing hook
    /// of its own for the concrete `NotchPanel` type.
    func testCmdQIsSwallowedWhileOpenByChordAndTheControllerKeepsRunning() throws {
        let controller = NotchWindowController()
        controller.show()
        defer { controller.stop() }
        controller.toggleFromHotKey()
        XCTAssertTrue(controller.panelAcceptsKeyForTesting, "setup: the chord should make the panel accept key events")
        let panel = try XCTUnwrap(controller.panelContentViewForTesting?.window, "no panel window to test performKeyEquivalent on")
        let commandQ = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: "q", charactersIgnoringModifiers: "q",
            isARepeat: false, keyCode: 12
        ), "could not build a synthetic Command-Q event")

        XCTAssertTrue(panel.performKeyEquivalent(with: commandQ), "Command-Q should be swallowed while the chord holds the key")

        XCTAssertTrue(controller.model.isExpanded, "the controller should still be running, drawer intact, after swallowing Cmd-Q")
        XCTAssertTrue(controller.panelAcceptsKeyForTesting, "the panel should still hold the key after swallowing Cmd-Q")
    }

    /// S327: the controller has no notion of `Preferences.appPresence` at
    /// all (confirmed: nothing in this file references it), which is
    /// exactly why the chord and the settings handle keep working with no
    /// Dock or menu bar icon; setting it here is scene-setting, not
    /// something the assertions below depend on. The handle point mirrors
    /// `NotchWindowController.handleRect`'s own private computation, the
    /// same way `cellScreenPoint` mirrors its ring-centre math.
    func testAppPresenceNeitherStillReachableByTheChordAndTheSettingsHandle() throws {
        let suite = "com.advegaf.drawer.tests.controller.s327.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        preferences.appPresence = .hidden   // AppPresence.hidden is titled "Neither" in Settings

        let controller = NotchWindowController()
        controller.show()
        defer { controller.stop() }
        controller.model.cells = Fixtures.cells(3)
        controller.relocate(cellCount: 3)

        controller.toggleFromHotKey()
        XCTAssertTrue(controller.model.isExpanded, "the chord should still open the drawer with no Dock or menu bar icon")

        var opened = 0
        controller.onOpenSettings = { opened += 1 }
        let frame = try XCTUnwrap(controller.panelFrameForTesting, "no panel frame to build a screen point from")
        let handle = try XCTUnwrap(controller.model.orbHandlePoints.first, "no orb handle point")
        let place = NotchPlacement(edge: controller.model.edge, panelSize: frame.size)
        let local = place.point(along: controller.model.slack + handle.x, across: handle.y)
        controller.pointerDown(at: screenPoint(local: local, frame: frame))

        XCTAssertEqual(opened, 1, "the settings handle should still open Settings with no Dock or menu bar icon")
    }

    func testFoldForActionWhileOpenByChordHandsBackTheChord() {
        let controller = NotchWindowController()
        controller.show()
        defer { controller.stop() }
        controller.toggleFromHotKey()
        XCTAssertTrue(controller.panelAcceptsKeyForTesting)

        controller.foldForAction()

        XCTAssertFalse(controller.panelAcceptsKeyForTesting)
        XCTAssertFalse(controller.model.isPinned)
        XCTAssertFalse(controller.model.isExpanded)
    }

    func testKeyboardHoverSurvivesAPollTick() {
        let controller = NotchWindowController()
        controller.show()
        defer { controller.stop() }
        controller.model.cells = Fixtures.cells(3)
        controller.relocate(cellCount: 3)
        controller.model.isExpanded = true
        controller.model.hoverSource = .keyboard
        controller.model.hoveredIndex = 1

        guard let frame = controller.panelFrameForTesting else {
            XCTFail("no panel frame")
            return
        }
        let outside = CGPoint(x: frame.minX - 500, y: frame.minY - 500)
        controller.cursorLocation = { outside }
        controller.pointerMoved(at: outside, fromMonitor: false)   // stands in for the poll

        XCTAssertEqual(controller.model.hoveredIndex, 1, "a poll tick should not touch a keyboard-sourced hover")
        XCTAssertTrue(controller.model.isExpanded, "a poll tick should not fold a keyboard-sourced hover either")
    }

    func testAMonitorMoveReturnsHoverToPointer() {
        let controller = NotchWindowController()
        controller.show()
        defer { controller.stop() }
        controller.model.hoverSource = .keyboard

        controller.pointerMoved(at: controller.cursorLocation(), fromMonitor: true)

        XCTAssertEqual(controller.model.hoverSource, .pointer)
    }

    /// A controller with cells and a screen size but no real panel: the
    /// keyboard-navigation paths read only `model`, so there is nothing here
    /// for AppKit geometry to get in the way of, and a fixed screen size keeps
    /// the fit deterministic regardless of the machine running the test.
    private func keyboardController(cellCount: Int = 17, height: CGFloat = 982) -> NotchWindowController {
        let controller = NotchWindowController()
        controller.model.edge = .right
        controller.model.screenSize = CGSize(width: 1800, height: height)
        controller.model.screenUsableSize = CGSize(width: 1800, height: height - 37)
        controller.model.cells = Fixtures.cells(cellCount)
        controller.model.isExpanded = true
        return controller
    }

    func testDownFromNilSelectsTheFirstVisibleCell() {
        let controller = keyboardController()

        controller.key(.down)

        XCTAssertEqual(controller.model.hoveredIndex, controller.model.firstVisibleIndex)
        XCTAssertEqual(controller.model.hoverSource, .keyboard)
    }

    func testUpFromNilSelectsTheLastVisibleCell() {
        let controller = keyboardController()

        controller.key(.up)

        let lastVisible = controller.model.firstVisibleIndex + controller.model.visibleCount - 1
        XCTAssertEqual(controller.model.hoveredIndex, lastVisible)
    }

    func testMovingPastTheVisibleSliceScrollsFirstVisibleIndex() {
        let controller = keyboardController()
        let visible = controller.model.visibleCount
        XCTAssertLessThan(visible, controller.model.cells.count, "setup: needs room to scroll")

        for _ in 0..<visible { controller.key(.down) }
        XCTAssertEqual(controller.model.hoveredIndex, visible - 1, "setup: should be sitting on the last visible cell")
        XCTAssertEqual(controller.model.firstVisibleIndex, 0, "setup: should not have scrolled yet")

        controller.key(.down)   // one more, past the visible slice

        XCTAssertEqual(controller.model.firstVisibleIndex, 1, "moving past the slice should scroll by one")
        XCTAssertEqual(controller.model.hoveredIndex, visible)
    }

    func testReturnActivatesAToggleCellButNotLevelOrPending() {
        let controller = keyboardController(cellCount: 3)
        controller.model.cells = [
            DrawerCell(id: "fixture-toggle", title: "Wifi", icon: .symbol("wifi"), kind: .toggle, state: .on),
            DrawerCell(id: "fixture-level", title: "Volume", icon: .symbol("speaker.wave.2.fill"), kind: .level, state: .level(0.5)),
            DrawerCell(id: "fixture-pending", title: "Pending", icon: .symbol("wifi"), kind: .toggle, state: .pending),
        ]
        var activated: [DrawerCell] = []
        controller.onActivate = { activated.append($0) }

        controller.model.hoveredIndex = 0
        controller.key(.return)
        XCTAssertEqual(activated.count, 1)

        controller.model.hoveredIndex = 1
        controller.key(.return)
        XCTAssertEqual(activated.count, 1, "a level cell's Return should be ignored, the same as its click")

        controller.model.hoveredIndex = 2
        controller.key(.return)
        XCTAssertEqual(activated.count, 1, "a pending cell's Return should be ignored, the same as its click")
    }

    // MARK: - outsideClick

    func testOutsideClickUnpinsButNeverTouchesAlwaysShow() {
        let controller = NotchWindowController()
        controller.show()
        defer { controller.stop() }
        guard let frame = controller.panelFrameForTesting else {
            XCTFail("no panel frame")
            return
        }
        controller.togglePinned()
        XCTAssertTrue(controller.model.isPinned)

        let outside = CGPoint(x: frame.minX - 500, y: frame.minY - 500)
        controller.outsideClick(at: outside)
        XCTAssertFalse(controller.model.isPinned, "a click outside the bar should unpin")

        controller.apply(.alwaysShow)
        controller.outsideClick(at: outside)
        XCTAssertTrue(controller.model.isAlwaysOn, "outsideClick must never touch Always show")
    }

    func testOutsideClickOnTheBarDoesNotUnpin() {
        let controller = NotchWindowController()
        controller.show()
        defer { controller.stop() }
        guard let frame = controller.panelFrameForTesting else {
            XCTFail("no panel frame")
            return
        }
        controller.togglePinned()

        let onBar = screenPoint(local: CGPoint(x: controller.notchRect.minX + 2, y: controller.notchRect.minY + 2), frame: frame)
        controller.outsideClick(at: onBar)

        XCTAssertTrue(controller.model.isPinned, "a click on the bar itself should not unpin")
    }

    func testOutsideClickOnTheCardDoesNotUnpin() {
        let controller = NotchWindowController()
        controller.show()
        defer { controller.stop() }
        controller.model.cells = Fixtures.cells(3)
        controller.relocate(cellCount: 3)
        controller.model.isExpanded = true
        controller.model.hoveredIndex = 0
        controller.togglePinned()
        guard let frame = controller.panelFrameForTesting, let card = controller.tooltipRect(index: 0) else {
            XCTFail("no card rect")
            return
        }

        let onCard = screenPoint(local: CGPoint(x: card.midX, y: card.midY), frame: frame)
        controller.outsideClick(at: onCard)

        XCTAssertTrue(controller.model.isPinned, "a click on the tooltip card should not unpin")
    }

    // MARK: - First-launch reveal

    /// No `show()` here: `setExpanded`, `foldNow` and the rest of the fold
    /// path are all nil-safe against a missing panel, and without the cursor
    /// poll running, only `revealOnce`'s own 3s fallback can fold it back up.
    func testRevealOnceExpandsAfterSixTenthsOfASecondWithoutPinning() {
        let controller = NotchWindowController()
        XCTAssertFalse(controller.model.isExpanded)

        controller.revealOnce()
        pump(0.3)
        XCTAssertFalse(controller.model.isExpanded, "it opened before the 0.6s delay had elapsed")

        pump(0.5)
        XCTAssertTrue(controller.model.isExpanded, "it never opened at all")
        XCTAssertFalse(controller.model.isPinned, "a first-launch reveal is not a pin")
    }

    func testRevealOnceFoldsWithinThreeSecondsPlusGraceWithNobodyThere() {
        let controller = NotchWindowController()
        controller.revealOnce()
        pump(0.8)
        XCTAssertTrue(controller.model.isExpanded, "setup: it should be open before it can fold")

        pump(3.5)   // past the 3s fallback plus foldGrace's 0.45s, with margin
        XCTAssertFalse(controller.model.isExpanded, "it never folded on its own")
        XCTAssertFalse(controller.model.isPinned)
    }

    func testRevealOnceUnderAlwaysShowStaysOpen() {
        let controller = NotchWindowController()
        controller.apply(.alwaysShow)
        XCTAssertTrue(controller.model.isExpanded)

        controller.revealOnce()
        pump(4.5)

        XCTAssertTrue(controller.model.isExpanded, "Always show should survive the first-launch reveal folding")
    }

    func testHoverReArmsOnlyOnceThePointerLeavesTheWholeBar() {
        let controller = NotchWindowController()
        controller.show()
        defer { controller.stop() }
        controller.dwell = 0.02
        guard let frame = controller.panelFrameForTesting else { return XCTFail("no panel frame") }
        controller.foldForAction()

        let barMiddle = screenPoint(local: CGPoint(x: controller.notchRect.midX, y: controller.notchRect.midY), frame: frame)
        controller.cursorLocation = { barMiddle }
        controller.pointerMoved(at: barMiddle, fromMonitor: true)
        let pill = screenPoint(local: CGPoint(x: controller.pillRect.midX, y: controller.pillRect.midY), frame: frame)
        controller.cursorLocation = { pill }
        controller.pointerMoved(at: pill, fromMonitor: true)
        pump(0.05)
        XCTAssertFalse(controller.model.isExpanded, "a pointer that only crossed the bar area must not re-arm hover")

        let farAway = screenPoint(local: CGPoint(x: -300, y: -300), frame: frame)
        controller.cursorLocation = { farAway }
        controller.pointerMoved(at: farAway, fromMonitor: true)
        controller.cursorLocation = { pill }
        controller.pointerMoved(at: pill, fromMonitor: true)
        pump(0.05)
        XCTAssertTrue(controller.model.isExpanded, "once the pointer has left the bar, hover opens again")
    }

    /// Was also a `backdropContext` freeze test before phase 26 deleted that
    /// property with the sampler it fed; this residual half, that repeated
    /// edge requests during one transition settle on the last one asked for,
    /// still holds and is the only coverage `apply(edge:)` has.
    func testEdgeDepartureAppliesTheNewestSelectionOnly() {
        let controller = NotchWindowController()
        controller.show()
        defer { controller.stop() }
        controller.model.edge = .right
        controller.relocate()
        controller.apply(.alwaysShow)
        pump(0.3)
        controller.apply(edge: .left)
        controller.apply(edge: .right)
        controller.apply(edge: .left)
        pump(0.65)
        XCTAssertEqual(controller.model.edge, .left)
        XCTAssertTrue(controller.model.isExpanded)
    }

    func testClosedEdgeArrivalAppliesTheNewEdgeWithoutOpening() {
        let controller = NotchWindowController()
        controller.show()
        defer { controller.stop() }
        controller.cursorLocation = { CGPoint(x: -10000, y: -10000) }
        controller.model.isExpanded = false
        let next: NotchEdge = controller.model.edge == .left ? .right : .left
        controller.apply(edge: next)
        pump(0.4)
        XCTAssertEqual(controller.model.edge, next)
        XCTAssertFalse(controller.model.isExpanded)
    }

    func testAccessibilityActivationResolvesVisibleStableIdentityAndPreservesRecovery() {
        let controller = NotchWindowController()
        controller.show()
        defer { controller.stop() }
        let missing = DrawerCell(id: "missing", title: "Missing app", icon: .symbol("app"),
                                 kind: .launch, state: .notInstalled)
        let pending = DrawerCell(id: "pending", title: "Pending", icon: .symbol("circle"),
                                 kind: .toggle, state: .pending)
        controller.model.cells = [missing, pending]
        controller.model.isExpanded = true
        var activated: [String] = []
        controller.onActivate = { activated.append($0.id) }
        controller.activateAccessibilityCell(id: "missing")
        controller.activateAccessibilityCell(id: "pending")
        controller.activateAccessibilityCell(id: "removed")
        XCTAssertEqual(activated, ["missing"])
        controller.model.cells = [pending]
        controller.activateAccessibilityCell(id: "missing")
        controller.model.cells = [missing]
        controller.model.isExpanded = false
        controller.activateAccessibilityCell(id: "missing")
        XCTAssertEqual(activated, ["missing"])
    }

    func testAccessibilityActionsRejectScrolledAwayCellsAndHiddenSettings() {
        let controller = NotchWindowController()
        controller.show()
        defer { controller.stop() }
        controller.model.cells = Fixtures.cells(100)
        controller.model.isExpanded = true
        let first = controller.model.cells[0].id
        controller.model.firstVisibleIndex = 1
        var activations = 0
        controller.onActivate = { _ in activations += 1 }
        controller.activateAccessibilityCell(id: first)
        XCTAssertEqual(activations, 0)
        var opened = 0
        controller.onOpenSettings = { opened += 1 }
        controller.openAccessibilitySettings()
        controller.model.isExpanded = false
        controller.openAccessibilitySettings()
        XCTAssertEqual(opened, 1)
        controller.stop()
        controller.model.isExpanded = true
        controller.openAccessibilitySettings()
        XCTAssertEqual(opened, 1)
    }

    func testAccessibilityLevelAdjustmentClampsAndBracketsImmediateWrites() {
        let controller = NotchWindowController()
        controller.show()
        defer { controller.stop() }
        func level(_ value: Double) -> DrawerCell {
            DrawerCell(id: "level", title: "Brightness", icon: .symbol("sun.max"),
                       kind: .level, state: .level(value))
        }
        controller.model.cells = [level(0.98)]
        controller.model.isExpanded = true
        var events: [String] = []
        var values: [Double] = []
        controller.onBeginLevelInteraction = { events.append("begin:" + $0.id) }
        controller.onSetLevel = { cell, value in
            events.append("set:" + cell.id)
            values.append(value)
            controller.model.cells = [level(value)]
        }
        controller.onEndLevelInteraction = { events.append("end:" + $0.id) }
        controller.adjustAccessibilityLevel(id: "level", increment: true)
        XCTAssertEqual(values, [1])
        XCTAssertEqual(events, ["begin:level", "set:level", "end:level"])
        controller.adjustAccessibilityLevel(id: "level", increment: true)
        XCTAssertEqual(values.count, 1)
        controller.adjustAccessibilityLevel(id: "level", increment: false)
        XCTAssertEqual(values.last!, 0.95, accuracy: 0.00001)
        controller.model.cells = [level(0.02)]
        controller.adjustAccessibilityLevel(id: "level", increment: false)
        XCTAssertEqual(values.last, 0)
        controller.model.cells = [level(.nan)]
        controller.adjustAccessibilityLevel(id: "level", increment: true)
        XCTAssertEqual(values.count, 3)
        XCTAssertEqual(events.count, 9)
    }

    func testInvalidLevelLabelsRemainUnavailableWithoutNumericConversion() {
        for value in [Double.nan, .infinity, -.infinity] {
            XCTAssertEqual(CellState.level(value).label, "Unavailable")
        }
        XCTAssertEqual(CellState.level(Double.greatestFiniteMagnitude).label, "100%")
        XCTAssertEqual(CellState.level(-Double.greatestFiniteMagnitude).label, "0%")
        XCTAssertEqual(CellState.level(0.42).label, "42%")
    }

}
