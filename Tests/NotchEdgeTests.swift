import SwiftUI
import XCTest
@testable import Drawer

private struct FakeScreen: ScreenDescribing {
    var frameValue: CGRect
    var visibleFrameValue: CGRect
}

/// The notch was welded to the right edge and nothing else. These pin the axis
/// abstraction that lets it live on either side.
final class NotchEdgeTests: XCTestCase {
    func testEveryEdgeIsOfferedAndNamed() {
        XCTAssertEqual(NotchEdge.allCases.count, 2)
        let titles = NotchEdge.allCases.map(\.title)
        XCTAssertEqual(Set(titles).count, 2, "two edges share a name")
        XCTAssertFalse(titles.contains(where: \.isEmpty))
    }

    /// The tooltip leaves the notch by the face that is not against the bezel.
    func testTheTooltipLeavesByTheInwardFace() {
        XCTAssertEqual(NotchEdge.right.tooltipDirection, .leading)
        XCTAssertEqual(NotchEdge.left.tooltipDirection, .trailing)
    }
}

/// `NotchPlacement` is the one place that knows which way is which. Everything
/// else in the notch works in stack space: `along` runs the length of the
/// stack, `across` measures inward from the bezel.
final class NotchPlacementTests: XCTestCase {
    private let panel = CGSize(width: 400, height: 900)

    private func placement(_ edge: NotchEdge) -> NotchPlacement {
        NotchPlacement(edge: edge, panelSize: panel)
    }

    /// Zero is always the bezel, whichever bezel that is.
    func testAcrossZeroIsTheEdgeItself() {
        XCTAssertEqual(placement(.right).point(along: 0, across: 0).x, 400, accuracy: 0.001)
        XCTAssertEqual(placement(.left).point(along: 0, across: 0).x, 0, accuracy: 0.001)
    }

    /// And a positive `across` always moves toward the middle of the screen.
    /// This is the whole reason the rest of the code can stop caring.
    func testAcrossGrowsInwardFromEveryEdge() {
        XCTAssertEqual(placement(.right).point(along: 0, across: 30).x, 370, accuracy: 0.001)
        XCTAssertEqual(placement(.left).point(along: 0, across: 30).x, 30, accuracy: 0.001)
    }

    func testAlongRunsDownBothSides() {
        XCTAssertEqual(placement(.right).point(along: 120, across: 0).y, 120, accuracy: 0.001)
        XCTAssertEqual(placement(.left).point(along: 120, across: 0).y, 120, accuracy: 0.001)
    }

    /// A hit region spans `depth` *inward*, so it never hangs off the screen
    /// side of the edge it is pinned to.
    func testARectSpansInwardFromTheEdge() {
        XCTAssertEqual(
            placement(.right).rect(along: 10, across: 0, length: 200, depth: 70),
            CGRect(x: 330, y: 10, width: 70, height: 200)
        )
        XCTAssertEqual(
            placement(.left).rect(along: 10, across: 0, length: 200, depth: 70),
            CGRect(x: 0, y: 10, width: 70, height: 200)
        )
    }

    /// The geometry the window controller used to write out by hand.
    func testTheRightEdgeReproducesTheHandWrittenNotchRect() {
        let notch = placement(.right).rect(
            along: NotchLayout.slack(for: .right),
            across: 0,
            length: 484,
            depth: NotchLayout.bodyDepth(for: .right)
        )
        XCTAssertEqual(notch.maxX, panel.width, accuracy: 0.001)
        XCTAssertEqual(notch.minY, NotchLayout.slack(for: .right), accuracy: 0.001)
        XCTAssertEqual(notch.width, NotchLayout.bodyDepth(for: .right), accuracy: 0.001)
        XCTAssertEqual(notch.height, 484, accuracy: 0.001)
    }

    func testThePanelIsTallOnBothSides() {
        for edge in NotchEdge.allCases {
            XCTAssertEqual(
                NotchPlacement.panelSize(edge: edge, length: 500, depth: 300),
                CGSize(width: 300, height: 500), "\(edge)"
            )
        }
    }

