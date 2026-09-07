import SwiftUI
import XCTest
@testable import Drawer

/// The state vocabulary and the empty-list fallback, rendered for real and
/// checked for ink rather than trusted on layout maths alone.
@MainActor
final class CellRenderTests: XCTestCase {
    func testSolidChromePreservesBlackAndAddsSoftDepthToLightFill() throws {
        func bitmap(finish: Theme.BarStyle, backdrop: Color) throws -> NSBitmapImageRep {
            let view = DrawerChrome(shape: RoundedRectangle(cornerRadius: 10), theme: Theme(bar: finish),
                                    size: CGSize(width: 40, height: 40))
                .frame(width: 100, height: 100)
                .background(backdrop)
                .environment(\.colorScheme, .light)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            return NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
        }
        func brightness(_ bitmap: NSBitmapImageRep, x: Int, y: Int) throws -> CGFloat {
            let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
            return (color.redComponent + color.greenComponent + color.blueComponent) / 3
        }
        let oledOnWhite = try bitmap(finish: .oled, backdrop: .white)
        XCTAssertLessThan(try brightness(oledOnWhite, x: 50, y: 50), 0.01)
        let light = try bitmap(finish: .light, backdrop: .white)
        XCTAssertGreaterThan(try brightness(light, x: 50, y: 50), 0.9)
        XCTAssertLessThan(try brightness(light, x: 28, y: 50), 0.99)
        XCTAssertGreaterThan(try brightness(light, x: 28, y: 50), 0.8)
        XCTAssertGreaterThan(try brightness(light, x: 10, y: 50), try brightness(light, x: 28, y: 50))
    }

