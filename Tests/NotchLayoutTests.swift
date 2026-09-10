import XCTest
@testable import Drawer

/// The layout is a scaled set of design pixels. These pin the fixed ratios,
/// so a change to `Design.scale` resizes everything without silently
/// reshaping it.
final class NotchLayoutTests: XCTestCase {
    func testRingIsTheSpecAnchor() {
        XCTAssertEqual(NotchLayout.ringDiameter(), 44, accuracy: 0.001)
    }

    func testPitchIsRingPlusSpacing() {
        XCTAssertEqual(
            NotchLayout.cellPitch(for: .right),
            NotchLayout.ringDiameter() + NotchLayout.cellSpacing(), accuracy: 0.001
        )
        XCTAssertEqual(
            NotchLayout.cellPitch(for: .left),
            NotchLayout.ringDiameter() + NotchLayout.cellSpacing(), accuracy: 0.001
        )
    }

    func testShapeGrowsOneCellAtATime() {
        let cell = NotchLayout.cellExtent()
        let one = NotchLayout.shapeLength(cellCount: 1)
        let two = NotchLayout.shapeLength(cellCount: 2)
        XCTAssertEqual(two - one, cell + NotchLayout.cellSpacing(), accuracy: 0.001)
    }

    func testRingCentresAreEvenlySpacedInsideTheBody() {
        let first = NotchLayout.ringCenter(index: 0)
        XCTAssertEqual(
            first,
            NotchLayout.curlRadius + NotchLayout.padTop() + NotchLayout.ringDiameter() / 2,
            accuracy: 0.001
        )
        XCTAssertEqual(
            NotchLayout.ringCenter(index: 2) - NotchLayout.ringCenter(index: 1),
            NotchLayout.cellPitch(for: .right),
            accuracy: 0.001
        )
    }

}

/// The card's height is a fixed function of what kind of cell it belongs to and
/// what that cell is saying, not a measurement. So the hover region can be
/// worked out before anything is ever drawn.
final class CardHeightTests: XCTestCase {
    func testPlainLevelAndFailedHeightsAreDistinctAndOrdered() {
        let plain = NotchLayout.cardHeight(for: .toggle, state: .on)
        let level = NotchLayout.cardHeight(for: .level, state: .ready)
        let failed = NotchLayout.cardHeight(for: .toggle, state: .failed("went wrong"))
        XCTAssertLessThan(plain, failed)
        XCTAssertLessThan(plain, level)
    }

    /// A failed cell says why, and the why can wrap. The budget has to hold
    /// two lines of it whatever the message actually is.
    func testTheFailedHeightLeavesRoomForTwoBodyLines() {
        let plain = NotchLayout.cardHeight(for: .toggle, state: .on)
        let failed = NotchLayout.cardHeight(for: .toggle, state: .failed("went wrong"))
        XCTAssertEqual(
            failed - plain,
            NotchLayout.headerToBlock + 2 * NotchLayout.cardBodyLineHeight(),
            accuracy: 0.001
        )
    }

    /// A tooltip anchored to the first or last cell still has to fit the panel,
    /// so half the tallest card, plus its lobe fillet and shadow pad, has to
    /// clear the slack reserved for it.
    func testHalfTheTallestCardFitsInsideTheEndSlack() {
        XCTAssertLessThan(
            NotchLayout.maxCardHeight() / 2 + NotchLayout.cardShadowPad,
            NotchLayout.endSlack
        )
    }
}

/// The panel has to be sized for the cell list that caused the change, not
/// the one the model still holds.
///
/// `@Published` notifies subscribers in `willSet`, so a sink that reacts to
/// `cells` changing and then reads `model.cells` back sees the *previous*
/// array. That is how the panel ended up sized for zero cells while one was on
/// screen. A panel too short for its shape clips the bottom flare, which is
/// visible as the notch looking cut off instead of curving into the bezel.
@MainActor
final class PanelSizingTests: XCTestCase {
    func testPanelGrowsWithTheCellCount() {
        let model = NotchViewModel()
        let empty = model.panelSize(cellCount: 0).height
        let one = model.panelSize(cellCount: 1).height
        let two = model.panelSize(cellCount: 2).height
        XCTAssertGreaterThan(one, empty)
        XCTAssertGreaterThan(two, one)
    }