    /// The centre of a rect is the point at its own middle, whichever way round
    /// the axes are. This is what positions the tooltip and the orb.
    func testACentredRectAgreesWithItsOwnCentrePoint() {
        for edge in NotchEdge.allCases {
            let place = placement(edge)
            let rect = place.rect(along: 100, across: 20, length: 60, depth: 40)
            let centre = place.point(along: 130, across: 40)
            XCTAssertEqual(rect.midX, centre.x, accuracy: 0.001, "\(edge)")
            XCTAssertEqual(rect.midY, centre.y, accuracy: 0.001, "\(edge)")
        }
    }
}

/// The notch is pinned to the *usable* edge, so it rests on the Dock rather
/// than under it, and below the menu bar rather than behind it.
final class DockAvoidanceTests: XCTestCase {
    /// A 70pt Dock at the bottom, and the menu bar above it.
    private let docked = FakeScreen(
        frameValue: CGRect(x: 0, y: 0, width: 1800, height: 1169),
        visibleFrameValue: CGRect(x: 0, y: 70, width: 1800, height: 1062)
    )
    private let wide = CGSize(width: 600, height: 200)

    func testASideDockPushesTheNotchIn() {
        let leftDock = FakeScreen(
            frameValue: CGRect(x: 0, y: 0, width: 1800, height: 1169),
            visibleFrameValue: CGRect(x: 90, y: 0, width: 1710, height: 1132)
        )
        let frame = NotchGeometry.panelFrame(
            for: leftDock, panelSize: CGSize(width: 334, height: 484), edge: .left
        )
        XCTAssertEqual(frame.minX, 90, accuracy: 0.001)
    }

    /// A Dock that hides gives the space back, and the notch takes it. This is
    /// what makes the placement follow rather than guess once at launch.
    /// Centring stays on the whole screen. A Dock at the bottom is nowhere near
    /// a right-edge notch, and letting it shift one upward would move the notch
    /// every time the Dock hid itself.
    func testCentringIgnoresChromeOnTheOtherAxis() {
        let frame = NotchGeometry.panelFrame(
            for: docked, panelSize: CGSize(width: 334, height: 484), edge: .right
        )
        XCTAssertEqual(frame.midY, docked.frameValue.midY, accuracy: 0.5)
    }
}

/// A horizontal stack puts the card *below* the notch rather than beside it, so
/// the room it needs is at the ends of the stack instead of off to one side.
final class StackSlackTests: XCTestCase {
    /// A side edge needs half the tallest card past each end, not the bare
    /// breathing space it used to have.
    ///
    /// This previously asserted the slack stayed at `Design.px(190)`, on the
    /// reasoning that a card beside the stack needs no room at the ends. It
    /// sits beside the stack horizontally but is centred on its cell
    /// *vertically*, so hovering the first cell threw half a card. Some
    /// 237pt against 71pt of slack. Past the top of the panel, and the card's
    /// own title was clipped off.
    func testASideEdgeLeavesRoomForHalfACard() {
        for edge in [NotchEdge.right, .left] {
            XCTAssertGreaterThanOrEqual(NotchLayout.slack(for: edge),
                                        NotchLayout.maxCardHeight() / 2)
        }
        XCTAssertEqual(NotchLayout.slack(for: .right), NotchLayout.slack(for: .left))
    }

    /// The panel is sized from the stack, so both edges are narrow and tall.
    @MainActor
    func testThePanelStandsUpOnBothEdges() {
        let model = NotchViewModel()
        for edge in NotchEdge.allCases {
            model.edge = edge
            let panel = model.panelSize(cellCount: 3)
            XCTAssertGreaterThan(panel.height, panel.width, "\(edge)")
        }
    }

    /// Whatever the edge, the panel always has room for the whole shape.
    @MainActor
    func testThePanelAlwaysFitsTheShapeOnEveryEdge() {
        let model = NotchViewModel()
        for edge in NotchEdge.allCases {
            model.edge = edge
            for count in 0...5 {
                let panel = model.panelSize(cellCount: count)
                let along = panel.height
                XCTAssertGreaterThanOrEqual(
                    along, model.shapeLength(cellCount: count),
                    "\(edge) with \(count) cells"
                )
            }
        }
    }
}

