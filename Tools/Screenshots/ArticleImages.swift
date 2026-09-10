import AppKit

/// Composites the README images: a drawn backdrop, the real window captures
/// placed on it, and a screen bezel around the ones that are supposed to read
/// as a display edge.
///
/// Run as `swift Tools/Screenshots/ArticleImages.swift <raw dir> <out dir>`,
/// where the raw directory holds the captures `make-docs-images.sh` takes.
///
/// Three things here are load bearing and easy to get wrong.
///
/// The backdrop is written per pixel rather than drawn with `NSGradient`.
/// Three gaussians over normalised coordinates give a wash with no banding
/// and no visible centre, which a radial gradient does not.
///
/// The 144 DPI tag is the last thing that happens to a bitmap. Setting the
/// size before drawing makes the context one point per two pixels while every
/// rectangle below is still in pixels, so the whole composite doubles and runs
/// off the canvas.
///
/// A capture carries its own shadow as transparent margin, so the alpha
/// bounding box is what has to be measured to place anything against an edge.
/// The window's own rounded corners and traffic lights come from the window
/// server; nothing here draws a window frame.

// MARK: - Canvas

func bitmap(_ width: Int, _ height: Int) -> NSBitmapImageRep {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { fatalError("cannot allocate a \(width) by \(height) bitmap") }
    rep.size = NSSize(width: width, height: height)
    return rep
}

/// Paper. One flat colour behind everything, because a picture with a wash
/// behind the window and a second wash inside the screen has two gradients
/// competing in it and neither wins. The settings windows are dark, so they
/// cut out against this without needing a border drawn around them.
func ground(_ width: Int, _ height: Int) -> NSBitmapImageRep {
    let result = bitmap(width, height)
    guard let data = result.bitmapData else { fatalError("no bitmap data") }
    let paper: [UInt8] = [242, 242, 244, 255]
    for y in 0..<height {
        for x in 0..<width {
            let offset = y * result.bytesPerRow + x * 4
            for channel in 0..<4 { data[offset + channel] = paper[channel] }
        }
    }
    return result
}

func withCanvas(_ canvas: NSBitmapImageRep, _ draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)
    draw()
    NSGraphicsContext.restoreGraphicsState()
}

/// Half the pixel count means 144 DPI in the encoded file, so the PNG reads as
/// a retina asset rather than a very large 1x one. Restored afterwards so any
/// later drawing stays in pixel coordinates.
func write(_ image: NSBitmapImageRep, to url: URL) {
    let pixels = NSSize(width: image.pixelsWide, height: image.pixelsHigh)
    image.size = NSSize(width: pixels.width / 2, height: pixels.height / 2)
    guard let png = image.representation(using: .png, properties: [:]) else {
        fatalError("cannot encode \(url.lastPathComponent)")
    }
    try! png.write(to: url)
    image.size = pixels
    print("\(url.lastPathComponent) \(image.pixelsWide)x\(image.pixelsHigh)")
}

// MARK: - Captures

struct Capture {
    let image: NSImage
    /// The part of the capture that is not fully transparent, in pixels with
    /// the origin at the top left, which is how a capture is read.
    let content: CGRect
    let size: CGSize
}