    /// Sizing must not depend on what `cells` happens to hold right now.
    func testSizingIgnoresTheModelsCurrentList() {
        let model = NotchViewModel()
        XCTAssertTrue(model.cells.isEmpty)
        XCTAssertEqual(
            model.panelSize(cellCount: 1).height,
            model.shapeLength(cellCount: 1) + 2 * NotchLayout.slack(for: .right),
            accuracy: 0.001
        )
    }

    /// Whatever the count, the panel always has room for the whole shape.
    /// Flares included. Or the ends get cut off.
    func testThePanelAlwaysFitsTheWholeShape() {
        let model = NotchViewModel()
        for count in 0...5 {
            let panel = model.panelSize(cellCount: count).height
            let shape = model.shapeLength(cellCount: count)
            XCTAssertGreaterThanOrEqual(panel, shape, "\(count) cells: panel \(panel) < shape \(shape)")
        }
    }
}

/// The notch folds away to a pill so it stops being in the way, and unfolds on
/// contact. These pin the geometry that makes that bearable to live with.
@MainActor
final class FoldedNotchTests: XCTestCase {
    private func model(cells: Int) -> NotchViewModel {
        let model = NotchViewModel()
        model.cells = Fixtures.cells(cells)
        return model
    }

    func testFoldedIsFarSmallerThanOpen() {
        let m = model(cells: 3)
        m.isExpanded = false
        let folded = m.notchSize
        m.isExpanded = true
        let open = m.notchSize
        XCTAssertLessThan(folded.width, open.width / 2)
        XCTAssertLessThan(folded.height, open.height / 2)
    }

    /// Both states share a centre line, so folding does not slide the notch up
    /// the screen as it shrinks. It contracts in place.
    func testFoldingKeepsTheCentreLine() {
        let m = model(cells: 3)
        m.isExpanded = true
        let openCentre = m.notchLeadingInset + m.notchSize.height / 2
        m.isExpanded = false
        let foldedCentre = m.notchLeadingInset + m.notchSize.height / 2
        XCTAssertEqual(openCentre, foldedCentre, accuracy: 0.001)
    }

    /// The panel never resizes for the fold: animating a window frame is jerky,
    /// and the reserved space is transparent anyway.
    func testThePanelIsTheSameSizeEitherWay() {
        let m = model(cells: 3)
        m.isExpanded = true
        let open = m.panelSize
        m.isExpanded = false
        XCTAssertEqual(open, m.panelSize)
    }

    /// A 10pt target on a screen edge is fiddly, so the region that wakes it is
    /// deliberately bigger than the pill it surrounds.
    func testTheWakeRegionIsLargerThanThePill() {
        XCTAssertGreaterThan(NotchLayout.pillHotZone, NotchLayout.pillWidth)
    }
}

/// Motion is a vocabulary, not a pile of magic numbers.
final class NotchMotionTests: XCTestCase {
    /// Reduce Motion means no animation at all, not a faster one.
    func testReduceMotionRemovesTheAnimation() {
        XCTAssertNil(NotchMotion.respectingReduceMotion(NotchMotion.unfold, true))
        XCTAssertNotNil(NotchMotion.respectingReduceMotion(NotchMotion.unfold, false))
    }

    /// The open and close spring, restored from the project's first commit.
    /// Also checked against the short ease it replaced, so this is pinning
    /// the actual response and damping, not just any non-nil animation.
    func testUnfoldIsTheOriginalSpring() {
        XCTAssertEqual(NotchMotion.unfold, .spring(response: 0.42, dampingFraction: 0.78))
        XCTAssertNotEqual(NotchMotion.unfold, .easeOut(duration: 0.22))
    }

    /// The stagger is capped, so a long cell list never feels sluggish.
    func testStaggerHasNoDelayForTheFirstCell() {
        XCTAssertEqual(NotchMotion.stagger(index: 0), NotchMotion.contents.delay(0))
    }

    func testStaggerCapsAtEighteenHundredthsOfASecond() {
        XCTAssertEqual(NotchMotion.stagger(index: 10), NotchMotion.contents.delay(0.18))
    }
}