/// The notch shape is written once for the right edge and transformed onto the
/// others. These pin that the transform really is a rigid one. The same
/// silhouette, turned. Rather than something that quietly stretches it.
final class RotatedShapeTests: XCTestCase {
    /// Whatever this edge's depth is, the same on every edge now that the
    /// cell is the ring alone.
    private func depth(_ edge: NotchEdge) -> CGFloat { NotchLayout.bodyDepth(for: edge) }
    private let length: CGFloat = 400

    private func rect(_ edge: NotchEdge) -> CGRect {
        CGRect(x: 0, y: 0, width: depth(edge), height: length)
    }

    private func path(_ edge: NotchEdge) -> Path {
        SideNotchShape(edge: edge).path(in: rect(edge))
    }

    func testItFillsItsRectOnEveryEdge() {
        for edge in NotchEdge.allCases {
            let box = path(edge).boundingRect
            XCTAssertEqual(box.width, rect(edge).width, accuracy: 1, "\(edge)")
            XCTAssertEqual(box.height, rect(edge).height, accuracy: 1, "\(edge)")
        }
    }

    /// The waist. Where the inverse corners pinch the shape in. Sits at the
    /// middle of the stack on every edge, and the flares at its ends.
    func testTheFlaresAreAtTheEndsOfTheStackWhicheverEdgeItIsOn() {
        for edge in NotchEdge.allCases {
            let place = NotchPlacement(edge: edge, panelSize: rect(edge).size)
            let path = path(edge)

            /// How deep the shape is at a given point along it.
            func filled(at along: CGFloat) -> CGFloat {
                let hits = stride(from: CGFloat(0.25), to: depth(edge), by: 0.25)
                    .filter { path.contains(place.point(along: along, across: $0)) }
                return hits.max() ?? 0
            }
            XCTAssertLessThan(filled(at: 4), depth(edge) / 3, "\(edge): no flare at the start")
            XCTAssertEqual(filled(at: length / 2), depth(edge), accuracy: 1, "\(edge): not full depth")
            XCTAssertLessThan(filled(at: length - 4), depth(edge) / 3, "\(edge): no flare at the end")
        }
    }

    /// The bezel side is solid; the inward side is where the body stops.
    func testTheBodyIsWeldedToTheBezelOnEveryEdge() {
        for edge in NotchEdge.allCases {
            let place = NotchPlacement(edge: edge, panelSize: rect(edge).size)
            let path = path(edge)
            XCTAssertTrue(
                path.contains(place.point(along: length / 2, across: 0.5)),
                "\(edge): the shape does not reach the bezel"
            )
            XCTAssertFalse(
                path.contains(place.point(along: 4, across: depth(edge) - 0.5)),
                "\(edge): the flare is missing. The shape is square at the end"
            )
        }
    }

    /// The folded pill's corners were the bug that made the clamping order
    /// matter. Rotating must not reintroduce it.
    func testTheFoldedPillKeepsItsCornersOnEveryEdge() {
        for edge in NotchEdge.allCases {
            let size = NotchPlacement.panelSize(
                edge: edge, length: NotchLayout.pillHeight(), depth: NotchLayout.pillWidth
            )
            let place = NotchPlacement(edge: edge, panelSize: size)
            let path = SideNotchShape(edge: edge).path(in: CGRect(origin: .zero, size: size))
            for along in [CGFloat(0.5), NotchLayout.pillHeight() - 0.5] {
                XCTAssertFalse(
                    path.contains(place.point(along: along, across: NotchLayout.pillWidth - 0.5)),
                    "\(edge): the pill has a square corner at \(along)"
                )
            }
        }
    }
}

/// Folding away has to behave the same on every edge. Contracting in place
/// rather than sliding along the bezel as it shrinks.
@MainActor
final class FoldingOnEveryEdgeTests: XCTestCase {
    private func model(cells: Int, edge: NotchEdge) -> NotchViewModel {
        let model = NotchViewModel()
        model.edge = edge
        model.cells = Fixtures.cells(cells)
        return model
    }