func load(_ url: URL) -> Capture {
    guard let data = try? Data(contentsOf: url), let rep = NSBitmapImageRep(data: data) else {
        fatalError("cannot read \(url.path)")
    }
    let width = rep.pixelsWide
    let height = rep.pixelsHigh
    rep.size = NSSize(width: width, height: height)
    var minX = width, minY = height, maxX = 0, maxY = 0
    if let data = rep.bitmapData {
        let samples = rep.samplesPerPixel
        for y in 0..<height {
            for x in 0..<width {
                let alpha = data[y * rep.bytesPerRow + x * samples + 3]
                if alpha > 8 {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        }
    }
    let image = NSImage(size: NSSize(width: width, height: height))
    image.addRepresentation(rep)
    let content = minX <= maxX
        ? CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        : CGRect(x: 0, y: 0, width: width, height: height)
    return Capture(image: image, content: content, size: CGSize(width: width, height: height))
}

/// Draws a capture so that its content box lands exactly on `target`, which
/// is given with the origin at the top left. The transparent shadow margin
/// hangs outside `target`, which is what makes a window sit against an edge
/// rather than a shadow's width away from it.
func place(_ capture: Capture, content target: CGRect, canvasHeight: CGFloat, interpolation: NSImageInterpolation = .none) {
    let scale = target.width / capture.content.width
    let full = CGRect(x: target.minX - capture.content.minX * scale,
                      y: target.minY - capture.content.minY * scale,
                      width: capture.size.width * scale,
                      height: capture.size.height * scale)
    let flipped = CGRect(x: full.minX, y: canvasHeight - full.maxY, width: full.width, height: full.height)
    NSGraphicsContext.current?.imageInterpolation = interpolation
    capture.image.draw(in: flipped, from: .zero, operation: .sourceOver, fraction: 1)
}

// MARK: - The bezel

/// A display. The rectangle is given in canvas coordinates with the origin at
/// the top left, and it is allowed to run off the canvas: for the close up the
/// screen bleeds past three sides so only the edge the drawer lives on is in
/// frame, because a whole laptop in the picture makes the product a detail in
/// it.
///
/// Returns the inner screen rectangle for placing a capture against.
@discardableResult
func screen(_ outer: CGRect, canvas: CGSize, radius: CGFloat = 46) -> CGRect {
    let inner = outer.insetBy(dx: 20, dy: 20)
    let flip = { (rect: CGRect) in CGRect(x: rect.minX, y: canvas.height - rect.maxY, width: rect.width, height: rect.height) }

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.32)
    shadow.shadowBlurRadius = 70
    shadow.shadowOffset = NSSize(width: -16, height: -22)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor(srgbRed: 0.086, green: 0.086, blue: 0.098, alpha: 1).setFill()
    NSBezierPath(roundedRect: flip(outer), xRadius: radius, yRadius: radius).fill()
    NSGraphicsContext.restoreGraphicsState()

    // One flat colour on the screen. Not white and not black, both measured:
    // a near white screen makes the picture read as a blank page with a bar
    // stuck to it, and a near black one makes the drawer disappear, since the
    // product and the screen behind it are then the same colour.
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: flip(inner), xRadius: radius - 16, yRadius: radius - 16).setClip()
    NSColor(srgbRed: 0.294, green: 0.329, blue: 0.651, alpha: 1).setFill()
    flip(inner).fill()
    NSGraphicsContext.restoreGraphicsState()

    // The hairline where the glass meets the bezel, which is the only thing
    // keeping two dark tones apart at this size.
    NSColor.white.withAlphaComponent(0.14).setStroke()
    let edge = NSBezierPath(roundedRect: flip(inner).insetBy(dx: -1, dy: -1), xRadius: radius - 15, yRadius: radius - 15)
    edge.lineWidth = 2
    edge.stroke()
    return inner
}

// MARK: - Type

func draw(_ text: String, at point: CGPoint, canvasHeight: CGFloat, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
    ]
    let string = text as NSString
    let measured = string.size(withAttributes: attributes)
    string.draw(at: NSPoint(x: point.x, y: canvasHeight - point.y - measured.height), withAttributes: attributes)
}

// MARK: - Run

let arguments = CommandLine.arguments
let rawDirectory = URL(fileURLWithPath: arguments.count > 1 ? arguments[1] : "artifacts/article/raw", isDirectory: true)
let outDirectory = URL(fileURLWithPath: arguments.count > 2 ? arguments[2] : "docs/images", isDirectory: true)
try? FileManager.default.createDirectory(at: outDirectory, withIntermediateDirectories: true)

func raw(_ name: String) -> Capture { load(rawDirectory.appendingPathComponent(name + ".png")) }

