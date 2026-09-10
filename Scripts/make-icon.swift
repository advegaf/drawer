import AppKit
import Foundation

/// Fills an `.appiconset` from a directory of per size exports.
///
/// A copy, not a render. The exports are drawn one size at a time rather
/// than scaled from a single master: the 16 point artwork is not the 1024
/// shrunk, and a script that resamples throws that work away. Every macOS
/// entry has an export at the same point size and scale, except the 1024
/// which serves `512x512@2x`.
/// Run as `swift Scripts/make-icon.swift <appiconset directory> <exports directory>`.
func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

guard CommandLine.arguments.count > 2 else {
    fail("usage: make-icon.swift <appiconset directory> <exports directory>")
}
let dir = URL(fileURLWithPath: CommandLine.arguments[1])
let exportsDir = URL(fileURLWithPath: CommandLine.arguments[2])
let contentsURL = dir.appendingPathComponent("Contents.json")

guard let data = try? Data(contentsOf: contentsURL) else {
    fail("no Contents.json at \(contentsURL.path)")
}

struct IconImage: Decodable {
    let size: String
    let scale: String
    let filename: String
}
struct Contents: Decodable {
    let images: [IconImage]
}

guard let contents = try? JSONDecoder().decode(Contents.self, from: data) else {
    fail("could not read \(contentsURL.path)")
}

guard let exports = try? FileManager.default.contentsOfDirectory(at: exportsDir, includingPropertiesForKeys: nil)
    .filter({ $0.pathExtension.lowercased() == "png" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }),
      !exports.isEmpty else {
    fail("no PNG exports in \(exportsDir.path)")
}

func pixelSide(size: String, scale: String) -> Int? {
    guard let points = Double(size.split(separator: "x").first ?? ""),
          let factor = Double(scale.split(separator: "x").first ?? "") else { return nil }
    return Int((points * factor).rounded())
}

func pixelSide(of url: URL) -> Int? {
    guard let data = try? Data(contentsOf: url), let rep = NSBitmapImageRep(data: data),
          rep.pixelsWide == rep.pixelsHigh else { return nil }
    return rep.pixelsWide
}

let sides = Dictionary(uniqueKeysWithValues: exports.compactMap { url in pixelSide(of: url).map { (url, $0) } })

/// The export for one catalogue entry: the file whose own pixels match,
/// preferring one named for the same point size and scale. Two exports can
/// be the same number of pixels and not the same picture, so which one is
/// picked is not arbitrary: `icon_16x16@2x` and `icon_32x32.png` are both
/// 32 pixels and take different artwork.
func export(for image: IconImage) -> URL? {
    guard let side = pixelSide(size: image.size, scale: image.scale) else { return nil }
    let matching = exports.filter { sides[$0] == side }
    let named = "\(image.size)@\(image.scale)"
    return matching.first { $0.lastPathComponent.contains(named) } ?? matching.first
}

for image in contents.images {
    guard let source = export(for: image) else {
        fail("no export in \(exportsDir.path) for \(image.filename) (\(image.size) at \(image.scale))")
    }
    let destination = dir.appendingPathComponent(image.filename)
    try? FileManager.default.removeItem(at: destination)
    do {
        try FileManager.default.copyItem(at: source, to: destination)
    } catch {
        fail("could not write \(image.filename): \(error.localizedDescription)")
    }
    print("\(image.filename) <- \(source.lastPathComponent)")
}