    func testFoldingKeepsTheCentreLineOnEveryEdge() {
        for edge in NotchEdge.allCases {
            let m = model(cells: 3, edge: edge)
            m.isExpanded = true
            let open = m.notchLeadingInset + m.notchLength / 2
            m.isExpanded = false
            let folded = m.notchLeadingInset + m.notchLength / 2
            XCTAssertEqual(open, folded, accuracy: 0.001, "\(edge)")
        }
    }

    /// The panel never resizes for the fold: animating a window frame is jerky,
    /// and the reserved space is transparent anyway.
    func testThePanelIsTheSameSizeEitherWayOnEveryEdge() {
        for edge in NotchEdge.allCases {
            let m = model(cells: 3, edge: edge)
            m.isExpanded = true
            let open = m.panelSize
            m.isExpanded = false
            XCTAssertEqual(open, m.panelSize, "\(edge)")
        }
    }

    /// Folded, the notch is a sliver against the bezel whichever bezel that is.
    func testTheFoldedNotchIsShallowOnEveryEdge() {
        for edge in NotchEdge.allCases {
            let m = model(cells: 3, edge: edge)
            m.isExpanded = false
            XCTAssertLessThan(m.notchDepth, NotchLayout.bodyDepth(for: edge) / 2, "\(edge)")
            XCTAssertLessThan(m.notchLength, m.shapeLength / 2, "\(edge)")
        }
    }
}

/// The orb hangs past the far end of the notch, one flare-radius in from the
/// bezel. That has to stay true when the notch turns.
@MainActor
final class OrbOnEveryEdgeTests: XCTestCase {
    func testTheOrbClearsTheEndOfTheShapeOnEveryEdge() {
        for edge in NotchEdge.allCases {
            let along = NotchLayout.slack(for: edge) + NotchLayout.orbCenterAlong(
                cellCount: 3
            )
            let panelLength = NotchLayout.shapeLength(
                cellCount: 3
            ) + 2 * NotchLayout.slack(for: edge)
            let overhang = NotchLayout.orbArcRadius + NotchLayout.orbStroke
            XCTAssertLessThanOrEqual(along + overhang, panelLength, "\(edge): the orb is clipped")
        }
    }

    /// It sits inward of the bezel by the flare's radius, never on top of it.
    func testTheOrbSitsInsideTheBezelOnEveryEdge() {
        for edge in NotchEdge.allCases {
            let size = NotchPlacement.panelSize(edge: edge, length: 900, depth: 400)
            let place = NotchPlacement(edge: edge, panelSize: size)
            let centre = place.point(along: 500, across: NotchLayout.orbInsetFromEdge)
            XCTAssertEqual(place.across(of: centre), NotchLayout.orbInsetFromEdge, accuracy: 0.001, "\(edge)")
            XCTAssertGreaterThan(place.across(of: centre), 0, "\(edge)")
        }
    }
}

/// The cell is the ring alone on every edge, so the notch is the same shape
/// whichever edge the stack is on.
final class HorizontalCellTests: XCTestCase {
    /// No edge needs to dig any deeper than NotchLayout's own margin around
    /// the ring.
    func testBodyDepthIsUniformAcrossEdges() {
        for edge in NotchEdge.allCases {
            XCTAssertEqual(NotchLayout.bodyDepth(for: edge), NotchLayout.sideBodyDepth(), accuracy: 0.001, "\(edge)")
        }
    }

    /// And the side edges keep exactly the depth NotchLayout fixes, so the
    /// default placement is untouched.
    func testASideNotchKeepsItsOwnDepth() {
        XCTAssertEqual(NotchLayout.bodyDepth(for: .right), Design.px(186), accuracy: 0.001)
        XCTAssertEqual(NotchLayout.bodyDepth(for: .left), Design.px(186), accuracy: 0.001)
    }

