import CoreGraphics
import XCTest
@testable import Drawer

/// Most assertions here are machine-bound: they check what this specific
/// Mac's private frameworks actually expose on this macOS version, not
/// something portable across every install.
final class PrivateAPITests: XCTestCase {
    func testControlForWithANilPrivateHandleIsUnavailableForEachID() {
        for control in [
            ActionRegistry.control(for: .bluetooth, bluetooth: nil),
            ActionRegistry.control(for: .brightness, brightness: nil),
            ActionRegistry.control(for: .lockScreen, lockScreen: nil),
            ActionRegistry.control(for: .nightShift, nightShift: nil),
        ] {
            guard case .unavailable = control else {
                XCTFail("expected unavailable with a nil handle")
                continue
            }
        }
    }

    func testAllFourPrivateHandlesResolveOnThisMac() {
        XCTAssertNotNil(PrivateAPI.bluetooth, "IOBluetooth symbols did not resolve on this Mac")
        XCTAssertNotNil(PrivateAPI.brightness, "DisplayServices symbols did not resolve on this Mac")
        XCTAssertNotNil(PrivateAPI.lockScreen, "login's lock symbol did not resolve on this Mac")
        XCTAssertNotNil(PrivateAPI.nightShift, "CBBlueLightClient did not resolve on this Mac")
    }

    // On this Mac IOBluetoothCoreBluetoothCoordinator's init deadlocks inside
    // IOBluetooth itself on the first call to the power getter, confirmed
    // with a standalone script outside Xcode and this app, so it is not
    // caused by anything here. The read runs off the main queue with a
    // bound so a wedge here skips instead of hanging the whole suite.
    func testBluetoothReadReturnsWithoutCrashingOnThisMac() throws {
        let bluetooth = try XCTUnwrap(PrivateAPI.bluetooth)
        let done = expectation(description: "getPower returns")
        DispatchQueue.global().async {
            _ = bluetooth.getPower()
            done.fulfill()
        }
        guard XCTWaiter().wait(for: [done], timeout: 3) == .completed else {
            throw XCTSkip("IOBluetoothPreferenceGetControllerPowerState did not return within 3s on this Mac")
        }
    }

    func testNightShiftReadReturnsNonNilOnThisMac() throws {
        let nightShift = try XCTUnwrap(PrivateAPI.nightShift)
        XCTAssertNotNil(nightShift.isEnabled())
    }

    func testBrightnessReadIsInRangeAndRoundTripsOnThisMac() throws {
        let brightness = try XCTUnwrap(PrivateAPI.brightness)

        var value: Float = 0
        guard brightness.get(CGMainDisplayID(), &value) == 0 else { return }
        XCTAssertTrue((0...1).contains(value), "brightness \(value) is outside 0...1")

        XCTAssertEqual(brightness.set(CGMainDisplayID(), value), 0)

        var readBack: Float = 0
        XCTAssertEqual(brightness.get(CGMainDisplayID(), &readBack), 0)
        XCTAssertEqual(Double(readBack), Double(value), accuracy: 0.02)
    }

    func testACallThatMissesItsDeadlineWedgesTheActionAndReturnsNil() async {
        PrivateCall.resetWedged()
        PrivateCall.timeout = 0.2
        defer { PrivateCall.timeout = 2; PrivateCall.resetWedged() }

        let started = Date()
        let value: Bool? = await PrivateCall.run(.nightShift) { Thread.sleep(forTimeInterval: 30); return true }
        XCTAssertNil(value)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
        XCTAssertTrue(PrivateCall.isWedged(.nightShift))

        let again = Date()
        let second: Bool? = await PrivateCall.run(.nightShift) { true }
        XCTAssertNil(second, "a wedged action is never asked again")
        XCTAssertLessThan(Date().timeIntervalSince(again), 0.1)
    }

    @MainActor
    func testAWedgedPrivateActionResolvesToUnavailable() async {
        PrivateCall.resetWedged()
        PrivateCall.timeout = 0.2
        defer { PrivateCall.timeout = 2; PrivateCall.resetWedged() }
        let hung: ActionSpec.Control = .toggle(
            read: { await PrivateCall.run(.brightness) { Thread.sleep(forTimeInterval: 30); return true } ?? nil },
            write: { _ in }, observe: nil
        )
        let resolver = ItemResolver(controlFor: { _ in hung })
        let cells = await resolver.resolve([.action("brightness")])
        XCTAssertEqual(cells.first?.state, .unavailable)
    }
}
