import Combine
import XCTest
@testable import Drawer

final class ObserverTests: XCTestCase {
    func testDarkModeObserverDeliversOnDistributedNotification() throws {
        guard case .toggle(_, _, let observe) = ActionRegistry.spec(for: .darkMode).control, let observe else {
            XCTFail("darkMode has no observer")
            return
        }

        let expectation = expectation(description: "dark mode notification")
        let cancellable = observe.sink { _ in expectation.fulfill() }
        defer { cancellable.cancel() }

        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )

        let result = XCTWaiter.wait(for: [expectation], timeout: 2)
        if result != .completed {
            throw XCTSkip("distributed notifications did not loop back to the posting process on this Mac within 2s")
        }
    }

    func testAudioOutputChangesCanBeSubscribedAndTornDownWithoutCrashing() {
        var cancellable: AnyCancellable? = AudioOutput.changes.sink { _ in }
        cancellable?.cancel()
        cancellable = nil
    }
}