    /// The ring keeps the same clear margin from the bezel on every edge.
    func testTheRingHasTheSameMarginFromTheBezelOnEveryEdge() {
        for edge in NotchEdge.allCases {
            let margin = NotchLayout.ringMargin(for: edge)
            XCTAssertGreaterThan(margin, 0, "\(edge)")
            XCTAssertLessThanOrEqual(
                margin + NotchLayout.ringDiameter(), NotchLayout.bodyDepth(for: edge),
                "\(edge): the ring does not fit the body"
            )
        }
    }

    /// The ring leads its cell on every edge. There is nothing else on the
    /// stack, so leading it and filling it are the same thing.
    func testTheRingLeadsItsCellOnEveryEdge() {
        for edge in NotchEdge.allCases {
            let lead = NotchLayout.curlRadius + NotchLayout.padStart(for: edge)
            XCTAssertEqual(
                NotchLayout.ringCenter(index: 0, edge: edge) - lead,
                NotchLayout.ringDiameter() / 2, accuracy: 0.001, "\(edge)"
            )
        }
    }

    /// Whichever edge, cells are one pitch apart. That is what makes the hover
    /// bands and the hover card line up with the rings that are drawn.
    func testCellsAreOnePitchApartOnEveryEdge() {
        for edge in NotchEdge.allCases {
            XCTAssertEqual(
                NotchLayout.ringCenter(index: 3, edge: edge)
                    - NotchLayout.ringCenter(index: 2, edge: edge),
                NotchLayout.cellPitch(for: edge), accuracy: 0.001, "\(edge)"
            )
        }
    }

    /// Every cell has to sit inside the body it is drawn in, or the last ring
    /// hangs out past the flare.
    func testEveryCellFallsInsideTheBodyOnEveryEdge() {
        for edge in NotchEdge.allCases {
            let shape = NotchLayout.shapeLength(cellCount: 4, edge: edge)
            for index in 0..<4 {
                let centre = NotchLayout.ringCenter(index: index, edge: edge)
                let half = NotchLayout.cellAlong(for: edge) / 2
                XCTAssertGreaterThanOrEqual(centre - half, 0, "\(edge) cell \(index)")
                XCTAssertLessThanOrEqual(centre + half, shape, "\(edge) cell \(index)")
            }
        }
    }
}

/// The settings orb is a segment of the *same circle* the notch's far flare
/// curves around, one gap inside it. That is what makes it read as following
/// the contour of the edge rather than merely sitting near it. And it means
/// the quadrant it occupies has to turn with the notch.
final class OrbOrientationTests: XCTestCase {
    /// Where the middle of the resting arc points, as a unit vector in panel
    /// coordinates. SwiftUI's `Circle` trim starts at 3 o'clock and runs
    /// clockwise with y growing downward.
    private func arcDirection(_ edge: NotchEdge) -> CGPoint {
        let range = SettingsOrb.restingTrim(for: edge)
        let mid = (range.lowerBound + range.upperBound) / 2
        let angle = Double(mid) * 2 * .pi
        return CGPoint(x: cos(angle), y: sin(angle))
    }

    private func dot(_ a: CGPoint, _ b: CGPoint) -> CGFloat { a.x * b.x + a.y * b.y }

    /// It faces the bezel. The arc is the outer edge of the orb, and the orb
    /// merges into the notch's black by travelling that way.
    func testTheArcFacesTheBezelOnEveryEdge() {
        for edge in NotchEdge.allCases {
            XCTAssertGreaterThan(
                dot(arcDirection(edge), edge.outward), 0.5,
                "\(edge): the resting arc faces away from the bezel"
            )
        }
    }

    /// And back toward the notch it hangs off, not out into open screen.
    func testTheArcFacesBackTowardTheNotchOnEveryEdge() {
        for edge in NotchEdge.allCases {
            let backwards = CGPoint(x: -edge.alongDirection.x, y: -edge.alongDirection.y)
            XCTAssertGreaterThan(
                dot(arcDirection(edge), backwards), 0.5,
                "\(edge): the resting arc points away from the notch"
            )
        }
    }

