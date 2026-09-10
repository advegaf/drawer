import AppKit

/// Draws the disk image's background: the thing a person sees for the two
/// seconds between double clicking the download and dragging the app across.
///
/// Drawn here rather than exported from a design file, so it can be reasoned
/// about and changed with the rest of the code. The picture is the product:
/// a screen edge on the right with the drawer's own pill unfolded against it,
/// and the two slots Finder puts the app and the Applications folder in.
///
/// Run as `swift Tools/Release/InstallerBackground.swift <output directory>`.
/// Writes `background.tiff` at 144 DPI (the 660 by 400 point canvas at 1320
/// by 800 pixels) plus standard and Retina PNGs for looking at.

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Design/Installer",
                 isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let width = 660.0
let height = 400.0
/// Where Finder puts the two icons, in its own coordinates (down from the
/// top). `dmg-layout.py` writes exactly these.
let appSlot = CGPoint(x: 220, y: 270)
let applicationsSlot = CGPoint(x: 440, y: 270)
/// The same points with y measured up from the bottom, which is how a
/// graphics context works.
func flipped(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x, y: height - point.y) }

func draw(into context: CGContext) {
    // Light, and not by preference. Finder draws the two icon labels in its
    // dark ink whatever the image behind them is, so a dark installer reads
    // as two unlabelled icons: measured on a first attempt, the words
    // "Drawer" and "Applications" came out near black on near black. The
    // product's own black bar is the thing that stands out here instead.
    let colours = [
        NSColor(srgbRed: 0.98, green: 0.98, blue: 0.98, alpha: 1).cgColor,
        NSColor(srgbRed: 0.91, green: 0.91, blue: 0.93, alpha: 1).cgColor,
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colours,
                                 locations: [0, 1]) {
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: height),
                                   end: CGPoint(x: 0, y: 0), options: [])
    }

    // The product itself, at the right edge where it lives on a real
    // screen. A capture of the running app rather than a drawing of it:
    // the shape, the ring weights, the glow on a cell that is on and the
    // way the bar meets the bezel are all things the app already draws,
    // and a hand drawn copy of them was close enough to look wrong.
    //
    // `Design/Installer/drawer-art.png` comes from
    // `screencapture -l` on a `DRAWER_DEMO=1 DRAWER_OPEN=1` launch, so it
    // is the window server's own render, shadow and all.
    let artURL = URL(fileURLWithPath: "Design/Installer/drawer-art.png")
    if let art = NSImage(contentsOf: artURL) {
        let target = 322.0
        let aspect = art.size.width / max(art.size.height, 1)
        let drawn = CGSize(width: target * aspect, height: target)
        // Flush with the canvas edge rather than hanging over it: the
        // capture's own right margin is the bezel, and pushing it further
        // clipped the settings orb's arc at the bottom of the bar.
        let rect = NSRect(x: width - drawn.width, y: (height - drawn.height) / 2,
                          width: drawn.width, height: drawn.height)
        NSGraphicsContext.current?.imageInterpolation = .high
        art.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    }

    // No plate or glow behind the icon slots. On a light ground the soft
    // white circle the dark version used reads as a grey square someone
    // forgot to delete, and Finder already draws a shadow under each icon.

    // The arrow between the slots. Short, and stopping well clear of both
    // 96 point icons.
    let arrowY = flipped(appSlot).y
    let start = appSlot.x + 62
    let end = applicationsSlot.x - 62
    context.setStrokeColor(NSColor.black.withAlphaComponent(0.28).cgColor)
    context.setLineWidth(2)
    context.setLineCap(.round)
    context.move(to: CGPoint(x: start, y: arrowY))
    context.addLine(to: CGPoint(x: end - 9, y: arrowY))
    context.strokePath()
    context.setFillColor(NSColor.black.withAlphaComponent(0.28).cgColor)
    context.move(to: CGPoint(x: end, y: arrowY))
    context.addLine(to: CGPoint(x: end - 12, y: arrowY + 7))
    context.addLine(to: CGPoint(x: end - 12, y: arrowY - 7))
    context.closePath()
    context.fillPath()
}

func drawText() {
    let title = "Drag Drawer into Applications" as NSString
    let subtitle = "It lives on the edge of your screen." as NSString
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    title.draw(in: NSRect(x: 60, y: height - 96, width: 540, height: 40), withAttributes: [
        .font: NSFont.systemFont(ofSize: 24, weight: .semibold),
        .foregroundColor: NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1),
        .paragraphStyle: paragraph,
    ])
    subtitle.draw(in: NSRect(x: 60, y: height - 126, width: 540, height: 26), withAttributes: [
        .font: NSFont.systemFont(ofSize: 14, weight: .regular),
        .foregroundColor: NSColor(srgbRed: 0.38, green: 0.38, blue: 0.41, alpha: 1),
        .paragraphStyle: paragraph,
    ])
}

var representations: [NSBitmapImageRep] = []
for pixelsWide in [660, 1320, 2640] {
    let scale = Double(pixelsWide) / width
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: Int((height * scale).rounded()),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { fatalError("could not make a bitmap") }
    // Left at its pixel size while drawing. Setting the point size first
    // makes the context scale itself, and the `scaleBy` below then scales it
    // twice: the first attempt drew a 660 point canvas four times too large.
    bitmap.size = NSSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let context = NSGraphicsContext.current!.cgContext
    context.scaleBy(x: scale, y: scale)
    draw(into: context)
    drawText()
    NSGraphicsContext.restoreGraphicsState()
    representations.append(bitmap)
    let name = pixelsWide == 660 ? "background.png" : pixelsWide == 1320 ? "background@2x.png" : "background@4x.png"
    try bitmap.representation(using: .png, properties: [:])!
        .write(to: output.appendingPathComponent(name))
}

// Finder reads one file. The 1320 by 800 representation at 144 DPI is the
// 660 by 400 point canvas the layout is written for.
let retina = representations[1]
retina.size = NSSize(width: width, height: height)
let tiff = NSImage(size: NSSize(width: width, height: height))
tiff.addRepresentation(retina)
try tiff.tiffRepresentation!.write(to: output.appendingPathComponent("background.tiff"))
print("installer background written to \(output.path)")