    func testOLEDFlaresHaveNoAuthoredLightFringeOnAnyEdge() throws {
        for edge in NotchEdge.allCases {
            let size = CGSize(width: 50, height: 150)
            let view = DrawerChrome(shape: SideNotchShape(edge: edge), theme: Theme(bar: .oled), size: size)
                .padding(24)
                .background(Color.black)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
            var brightest: CGFloat = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                    brightest = max(brightest, color.redComponent, color.greenComponent, color.blueComponent)
                }
            }
            XCTAssertLessThan(brightest, 0.01, "OLED gained a light fringe at \(edge)")
        }
    }

    private struct ObservedCell: View {
        @ObservedObject var model: NotchViewModel
        var body: some View {
            DrawerCellView(cell: model.cells[0], theme: Theme(accent: .custom(hex: 0x0071ff), bar: .oled))
                .padding(8).background(Color.black)
        }
    }

    func testToggleRingKeepsItsSettledStateThroughFirstAndLaterPendingChanges() {
        let model = NotchViewModel()
        model.cells = [DrawerCell(id: "action:darkMode", title: "Dark mode", icon: .symbol("circle.lefthalf.filled"),
                                  kind: .toggle, state: .on)]
        let host = NSHostingView(rootView: ObservedCell(model: model))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 80, height: 80),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        func ringPixels(after state: CellState) -> Int {
            model.updateCell(id: "action:darkMode", state: state)
            RunLoop.current.run(until: Date().addingTimeInterval(0.22))
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                XCTFail("No cell bitmap")
                return -1
            }
            host.cacheDisplay(in: host.bounds, to: rep)
            var count = 0
            for y in 0..<rep.pixelsHigh {
                for x in 0..<rep.pixelsWide {
                    guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    if color.blueComponent > 0.5 && color.redComponent < 0.25 { count += 1 }
                }
            }
            return count
        }

        let on = ringPixels(after: .on)
        XCTAssertGreaterThan(on, 20)
        XCTAssertEqual(ringPixels(after: .pending), on)
        XCTAssertEqual(ringPixels(after: .off), 0)
        XCTAssertEqual(ringPixels(after: .pending), 0)
        XCTAssertEqual(ringPixels(after: .on), on)
        XCTAssertEqual(ringPixels(after: .pending), on)
    }

    func testRingAndSliderHaveNoExtraOutline() {
        let theme = Theme(accent: .custom(hex: 0), bar: .oled)
        let ring = CellRing(fraction: 0.5, tint: .black, theme: theme)
        let slider = LevelBar(fraction: 0.5, fill: .black, track: Palette.track(theme), theme: theme)
            .frame(width: 160)
        XCTAssertEqual(brightPixels(ring), 0)
        XCTAssertEqual(brightPixels(slider), 0)
    }

    func testSettingsArcBandKeepsItsCenterAndThicknessForEveryEdge() {
        for edge in NotchEdge.allCases {
            for convex in [false, true] {
                for radius in [CGFloat(18.525), NotchLayout.orbArcRadius] {
                    let width = NotchLayout.orbStroke
                    let diameter = radius * 2 + width
                    let rect = CGRect(x: 0, y: 0, width: diameter, height: diameter)
                    let trim = SettingsOrb.restingTrim(for: edge, convex: convex)
                    let path = SettingsArcBand(trim: trim, width: width).path(in: rect)
                    let angle = (trim.lowerBound + trim.upperBound) * .pi
                    func point(_ distance: CGFloat) -> CGPoint {
                        CGPoint(x: rect.midX + cos(angle) * distance, y: rect.midY + sin(angle) * distance)
                    }
                    XCTAssertTrue(path.contains(point(radius)))
                    XCTAssertFalse(path.contains(point(radius - width)))
                    XCTAssertFalse(path.contains(point(radius + width)))
                    let renderer = ImageRenderer(content: SettingsArcBand(trim: trim, width: width)
                        .fill(Color.white).frame(width: diameter, height: diameter))
                    renderer.scale = 2
                    guard let image = renderer.cgImage else { return XCTFail("no arc image") }
                    let pixels = NSBitmapImageRep(cgImage: image)
                    // Sample an area, avoiding a winding test whose horizontal ray
                    // can coincide with the stroked arc's floating-point endpoint.
                    for x in (pixels.pixelsWide / 2 - 2)...(pixels.pixelsWide / 2 + 2) {
                        for y in (pixels.pixelsHigh / 2 - 2)...(pixels.pixelsHigh / 2 + 2) {
                            XCTAssertEqual(pixels.colorAt(x: x, y: y)?.alphaComponent ?? 1, 0,
                                           "arc painted its center: \(edge), convex \(convex), radius \(radius)")
                        }
                    }
                    XCTAssertTrue(rect.insetBy(dx: -0.01, dy: -0.01).contains(path.boundingRect))
                }
            }
        }
    }

    private func brightPixels(_ view: some View) -> Int {
        let renderer = ImageRenderer(content: view.padding(4).background(Color.black))
        renderer.scale = 2
        guard let image = renderer.cgImage else { XCTFail("no image"); return 0 }
        return brightPixels(NSBitmapImageRep(cgImage: image))
    }

    private func brightPixels(_ rep: NSBitmapImageRep) -> Int {
        var count = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                if let color = rep.colorAt(x: x, y: y), color.redComponent > 0.5 { count += 1 }
            }
        }
        return count
    }

    private func render(_ model: NotchViewModel) -> NSBitmapImageRep? {
        let size = model.panelSize
        let renderer = ImageRenderer(
            content: NotchRootView(model: model).frame(width: size.width, height: size.height)
        )
        renderer.scale = 1
        guard let image = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: image)
    }

    private func inkedFraction(_ rep: NSBitmapImageRep) -> Double {
        var inked = 0, total = 0
        for x in stride(from: 0, to: rep.pixelsWide, by: 3) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 3) {
                total += 1
                if let colour = rep.colorAt(x: x, y: y), colour.alphaComponent > 0.1 { inked += 1 }
            }
        }
        return total == 0 ? 0 : Double(inked) / Double(total)
    }

    func testTheWholeVocabularyRendersOnTheRightEdge() {
        let model = NotchViewModel()
        model.edge = .right
        model.isExpanded = true
        model.cells = Fixtures.vocabulary()

        guard let rep = render(model) else {
            XCTFail("the vocabulary produced no image at all")
            return
        }
        XCTAssertGreaterThan(inkedFraction(rep), 0.15, "eleven open cells should paint a lot of ink")
    }

    func testAnEmptyListRendersTheAddCell() {
        let model = NotchViewModel()
        model.edge = .right
        model.isExpanded = true
        model.replaceCells([])

        XCTAssertEqual(model.cells, [DrawerCell.add])

        guard let rep = render(model) else {
            XCTFail("the add cell produced no image at all")
            return
        }
        XCTAssertGreaterThan(inkedFraction(rep), 0.02, "the add cell should still paint something")
    }
}
