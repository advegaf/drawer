import SwiftUI
import XCTest
@testable import Drawer

/// The card's layout maths can be right and still put nothing on screen, or
/// spill a sentence past the budget it was given. These render the real view
/// and look at the pixels, the same idiom `CellRenderTests` uses.
@MainActor
final class ItemCardRenderTests: XCTestCase {
    private static let pad = (NotchLayout.cardShadowPad + NotchLayout.pointerDepth).rounded(.up)

    func testOLEDCardHasNoCustomBorderAndKeepsASubtleShadow() {
        let renderer = ImageRenderer(content:
            TooltipShell(height: 80, direction: .leading) { EmptyView() }.padding(Self.pad)
        )
        renderer.scale = 2
        guard let image = renderer.cgImage else { return XCTFail("no image") }
        let rep = NSBitmapImageRep(cgImage: image)
        let centerY = Int((Self.pad + 40) * 2)
        let edgeX = Int(Self.pad * 2)
        for x in edgeX...(edgeX + 3) {
            guard let color = rep.colorAt(x: x, y: centerY) else { return XCTFail("missing edge pixel") }
            XCTAssertLessThan(color.brightnessComponent, 0.01)
        }
        guard let shadow = rep.colorAt(x: edgeX - 2, y: centerY) else { return XCTFail("missing shadow pixel") }
        XCTAssertGreaterThan(shadow.alphaComponent, 0)
        XCTAssertLessThan(shadow.alphaComponent, 0.2)
    }

    func testPresentedCardHeightMatchesTheCurrentHitRectangle() {
        let cell = DrawerCell(id: "volume", title: "Volume", icon: .symbol("speaker"), kind: .level, state: .level(0.5))
        let height: CGFloat = 55
        let renderer = ImageRenderer(content:
            ItemCard(cell: cell, direction: .leading, presentationHeight: height).padding(Self.pad)
        )
        renderer.scale = 1
        guard let image = renderer.cgImage else { return XCTFail("no image") }
        XCTAssertEqual(CGFloat(image.height), height + Self.pad * 2, accuracy: 1)
        let width = NotchLayout.cardWidth(title: cell.title, note: "50%")
        XCTAssertEqual(CGFloat(image.width), width + Self.pad * 2, accuracy: 1)
    }

    func testUnavailableAndUnknownLevelsDoNotPaintASlider() {
        for state in [CellState.unknown, .unavailable, .failed("Could not read level")] {
            let cell = DrawerCell(id: "volume", title: "Volume", icon: .symbol("speaker"), kind: .level, state: state)
            guard let (rep, _) = render(cell) else { return XCTFail("no image") }
            XCTAssertFalse(sliderIsPainted(rep))
        }
        let active = DrawerCell(id: "volume", title: "Volume", icon: .symbol("speaker"), kind: .level, state: .level(0))
        guard let (rep, _) = render(active) else { return XCTFail("no image") }
        XCTAssertTrue(sliderIsPainted(rep), "an observed zero is still a valid level")
    }

    func testExplicitSliderFractionPaintsDuringTransientUnknownState() {
        let cell = DrawerCell(id: "volume", title: "Volume", icon: .symbol("speaker"), kind: .level, state: .unknown)
        let renderer = ImageRenderer(content: ItemCard(cell: cell, direction: .leading, sliderFraction: 0.5).padding(Self.pad))
        renderer.scale = 1
        guard let image = renderer.cgImage else { return XCTFail("no image") }
        XCTAssertTrue(sliderIsPainted(NSBitmapImageRep(cgImage: image)))
    }

    private func sliderIsPainted(_ rep: NSBitmapImageRep) -> Bool {
        let top = Self.pad + NotchLayout.cardPadding + NotchLayout.cardTitleLineHeight() + NotchLayout.headerToBlock
        // A card is as wide as its own text now, and the floor is the
        // narrowest it can be, so sampling to the floor stays inside it.
        let right = Self.pad + NotchLayout.cardMinWidth - NotchLayout.cardPadding
        for y in Int(ceil(top))..<Int(top + NotchLayout.sliderHitDepth) {
            for x in Int(Self.pad + NotchLayout.cardPadding)..<Int(right) {
                if isPainted(rep.colorAt(x: x, y: y)) { return true }
            }
        }
        return false
    }

