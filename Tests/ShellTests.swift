import XCTest
@testable import Drawer

final class ShellTests: XCTestCase {
    func testRunPassesArgvUnchanged() async throws {
        let value = "hello world café 🎉"
        let result = try await Shell.run("/usr/bin/printf", ["%s|", value])
        XCTAssertEqual(result.stdout, value + "|")
    }

    func testNonZeroExitYieldsStatusAndStderr() async throws {
        let falseResult = try await Shell.run("/usr/bin/false", [])
        XCTAssertEqual(falseResult.status, 1)

        let envResult = try await Shell.run("/usr/bin/env", ["definitely-not-a-real-command-xyz"])
        XCTAssertNotEqual(envResult.status, 0)
        XCTAssertFalse(envResult.stderr.isEmpty)
    }

    func testTimeoutThrowsWithinAboutASecond() async throws {
        let start = Date()
        do {
            _ = try await Shell.run("/bin/sleep", ["5"], timeout: 0.5)
            XCTFail("expected a timeout")
        } catch ShellError.timedOut {
            XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
        }
    }

    func testOutputLargerThanPipeCapacityIsCollectedCompletely() async throws {
        let result = try await Shell.run("/usr/bin/jot", ["20000"], timeout: 3)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout.split(separator: "\n").count, 20_000)
        XCTAssertTrue(result.stdout.hasSuffix("20000\n"))
        XCTAssertGreaterThan(result.stdout.utf8.count, 65_536)
    }

    func testTimeoutKillsProcessThatIgnoresTermination() async throws {
        let start = Date()
        do {
            _ = try await Shell.run("/bin/sh", ["-c", "trap '' TERM; while :; do :; done"], timeout: 0.1)
            XCTFail("expected timeout")
        } catch ShellError.timedOut {
            XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
        }
    }

    func testNilTimeoutAllowsProcessToFinishNormally() async throws {
        let result = try await Shell.run("/bin/sh", ["-c", "sleep 0.1; printf done"], timeout: nil)
        XCTAssertEqual(result, ShellResult(status: 0, stdout: "done", stderr: ""))
    }

    func testCancellationBeforeRunDoesNotLaunchChild() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("launched")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await Shell.run("/usr/bin/touch", [marker.path], timeout: nil)
        }
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testCancellationDuringRunTerminatesChildAndReturnsOnce() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("started")
        let task = Task {
            try await Shell.run("/bin/sh", ["-c", "printf started > \"$1\"; exec /bin/sleep 30", "cancellation-test", marker.path], timeout: nil)
        }
        let deadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: marker.path), Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let didStart = FileManager.default.fileExists(atPath: marker.path)
        let cancelledAt = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {}
        XCTAssertTrue(didStart, "child must launch before this cancellation check")
        XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 1.5)
    }

    func testLaunchFailureResumesEachCallerOnceWithoutWaitingForTimeout() async throws {
        let start = Date()
        for _ in 0..<3 {
            do {
                _ = try await Shell.run("/definitely-missing-drawer-test-executable", [], timeout: nil)
                XCTFail("expected launch failure")
            } catch {
                XCTAssertFalse(error is CancellationError)
                XCTAssertFalse(error is ShellError)
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
        let following = try await Shell.run("/usr/bin/true", [], timeout: nil)
        XCTAssertEqual(following.status, 0)
    }

    func testLaunchDetachedCallsOnExitOnMain() throws {
        let expectation = expectation(description: "onExit")
        try Shell.launchDetached("/usr/bin/true", []) { result in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(result.status, 0)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
    }

    func testClassifyMapsStatusZeroToOk() {
        XCTAssertEqual(Shell.classify(ShellResult(status: 0, stdout: "", stderr: "")), .ok)
    }

    func testClassifyMapsAFindShortcutComplaintToNotFound() {
        let result = ShellResult(status: 1, stdout: "", stderr: "Couldn't find shortcut \"X\"")
        XCTAssertEqual(Shell.classify(result), .notFound)
    }

    func testClassifyMapsOtherStderrToFailed() {
        let result = ShellResult(status: 1, stdout: "", stderr: "boom")
        XCTAssertEqual(Shell.classify(result), .failed("boom"))
    }

    func testShortcutsRunArgumentsKeepsALeadingDashNameLiteral() {
        XCTAssertEqual(Shell.shortcutsRunArguments(name: "-weird"), ["run", "--", "-weird"])
    }
}
