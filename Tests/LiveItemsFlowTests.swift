import AppKit
import SwiftUI
import XCTest
@testable import Drawer

/// Cells that arrive after the panel is already on screen, the way pinned
/// items do once they resolve, must open the notch to their full length.
@MainActor
final class LiveItemsFlowTests: XCTestCase {
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
                if let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.1 { inked += 1 }
            }
        }
        return total == 0 ? 0 : Double(inked) / Double(total)
    }

    func testCellsArrivingAfterShowFillTheOpenNotch() {
        let controller = NotchWindowController()
        controller.show()
        defer { controller.stop() }
        controller.apply(.alwaysShow)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        controller.model.replaceCells(Fixtures.cells(8))
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))

        XCTAssertTrue(controller.model.isExpanded)
        XCTAssertEqual(controller.model.cells.count, 8)
        XCTAssertEqual(controller.model.notchLength,
                       controller.model.shapeLength(cellCount: 8), accuracy: 0.5)
        XCTAssertEqual(controller.panelFrameForTesting?.height ?? 0,
                       controller.model.panelSize(cellCount: 8).height, accuracy: 1)

        guard let rep = render(controller.model) else { return XCTFail("no render") }
        let ink = inkedFraction(rep)
        XCTAssertGreaterThan(ink, 0.15, "eight open cells should paint a long body, got \(ink)")
    }
}