    private func render(_ cell: DrawerCell) -> (rep: NSBitmapImageRep, height: CGFloat)? {
        let renderer = ImageRenderer(content:
            ItemCard(cell: cell, direction: .leading).padding(Self.pad)
        )
        renderer.scale = 1
        guard let image = renderer.cgImage else { return nil }
        return (NSBitmapImageRep(cgImage: image), CGFloat(image.height) - 2 * Self.pad)
    }

    private func isPainted(_ colour: NSColor?) -> Bool {
        guard let colour, colour.alphaComponent > 0.6 else { return false }
        return colour.redComponent > 0.3 || colour.greenComponent > 0.3 || colour.blueComponent > 0.3
    }

    private func inkedFraction(_ rep: NSBitmapImageRep) -> Double {
        var inked = 0, total = 0
        for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
                total += 1
                if isPainted(rep.colorAt(x: x, y: y)) { inked += 1 }
            }
        }
        return total == 0 ? 0 : Double(inked) / Double(total)
    }

    /// The last `cardPadding` band at the foot of the card's own body, card
    /// width only, inside the outer `pad` every render carries.
    private func bottomBandIsUnpainted(_ rep: NSBitmapImageRep, cardHeight: CGFloat) -> Bool {
        let pad = Self.pad
        let bandTop = max(0, Int((pad + cardHeight - NotchLayout.cardPadding).rounded()))
        let bandBottom = min(rep.pixelsHigh, Int((pad + cardHeight).rounded()))
        let minX = Int(pad.rounded())
        let maxX = min(rep.pixelsWide, Int((pad + NotchLayout.cardMinWidth).rounded()))
        for x in stride(from: minX, to: maxX, by: 2) {
            for y in stride(from: bandTop, to: bandBottom, by: 1) {
                if isPainted(rep.colorAt(x: x, y: y)) { return false }
            }
        }
        return true
    }

    func testALaunchReadyCardPaints() {
        let cell = DrawerCell(id: "launch", title: "Finder", icon: .symbol("macwindow"),
                              kind: .launch, state: .ready)
        guard let (rep, _) = render(cell) else { return XCTFail("no image") }
        XCTAssertGreaterThan(inkedFraction(rep), 0.01)
    }

    func testAToggleOnCardPaints() {
        let cell = DrawerCell(id: "toggle", title: "Wi-Fi", icon: .symbol("wifi"),
                              kind: .toggle, state: .on)
        guard let (rep, _) = render(cell) else { return XCTFail("no image") }
        XCTAssertGreaterThan(inkedFraction(rep), 0.01)
    }

    func testALevelCardPaints() {
        let cell = DrawerCell(id: "level", title: "Volume", icon: .symbol("speaker.wave.2.fill"),
                              kind: .level, state: .level(0.62))
        guard let (rep, _) = render(cell) else { return XCTFail("no image") }
        XCTAssertGreaterThan(inkedFraction(rep), 0.01)
    }

    func testAnArmedCardPaints() {
        let cell = DrawerCell(id: "action:emptyTrash", title: "Empty Trash", icon: .symbol("trash.fill"),
                              kind: .fire(destructive: true), state: .armed)
        guard let (rep, _) = render(cell) else { return XCTFail("no image") }
        XCTAssertGreaterThan(inkedFraction(rep), 0.01)
    }

    func testAFailedCardWithASentencePaints() {
        let cell = DrawerCell(id: "failed", title: "Screenshot", icon: .symbol("camera.viewfinder"),
                              kind: .toggle, state: .failed("Couldn't open"))
        guard let (rep, _) = render(cell) else { return XCTFail("no image") }
        XCTAssertGreaterThan(inkedFraction(rep), 0.01)
    }

    func testAFailedCardsRenderedHeightMatchesTheBudget() {
        let cell = DrawerCell(id: "failed", title: "Screenshot", icon: .symbol("camera.viewfinder"),
                              kind: .toggle, state: .failed("Couldn't open"))
        guard let (_, height) = render(cell) else { return XCTFail("no image") }
        XCTAssertEqual(height, NotchLayout.cardHeight(for: .toggle, state: .failed("Couldn't open")), accuracy: 1)
    }

    /// The longest sentence the card ever shows. It has to wrap to no more
    /// than the two lines the height budget reserves, or it bleeds into the
    /// padding band the card's own foot is supposed to keep clear.
    func testTheAutomationSentenceFitsInTwoLines() {
        let sentence = "Allow Drawer in System Settings > Privacy & Security > Automation"
        let cell = DrawerCell(id: "failed-automation", title: "Screen Recording", icon: .symbol("camera.viewfinder"),
                              kind: .toggle, state: .failed(sentence))
        guard let (rep, height) = render(cell) else { return XCTFail("no image") }
        XCTAssertTrue(bottomBandIsUnpainted(rep, cardHeight: height),
                      "the Automation sentence spilled past its two-line budget")
    }

    func testALevelCardIsTallerThanAToggleCardBySliderRoom() {
        let toggle = DrawerCell(id: "t", title: "Wi-Fi", icon: .symbol("wifi"), kind: .toggle, state: .on)
        let level = DrawerCell(id: "l", title: "Volume", icon: .symbol("speaker.wave.2.fill"),
                               kind: .level, state: .level(0.5))
        guard let (_, toggleHeight) = render(toggle), let (_, levelHeight) = render(level) else {
            return XCTFail("no image")
        }
        XCTAssertEqual(levelHeight - toggleHeight,
                       NotchLayout.headerToBlock + NotchLayout.sliderHitDepth, accuracy: 1)
    }

    func testPopoverIsOneClosedOutlineForEveryDirection() {
        for direction in [NotchEdge.TooltipDirection.leading, .trailing] {
            let rect = CGRect(x: 0, y: 0, width: 240, height: 110)
            let path = PopoverShape(direction: direction).path(in: rect)
            var moves = 0
            var closes = 0
            var curves = 0
            path.forEach {
                switch $0 {
                case .move: moves += 1
                case .closeSubpath: closes += 1
                case .curve, .quadCurve: curves += 1
                default: break
                }
            }
            XCTAssertEqual(moves, 1)
            XCTAssertEqual(closes, 1)
            XCTAssertGreaterThanOrEqual(curves, 7)
            XCTAssertTrue(rect.insetBy(dx: -0.01, dy: -0.01).contains(path.boundingRect))
            XCTAssertTrue(path.contains(CGPoint(x: rect.midX, y: rect.midY)))
        }
    }

    func testPointerMovesWithinRoundedBodyEnds() {
        // A leading card sits to the left of the notch, so its pointer is on
        // the card's right edge and slides along it. An offset past the end
        // is clamped to the rounded corner rather than running off it.
        let rect = CGRect(x: 0, y: 0, width: 240, height: 110)
        let path = PopoverShape(direction: .leading, pointerOffset: -1000).path(in: rect)
        let spine = rect.maxX - NotchLayout.pointerDepth / 2
        let target = NotchLayout.cardCorner + NotchLayout.pointerBase / 2
        XCTAssertTrue(path.contains(CGPoint(x: spine, y: target)))
        XCTAssertFalse(path.contains(CGPoint(x: spine, y: rect.midY)))
    }

    func testTheShadowBandOutsideTheFreeEdgeIsPainted() {
        let cell = DrawerCell(id: "toggle", title: "Wi-Fi", icon: .symbol("wifi"), kind: .toggle, state: .on)
        guard let (rep, height) = render(cell) else { return XCTFail("no image") }
        let pad = Int(Self.pad)

        // A few points outside the free left edge, well inside the shadow's
        // own margin: the blur should still be putting down some alpha.
        var sawShadow = false
        for y in stride(from: pad + 10, to: pad + Int(height) - 10, by: 4) {
            guard let colour = rep.colorAt(x: pad - 6, y: y) else { continue }
            if colour.alphaComponent > 0 { sawShadow = true; break }
        }
        XCTAssertTrue(sawShadow, "the shadow should reach past the free edge")
    }
}
