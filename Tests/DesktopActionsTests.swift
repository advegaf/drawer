import AppKit
import XCTest
@testable import Drawer

@MainActor
final class DesktopActionsTests: XCTestCase {
    private let success = ShellResult(status: 0, stdout: "", stderr: "")

    private func writeImage(to path: String) throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for x in 0..<2 {
            for y in 0..<2 { bitmap.setColor(.red, atX: x, y: y) }
        }
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }

    func testModesUseNativeArgumentsWithoutDeadlineAndCopyValidOutputOnce() async throws {
        let cases: [(ScreenshotCapture.Mode, [String])] = [(.selection, ["-i"]), (.window, ["-iw"]), (.display, ["-m"])]
        for (mode, flags) in cases {
            let capture = ScreenshotCapture()
            var copies = 0
            var directory: URL?
            try await capture.capture(mode, run: { executable, arguments, timeout in
                XCTAssertTrue(capture.isRunning)
                XCTAssertEqual(executable, "/usr/sbin/screencapture")
                XCTAssertEqual(Array(arguments.dropLast()), flags)
                XCTAssertNil(timeout)
                let output = try XCTUnwrap(arguments.last)
                directory = URL(fileURLWithPath: output).deletingLastPathComponent()
                XCTAssertEqual(URL(fileURLWithPath: output).lastPathComponent, "capture.png")
                let permissions = try FileManager.default.attributesOfItem(atPath: directory!.path)[.posixPermissions] as? NSNumber
                XCTAssertEqual(permissions?.intValue, 0o700)
                try self.writeImage(to: output)
                return self.success
            }, copy: { image in
                copies += 1
                XCTAssertTrue(image.isValid)
                return true
            })
            XCTAssertEqual(copies, 1)
            XCTAssertFalse(capture.isRunning)
            XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(directory).path))
        }
    }

    func testSuccessfulExitWithoutArtifactIsQuietCancellation() async throws {
        let capture = ScreenshotCapture()
        var output: String?
        try await capture.capture(.window, run: { _, arguments, _ in
            output = arguments.last
            return self.success
        }, copy: { _ in XCTFail("cancellation must not change the clipboard"); return true })
        XCTAssertFalse(capture.isRunning)
        let directory = URL(fileURLWithPath: try XCTUnwrap(output)).deletingLastPathComponent()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testFailedExitNeverCopiesEvenWhenArtifactExists() async throws {
        let capture = ScreenshotCapture()
        var output: String?
        do {
            try await capture.capture(.selection, run: { _, arguments, _ in
                output = try XCTUnwrap(arguments.last)
                try self.writeImage(to: output!)
                return ShellResult(status: 1, stdout: "", stderr: "Permission denied")
            }, copy: { _ in XCTFail("failed capture must not copy"); return true })
            XCTFail("expected capture failure")
        } catch {
            XCTAssertEqual(error as? ActionError, .failed("Permission denied"))
        }
        XCTAssertFalse(capture.isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: URL(fileURLWithPath: try XCTUnwrap(output)).deletingLastPathComponent().path))
    }

    func testInvalidArtifactFailsWithoutCopyingAndCleansUp() async throws {
        let capture = ScreenshotCapture()
        var directory: URL?
        do {
            try await capture.capture(.display, run: { _, arguments, _ in
                let output = URL(fileURLWithPath: try XCTUnwrap(arguments.last))
                directory = output.deletingLastPathComponent()
                try Data("invalid image".utf8).write(to: output)
                return self.success
            }, copy: { _ in XCTFail("invalid image must not copy"); return true })
            XCTFail("expected invalid image failure")
        } catch {
            XCTAssertEqual(error as? ActionError, .failed("The screenshot could not be read."))
        }
        XCTAssertFalse(capture.isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(directory).path))
    }

    func testClipboardFailureIsReportedAndCleansUp() async throws {
        let capture = ScreenshotCapture()
        var directory: URL?
        do {
            try await capture.capture(.display, run: { _, arguments, _ in
                let output = try XCTUnwrap(arguments.last)
                directory = URL(fileURLWithPath: output).deletingLastPathComponent()
                try self.writeImage(to: output)
                return self.success
            }, copy: { _ in false })
            XCTFail("expected clipboard failure")
        } catch {
            XCTAssertEqual(error as? ActionError, .failed("The screenshot could not be copied."))
        }
        XCTAssertFalse(capture.isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(directory).path))
    }

    func testSimultaneousCaptureStartsOnlyOnePicker() async throws {
        let capture = ScreenshotCapture()
        let started = expectation(description: "first picker started")
        var pending: CheckedContinuation<ShellResult, Error>?
        var runs = 0
        let first = Task {
            try await capture.capture(.selection, run: { _, _, _ in
                runs += 1
                return try await withCheckedThrowingContinuation { continuation in
                    pending = continuation
                    started.fulfill()
                }
            }, copy: { _ in XCTFail("no artifact"); return true })
        }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(capture.isRunning)
        try await capture.capture(.window, run: { _, _, _ in
            runs += 1
            return self.success
        }, copy: { _ in XCTFail("second capture must not copy"); return true })
        XCTAssertEqual(runs, 1)
        pending?.resume(returning: success)
        try await first.value
        XCTAssertFalse(capture.isRunning)
    }

    func testRunnerCancellationCleansUpAndAllowsNextCapture() async throws {
        let capture = ScreenshotCapture()
        var directory: URL?
        do {
            try await capture.capture(.window, run: { _, arguments, _ in
                directory = URL(fileURLWithPath: try XCTUnwrap(arguments.last)).deletingLastPathComponent()
                throw CancellationError()
            }, copy: { _ in XCTFail("cancelled task must not copy"); return true })
            XCTFail("expected cancellation")
        } catch is CancellationError {}
        XCTAssertFalse(capture.isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(directory).path))
        var retried = false
        try await capture.capture(.window, run: { _, _, _ in retried = true; return self.success })
        XCTAssertTrue(retried)
    }
}