    /// A quarter of the circle on every edge. The same object, turned.
    func testItIsAQuadrantOnEveryEdge() {
        for edge in NotchEdge.allCases {
            let range = SettingsOrb.restingTrim(for: edge)
            XCTAssertEqual(range.upperBound - range.lowerBound, 0.25, accuracy: 0.0001, "\(edge)")
        }
    }

    /// The right edge is untouched: this is the arc that was drawn before there
    /// was any choice of edge.
    func testTheRightEdgeKeepsTheArcItAlwaysHad() {
        XCTAssertEqual(SettingsOrb.restingTrim(for: .right).lowerBound, 0.75, accuracy: 0.0001)
        XCTAssertEqual(SettingsOrb.restingTrim(for: .right).upperBound, 1.0, accuracy: 0.0001)
    }

    /// `alongDirection` and `outward` are perpendicular by construction. The
    /// stack runs along the bezel and `across` leaves it at a right angle.
    func testTheStackRunsAlongTheBezelNotIntoIt() {
        for edge in NotchEdge.allCases {
            XCTAssertEqual(dot(edge.alongDirection, edge.outward), 0, accuracy: 0.0001, "\(edge)")
        }
    }
}

/// A lone ring should sit in the middle of the notch it is alone in.
final class SingleCellBalanceTests: XCTestCase {
    /// `padTop` and `padBottom` are not the same number, and down a side edge
    /// they stay different: `padTop` measures the body's top to the first
    /// ring, `padBottom` measures the last ring to the body's foot. That
    /// asymmetry is NotchLayout's own and is kept as is.
    ///
    /// And the side edges keep NotchLayout's own asymmetry, untouched.
    func testTheSideEdgesKeepTheLayoutsUnevenPadding() {
        XCTAssertEqual(NotchLayout.padStart(for: .right), Design.px(69.5), accuracy: 0.001)
        XCTAssertEqual(NotchLayout.padEnd(for: .right), Design.px(50.1), accuracy: 0.001)
        XCTAssertNotEqual(NotchLayout.padStart(for: .right), NotchLayout.padEnd(for: .right))
    }

}

/// A cell claims what it needs along the stack, and no more: the ring alone,
/// on every edge.
final class CellPitchTests: XCTestCase {
    /// The gap you actually see between two rings is NotchLayout's own spacing,
    /// on every edge.
    func testTheGapBetweenRingsIsTheLayoutsSpacingOnEveryEdge() {
        for edge in NotchEdge.allCases {
            let pitch = NotchLayout.cellPitch(for: edge)
            XCTAssertEqual(pitch - NotchLayout.cellExtent(), NotchLayout.cellSpacing(),
                           accuracy: 0.001, "\(edge)")
        }
    }

    /// Which leaves clear space between adjacent rings of about two thirds of a
    /// ring. Not half as much again as the ring itself.
    func testAdjacentRingsAreNotFlungApart() {
        let edge = NotchEdge.right
        let clear = NotchLayout.ringCenter(index: 1, edge: edge)
            - NotchLayout.ringCenter(index: 0, edge: edge)
            - NotchLayout.ringDiameter()
        XCTAssertLessThan(clear, NotchLayout.ringDiameter(),
                          "there is more space between the rings than there is ring")
    }

    /// The side edges' pitch is just the ring plus NotchLayout's own spacing,
    /// now that there is no label to fill part of it.
    func testTheSideEdgesPitchIsRingPlusSpacing() {
        XCTAssertEqual(
            NotchLayout.cellPitch(for: .right),
            NotchLayout.ringDiameter() + NotchLayout.cellSpacing(), accuracy: 0.001
        )
    }

    /// The cell is the ring alone, on every edge.
    func testCellExtentIsTheRing() {
        XCTAssertEqual(NotchLayout.cellExtent(), NotchLayout.ringDiameter(), accuracy: 0.001)
        for edge in NotchEdge.allCases {
            XCTAssertEqual(NotchLayout.cellAlong(for: edge), NotchLayout.ringDiameter(), accuracy: 0.001, "\(edge)")
        }
    }
}
