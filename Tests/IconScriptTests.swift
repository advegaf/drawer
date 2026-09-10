import AppKit
import XCTest
@testable import Drawer

/// Runs the real `make-icon.swift` against a scratch copy of the real
/// `Contents.json` and the real exports, so a change to the script, the
/// JSON or the export set is caught here rather than only by eye after
/// `make icon`.
final class IconScriptTests: XCTestCase {
    private struct IconImage: Decodable {
        let size: String
        let scale: String
        let filename: String

        var pixelSide: Int? {
            guard let points = Double(size.split(separator: "x").first ?? ""),
                  let factor = Double(scale.split(separator: "x").first ?? "")
            else { return nil }
            return Int((points * factor).rounded())
        }
    }
    private struct Contents: Decodable { let images: [IconImage] }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Fills a scratch appiconset from the real exports and hands back the
    /// directory, so each test reads what `make icon` would have written.
    private func fillScratchIconSet() async throws -> URL {
        let scriptURL = repoRoot.appendingPathComponent("Scripts/make-icon.swift")
        let sourceJSON = repoRoot
            .appendingPathComponent("Sources/Assets.xcassets/AppIcon.appiconset/Contents.json")
        let exports = repoRoot.appendingPathComponent("Design/icon/exports")

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("icon-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.copyItem(at: sourceJSON, to: tempDir.appendingPathComponent("Contents.json"))

        let result = try await Shell.run(
            "/usr/bin/env", ["swift", scriptURL.path, tempDir.path, exports.path], timeout: 60
        )
        XCTAssertEqual(result.status, 0, "make-icon.swift failed: \(result.stderr)")
        return tempDir
    }

    func testMakeIconWritesEveryEntryAtItsExactPixelSize() async throws {
        let tempDir = try await fillScratchIconSet()
        let sourceJSON = repoRoot
            .appendingPathComponent("Sources/Assets.xcassets/AppIcon.appiconset/Contents.json")
        let contents = try JSONDecoder().decode(Contents.self, from: Data(contentsOf: sourceJSON))
        for image in contents.images {
            guard let expected = image.pixelSide else {
                XCTFail("could not read a pixel size for \(image.filename)")
                continue
            }
            let fileURL = tempDir.appendingPathComponent(image.filename)
            guard let fileData = try? Data(contentsOf: fileURL), let rep = NSBitmapImageRep(data: fileData) else {
                XCTFail("\(image.filename) was not written")
                continue
            }
            XCTAssertEqual(rep.pixelsWide, expected, "\(image.filename) width")
            XCTAssertEqual(rep.pixelsHigh, expected, "\(image.filename) height")
        }
    }

    /// Every entry is the export byte for byte.
    ///
    /// This is the whole point of the script: the artwork is drawn one
    /// size at a time, so 16 points is not the 1024 shrunk, and anything
    /// that resamples on the way in loses that. A rendered file would
    /// still be the right number of pixels and would still pass the test
    /// above.
    func testMakeIconCopiesTheExportRatherThanRedrawingIt() async throws {
        let tempDir = try await fillScratchIconSet()
        let exports = repoRoot.appendingPathComponent("Design/icon/exports")
        let byLength = Dictionary(grouping: try FileManager.default
            .contentsOfDirectory(at: exports, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "png" }) { (try? Data(contentsOf: $0))?.count ?? 0 }

        let sourceJSON = repoRoot
            .appendingPathComponent("Sources/Assets.xcassets/AppIcon.appiconset/Contents.json")
        let contents = try JSONDecoder().decode(Contents.self, from: Data(contentsOf: sourceJSON))
        for image in contents.images {
            let written = try Data(contentsOf: tempDir.appendingPathComponent(image.filename))
            let candidates = byLength[written.count] ?? []
            let identical = candidates.contains { (try? Data(contentsOf: $0)) == written }
            XCTAssertTrue(identical, "\(image.filename) is not one of the exports byte for byte")
        }
    }

    /// The glyph reaches the edges of its square.
    ///
    /// The old script inset every drawing to 80 percent of its canvas,
    /// which is why the icon read small everywhere it was drawn small: in
    /// the Dock, and at 24 points in the settings sidebar. The exports are
    /// already padded the way an app icon should be.
    func testTheIconFillsItsSquare() async throws {
        let tempDir = try await fillScratchIconSet()
        let fileURL = tempDir.appendingPathComponent("icon_32x32@2x.png")
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: fileURL)))

        // 64 pixels. The rounded square's own corners are clear, so the
        // edges are read at the middle of each side rather than at (2, 2),
        // which is where the old 80 percent inset used to show up.
        let leftEdge = try XCTUnwrap(rep.colorAt(x: 1, y: rep.pixelsHigh / 2))
        let rightEdge = try XCTUnwrap(rep.colorAt(x: rep.pixelsWide - 2, y: rep.pixelsHigh / 2))
        XCTAssertEqual(leftEdge.alphaComponent, 1, accuracy: 0.05, "the glyph stops short of the left edge")
        XCTAssertEqual(rightEdge.alphaComponent, 1, accuracy: 0.05, "the glyph stops short of the right edge")
    }
}