/// The shape has to stay a notch at every size it is drawn at. Including the
/// pill, which is narrower than the flare radius it was designed around.
final class SideNotchShapeTests: XCTestCase {
    private func bounds(width: CGFloat, height: CGFloat) -> CGRect {
        SideNotchShape().path(in: CGRect(x: 0, y: 0, width: width, height: height)).boundingRect
    }

    /// The bug: clamping the corner by `width - curl` collapsed it to zero as
    /// soon as the flare was as wide as the body, so the folded pill came out
    /// with square corners.
    func testTheFoldedPillKeepsItsCorners() {
        let width = NotchLayout.pillWidth
        let path = SideNotchShape().path(
            in: CGRect(x: 0, y: 0, width: width, height: NotchLayout.pillHeight())
        )
        // A square-cornered pill touches its own top-left corner; a rounded one
        // never does.
        XCTAssertFalse(path.contains(CGPoint(x: 0.5, y: 0.5)),
                       "the pill's top-left corner is square")
        XCTAssertFalse(path.contains(CGPoint(x: 0.5, y: NotchLayout.pillHeight() - 0.5)),
                       "the pill's bottom-left corner is square")
    }

    /// Fixing the pill must not reshape the notch's open proportions: at full
    /// width the flare is wider than half the body and must stay so.
    func testTheOpenNotchIsUnchanged() {
        let width = NotchLayout.bodyDepth(for: .right)
        let path = SideNotchShape().path(in: CGRect(x: 0, y: 0, width: width, height: 400))
        XCTAssertEqual(path.boundingRect.width, width, accuracy: 0.5)
        XCTAssertEqual(path.boundingRect.height, 400, accuracy: 0.5)

        // The flare: near the top the shape is a sliver hugging the edge, and by
        // mid-height it is the full body. Sampled rather than probed at a single
        // point. A point 1pt down sits in a flare only hundredths of a point
        // wide, which is a fact about arcs, not about the shape being wrong.
        func filled(atY y: CGFloat) -> CGFloat {
            let hits = stride(from: CGFloat(0.25), to: width, by: 0.25)
                .filter { path.contains(CGPoint(x: $0, y: y)) }
            return hits.isEmpty ? 0 : width - hits.min()!
        }
        XCTAssertLessThan(filled(atY: 4), width / 3, "no flare at the top")
        XCTAssertEqual(filled(atY: 200), width, accuracy: 1, "not full width in the body")
        XCTAssertLessThan(filled(atY: 396), width / 3, "no flare at the bottom")
    }

    /// It is drawn at every size in between while folding, so none of them may
    /// produce a degenerate path.
    func testEveryIntermediateSizeIsDrawable() {
        for step in 0...20 {
            let t = CGFloat(step) / 20
            let w = NotchLayout.pillWidth + (NotchLayout.bodyDepth(for: .right) - NotchLayout.pillWidth) * t
            let h = NotchLayout.pillHeight() + (400 - NotchLayout.pillHeight()) * t
            let box = bounds(width: w, height: h)
            XCTAssertFalse(box.isEmpty, "degenerate path at \(w) x \(h)")
            XCTAssertEqual(box.width, w, accuracy: 1)
        }
    }
}

/// The rings are buttons: clicking one runs that cell's action, so the cursor
/// should say so, and only there.
@MainActor
final class PointerStateTests: XCTestCase {
    func testACellShowsThePointingHand() {
        XCTAssertTrue(NotchWindowController.wantsPointingHand(isExpanded: true, cellIndex: 0))
        XCTAssertTrue(NotchWindowController.wantsPointingHand(isExpanded: true, cellIndex: 2))
    }

    /// The gap around the cells is not a button.
    func testTheRestOfTheNotchDoesNot() {
        XCTAssertFalse(NotchWindowController.wantsPointingHand(isExpanded: true, cellIndex: nil))
    }

    /// Folded, the pill is a handle you hover rather than a button you aim at,
    /// and a pointer that flashes on the way past is noise.
    func testTheFoldedPillDoesNot() {
        XCTAssertFalse(NotchWindowController.wantsPointingHand(isExpanded: false, cellIndex: 0))
        XCTAssertFalse(NotchWindowController.wantsPointingHand(isExpanded: false, cellIndex: nil))
    }
}

/// The settings orb sits in the corner the notch's bottom flare makes, and its
/// resting arc follows that curve rather than merely sitting near it.
@MainActor
final class SettingsOrbTests: XCTestCase {
    private func centre(_ count: Int) -> CGFloat {
        NotchLayout.orbCenterAlong(cellCount: count)
    }

