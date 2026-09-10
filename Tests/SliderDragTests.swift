import XCTest
@testable import Drawer

final class SliderDragTests: XCTestCase {
    func testValueAtBandStartIsZero() {
        let slider = SliderDrag(band: CGRect(x: 0, y: 0, width: 100, height: 20), horizontal: true, isActive: false)
        XCTAssertEqual(slider.value(at: CGPoint(x: 0, y: 10)), 0)
    }

    func testValueAtBandEndIsOne() {
        let slider = SliderDrag(band: CGRect(x: 0, y: 0, width: 100, height: 20), horizontal: true, isActive: false)
        XCTAssertEqual(slider.value(at: CGPoint(x: 100, y: 10)), 1)
    }

    func testOutsideTheBandClamps() {
        let slider = SliderDrag(band: CGRect(x: 0, y: 0, width: 100, height: 20), horizontal: true, isActive: false)
        XCTAssertEqual(slider.value(at: CGPoint(x: -50, y: 10)), 0)
        XCTAssertEqual(slider.value(at: CGPoint(x: 500, y: 10)), 1)
    }

    func testVerticalMapsBottomToTop() {
        let slider = SliderDrag(band: CGRect(x: 0, y: 0, width: 20, height: 100), horizontal: false, isActive: false)
        XCTAssertEqual(slider.value(at: CGPoint(x: 10, y: 0)), 0, "the bottom of the band should read as 0")
        XCTAssertEqual(slider.value(at: CGPoint(x: 10, y: 100)), 1, "the top of the band should read as 1")
    }

    func testContains() {
        let slider = SliderDrag(band: CGRect(x: 0, y: 0, width: 100, height: 20), horizontal: true, isActive: false)
        XCTAssertTrue(slider.contains(CGPoint(x: 50, y: 10)))
        XCTAssertFalse(slider.contains(CGPoint(x: 150, y: 10)))
    }
}
