import XCTest
@testable import Drawer

@MainActor
final class ShortcutsCatalogTests: XCTestCase {
    func testParseSplitsTrimsDropsEmptyKeepsOrderAndDuplicates() {
        XCTAssertEqual(ShortcutsCatalog.parse("  Focus  \n\nFocus\n   \nShare Screen\n"), ["Focus", "Focus", "Share Screen"])
    }

    func testOverlappingReloadsHaveOneLoaderAndClearLoading() async {
        let started = expectation(description: "loader started")
        var continuation: CheckedContinuation<ShellResult, Error>?
        var calls = 0
        let catalog = ShortcutsCatalog {
            calls += 1
            return try await withCheckedThrowingContinuation {
                continuation = $0
                started.fulfill()
            }
        }
        let request = Task { await catalog.reload() }
        await fulfillment(of: [started])
        XCTAssertTrue(catalog.isLoading)
        await catalog.reload()
        XCTAssertEqual(calls, 1)
        continuation?.resume(returning: ShellResult(status: 0, stdout: "Focus\n", stderr: ""))
        await request.value
        XCTAssertEqual(catalog.names, ["Focus"])
        XCTAssertFalse(catalog.isLoading)
        XCTAssertFalse(catalog.failed)
    }

    func testNonzeroExitPreservesNamesAndLaterRetrySucceeds() async {
        var result = ShellResult(status: 0, stdout: "Original", stderr: "")
        let catalog = ShortcutsCatalog { result }
        await catalog.reload()
        result = ShellResult(status: 1, stdout: "partial", stderr: "failure")
        await catalog.reload()
        XCTAssertEqual(catalog.names, ["Original"])
        XCTAssertTrue(catalog.failed)
        XCTAssertFalse(catalog.isLoading)
        result = ShellResult(status: 0, stdout: "Updated", stderr: "")
        await catalog.reload()
        XCTAssertEqual(catalog.names, ["Updated"])
        XCTAssertFalse(catalog.failed)
        XCTAssertFalse(catalog.isLoading)
    }

    func testThrownFailurePreservesNamesAndCanRetry() async {
        var shouldThrow = false
        let catalog = ShortcutsCatalog {
            if shouldThrow { throw ShellError.timedOut }
            return ShellResult(status: 0, stdout: "Focus", stderr: "")
        }
        await catalog.reload()
        shouldThrow = true
        await catalog.reload()
        XCTAssertEqual(catalog.names, ["Focus"])
        XCTAssertTrue(catalog.failed)
        XCTAssertFalse(catalog.isLoading)
        shouldThrow = false
        await catalog.reload()
        XCTAssertFalse(catalog.failed)
        XCTAssertFalse(catalog.isLoading)
    }

    func testInitialFailureKeepsNamesUnknown() async {
        let catalog = ShortcutsCatalog { throw ShellError.timedOut }
        await catalog.reload()
        XCTAssertNil(catalog.names)
        XCTAssertTrue(catalog.failed)
        XCTAssertFalse(catalog.isLoading)
    }
}
