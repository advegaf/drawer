import XCTest
@testable import Drawer

final class WheelStepperTests: XCTestCase {
    func testMomentumIsIgnoredAndTouchesNothing() {
        var stepper = WheelStepper(stepThreshold: 10)
        XCTAssertEqual(stepper.feed(delta: 100, precise: true, momentum: true), 0)
        XCTAssertEqual(stepper.feed(delta: -100, precise: false, momentum: true), 0)
    }

    func testPreciseDeltasAccumulateAndKeepTheRemainder() {
        var stepper = WheelStepper(stepThreshold: 10)
        XCTAssertEqual(stepper.feed(delta: 4, precise: true, momentum: false), 0, "4 of 10 should not step yet")
        XCTAssertEqual(stepper.feed(delta: 4, precise: true, momentum: false), 0, "8 of 10 should still not step")
        XCTAssertEqual(stepper.feed(delta: 4, precise: true, momentum: false), 1, "12 should step once, leaving 2")
        XCTAssertEqual(stepper.feed(delta: 4, precise: true, momentum: false), 0, "6 should not step again yet")
        XCTAssertEqual(stepper.feed(delta: 4, precise: true, momentum: false), 1, "10 should step once more")
    }

    func testAWheelNotchStepsOncePerEventWithNoAccumulation() {
        var stepper = WheelStepper(stepThreshold: 10)
        XCTAssertEqual(stepper.feed(delta: 1, precise: false, momentum: false), 1)
        XCTAssertEqual(stepper.feed(delta: 50, precise: false, momentum: false), 1, "a notch never accumulates")
        XCTAssertEqual(stepper.feed(delta: -1, precise: false, momentum: false), -1)
    }

    func testClampSetsAndClearsOverscrolled() {
        var stepper = WheelStepper(stepThreshold: 10)
        XCTAssertEqual(stepper.clamp(5, within: 0...3), 3)
        XCTAssertTrue(stepper.overscrolled)
        XCTAssertEqual(stepper.clamp(2, within: 0...3), 2)
        XCTAssertFalse(stepper.overscrolled)
    }

    func testResetEmptiesTheAccumulator() {
        var stepper = WheelStepper(stepThreshold: 10)
        _ = stepper.feed(delta: 8, precise: true, momentum: false)
        stepper.reset()
        XCTAssertEqual(stepper.feed(delta: 4, precise: true, momentum: false), 0, "the old 8 should not still be there")
    }
}