    private func shapeBottom(_ count: Int) -> CGFloat {
        NotchLayout.shapeLength(cellCount: count)
    }

    /// The whole point: the orb shares the flare's centre of curvature, so the
    /// two arcs are concentric and the resting stroke parallels the edge. Centre
    /// it anywhere else. On the body's axis, say. And it stops following the
    /// contour, which is exactly what went wrong first time.
    func testItSharesTheFlaresCentreOfCurvature() {
        XCTAssertEqual(NotchLayout.orbInsetFromEdge, NotchLayout.curlRadius, accuracy: 0.001)
        for count in 1...4 {
            XCTAssertEqual(centre(count), shapeBottom(count), accuracy: 0.001,
                           "\(count): the orb's centre must be the flare's centre")
        }
    }

    /// Inside the flare, with a real gap. Touching it would read as a smudge on
    /// the notch rather than as a separate control.
    func testTheArcSitsInsideTheFlareWithAGap() {
        XCTAssertLessThan(NotchLayout.orbArcRadius, NotchLayout.curlRadius)
        let gap = NotchLayout.curlRadius - NotchLayout.orbArcRadius
        XCTAssertGreaterThan(gap, NotchLayout.orbStroke / 2,
                             "the stroke would touch the flare")
    }

    /// The filled disc goes inside the arc, so hovering does not push past it.
    func testTheDiscFitsWithinTheArc() {
        XCTAssertLessThan(NotchLayout.orbDiameter / 2, NotchLayout.orbArcRadius)
    }

    /// The notch itself must not grow for it. The orb is not part of the shape.
    func testTheNotchDoesNotGrowForIt() {
        let cells = NotchLayout.cellExtent()
        let body = NotchLayout.bodyLength(cellCount: 2)
        let bare = NotchLayout.padTop() + 2 * cells + NotchLayout.cellSpacing() + NotchLayout.padBottom()
        XCTAssertEqual(body, bare, accuracy: 0.001)
    }

    /// The panel has to reserve room below the shape or the orb is clipped away.
    func testThePanelHasRoomBelowTheNotch() {
        let overhang = NotchLayout.orbArcRadius + NotchLayout.orbStroke
        XCTAssertLessThanOrEqual(overhang, NotchLayout.slack(for: .right))
    }

    /// Like the pill's, the region you can hit is larger than what is drawn.
    func testTheHitRegionIsLargerThanTheOrb() {
        XCTAssertGreaterThan(NotchLayout.orbHotZone, NotchLayout.orbDiameter)
    }
}

/// The notch's own visibility. Its default matters more than the other two
/// settings here: get it wrong and a fresh install shows nothing at all, which
/// is indistinguishable from the app failing to start.
final class NotchVisibilityTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "NotchVisibilityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @MainActor
    func testItDefaultsToHoverRatherThanHidden() {
        XCTAssertEqual(Preferences(defaults: defaults()).notchVisibility, .onHover)
    }

    @MainActor
    func testTheChoiceSurvivesARestart() {
        let defaults = defaults()
        Preferences(defaults: defaults).notchVisibility = .alwaysShow
        XCTAssertEqual(Preferences(defaults: defaults).notchVisibility, .alwaysShow)
    }

    /// A value written by a future version, or corrupted, must not hide the
    /// notch. It falls back to the visible default.
    @MainActor
    func testAnUnknownStoredValueFallsBackToVisible() {
        let defaults = defaults()
        defaults.set("teleport", forKey: "notchVisibility")
        XCTAssertEqual(Preferences(defaults: defaults).notchVisibility, .onHover)
    }

    /// Hiding removes every other way back into the app, so the option itself
    /// has to say where the door is.
    func testHidingExplainsHowToGetBack() {
        XCTAssertTrue(NotchVisibility.hidden.explanation.contains("Applications"))
    }

    func testEveryModeIsOfferedAndNamed() {
        XCTAssertEqual(NotchVisibility.allCases.count, 3)
        for mode in NotchVisibility.allCases {
            XCTAssertFalse(mode.title.isEmpty)
            XCTAssertFalse(mode.explanation.isEmpty)
        }
    }
}