let ink = NSColor(srgbRed: 0.16, green: 0.19, blue: 0.26, alpha: 1)
let inkSoft = NSColor(srgbRed: 0.35, green: 0.39, blue: 0.47, alpha: 1)

// The drawer on a screen edge, close up. The screen runs off three sides, so
// the picture is the edge rather than a laptop with something small on it.
do {
    let canvas = CGSize(width: 1240, height: 1240)
    let image = ground(Int(canvas.width), Int(canvas.height))
    let drawer = raw("drawer")
    withCanvas(image) {
        let inner = screen(CGRect(x: -420, y: -300, width: 1560, height: 1840), canvas: canvas)
        let height = min(drawer.content.height, canvas.height - 150)
        let scale = height / drawer.content.height
        let width = drawer.content.width * scale
        place(drawer, content: CGRect(x: inner.maxX - width, y: (canvas.height - height) / 2,
                                      width: width, height: height),
              canvasHeight: canvas.height, interpolation: .high)
    }
    write(image, to: outDirectory.appendingPathComponent("drawer.png"))
}

// The hero. One desktop: the wallpaper, the window where a drawer gets
// filled, and the drawer itself on the right edge where it lives. The title
// sits on the wallpaper, which is what a magazine would do with the same
// picture, rather than beside it where it would compete with the product.
do {
    let canvas = CGSize(width: 2400, height: 1600)
    let image = ground(Int(canvas.width), Int(canvas.height))
    let drawer = raw("drawer")
    let settings = raw("settings-items")
    withCanvas(image) {
        // 2240 by 1440 is 16 by 10, which is the shape of every Mac display.
        let inner = screen(CGRect(x: 80, y: 80, width: 2240, height: 1440), canvas: canvas, radius: 52)
        let height = inner.height - 130
        let scale = height / drawer.content.height
        let width = drawer.content.width * scale
        place(drawer, content: CGRect(x: inner.maxX - width, y: inner.midY - height / 2,
                                      width: width, height: height),
              canvasHeight: canvas.height, interpolation: .high)

        let settingsScale = 0.46
        let settingsWidth = settings.content.width * settingsScale
        let settingsHeight = settings.content.height * settingsScale
        place(settings, content: CGRect(x: inner.minX + 150, y: inner.maxY - settingsHeight - 90,
                                        width: settingsWidth, height: settingsHeight),
              canvasHeight: canvas.height, interpolation: .high)

        if let icon = NSImage(contentsOf: rawDirectory.appendingPathComponent("logo.png")) {
            NSGraphicsContext.current?.imageInterpolation = .high
            icon.draw(in: CGRect(x: inner.minX + 150, y: canvas.height - inner.minY - 232, width: 112, height: 112))
        }
        draw("Drawer", at: CGPoint(x: inner.minX + 296, y: inner.minY + 122), canvasHeight: canvas.height,
             size: 66, weight: .semibold, color: .white)
        draw("Quick actions at the edge of the screen.", at: CGPoint(x: inner.minX + 300, y: inner.minY + 214),
             canvasHeight: canvas.height, size: 29, weight: .regular,
             color: NSColor.white.withAlphaComponent(0.76))
    }
    write(image, to: outDirectory.appendingPathComponent("hero.png"))
}

// The windows, at their own size on the ground. No bezel: these are windows,
// not a screen edge, and a frame around a frame reads as a mistake.
for (name, canvasSize) in [("settings-items", CGSize(width: 2400, height: 2500)),
                           ("settings-appearance", CGSize(width: 2400, height: 2500)),
                           ("guide", CGSize(width: 1700, height: 1560))] {
    let capture = raw(name)
    let image = ground(Int(canvasSize.width), Int(canvasSize.height))
    withCanvas(image) {
        place(capture, content: CGRect(x: (canvasSize.width - capture.content.width) / 2,
                                       y: (canvasSize.height - capture.content.height) / 2,
                                       width: capture.content.width, height: capture.content.height),
              canvasHeight: canvasSize.height)
    }
    write(image, to: outDirectory.appendingPathComponent(name + ".png"))
}
