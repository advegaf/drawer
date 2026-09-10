import XCTest
@testable import Drawer

final class AppleScriptTests: XCTestCase {
    func testErrorNumberMinus1743MapsToAutomationDenied() {
        let info: NSDictionary = [NSAppleScript.errorNumber: -1743]
        XCTAssertEqual(AppleScript.error(from: info), .automationDenied)
    }

    func testAnotherErrorNumberMapsToFailedWithTheMessage() {
        let info: NSDictionary = [
            NSAppleScript.errorNumber: -10000,
            NSAppleScript.errorMessage: "Application isn't running.",
        ]
        XCTAssertEqual(AppleScript.error(from: info), .failed("Application isn't running."))
    }
}
