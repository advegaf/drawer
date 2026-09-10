import AppKit

/// Captures one app window to a file, and refuses to write a file that is
/// not that window.
///
/// Run as `swift Scripts/window-shot.swift <ownerName> <out.png>`.
///
/// Two traps on this machine, both of which produced screenshots that
/// looked plausible until they were measured.
///
/// `screencapture -l` sizes its output from `CGWindowListCopyWindowInfo`
/// bounds, and those bounds are a stale stub rect for a freshly created
/// Settings window until something makes the window server redraw it.
/// Activating the app is what refreshes them: raising the window,
/// minimising and restoring it, and moving it through Accessibility were
/// all tried and none of them worked. So this activates, waits, reads the
/// real frame through Accessibility, and matches that against the window
/// list to pick the number to capture.
///
/// The other trap is the workaround for the first one. A region capture
/// (`-R`) is geometrically honest but photographs whatever is on that
/// patch of screen, which twice caught what was behind the window. It is
/// not used here at all: `-l` composites the one window and can catch
/// nothing else.
func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

guard CommandLine.arguments.count > 2 else {
    fail("usage: window-shot.swift <ownerName> <out.png> [--shadow]")
}
let owner = CommandLine.arguments[1]
let out = CommandLine.arguments[2]
/// With the window's own drop shadow, which is what a screenshot for a page
/// wants: the capture then measures larger than the window by however wide
/// the shadow's margin is, so the size check below allows for that rather
/// than demanding an exact match.
let keepsShadow = CommandLine.arguments.contains("--shadow")

guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == owner }) else {
    fail("no running app named \(owner)")
}
let element = AXUIElementCreateApplication(app.processIdentifier)

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

func frame(_ window: AXUIElement) -> (title: String, rect: CGRect) {
    var origin = CGPoint.zero
    var size = CGSize.zero
    if let value = attribute(window, kAXPositionAttribute) { AXValueGetValue(value as! AXValue, .cgPoint, &origin) }
    if let value = attribute(window, kAXSizeAttribute) { AXValueGetValue(value as! AXValue, .cgSize, &size) }
    return ((attribute(window, kAXTitleAttribute) as? String) ?? "", CGRect(origin: origin, size: size))
}

/// The largest titled window. Settings is the only window this app titles;
/// the notch panel has none, which is the same test `window-id.swift` makes
/// by looking at the window layer.
func settingsFrame() -> CGRect? {
    guard let windows = attribute(element, kAXWindowsAttribute) as? [AXUIElement] else { return nil }
    return windows.map(frame).filter { !$0.title.isEmpty }
        .max { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }?.rect
}

func windowNumber(matching wanted: CGRect) -> Int? {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: AnyObject]] ?? []
    for window in list where (window[kCGWindowOwnerName as String] as? String) == owner {
        guard (window[kCGWindowLayer as String] as? Int ?? -1) != 25,
              let bounds = window[kCGWindowBounds as String],
              let rect = CGRect(dictionaryRepresentation: bounds as! CFDictionary),
              abs(rect.width - wanted.width) <= 2, abs(rect.height - wanted.height) <= 2,
              let number = window[kCGWindowNumber as String] as? Int
        else { continue }
        return number
    }
    return nil
}

let scale = NSScreen.main?.backingScaleFactor ?? 2

for attempt in 1...3 {
    app.activate(options: [.activateAllWindows])
    usleep(useconds_t(600_000 * attempt))
    guard let wanted = settingsFrame() else {
        fail("no titled window for \(owner); Accessibility permission may be missing for this terminal")
    }
    guard let number = windowNumber(matching: wanted) else { continue }

    let capture = Process()
    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    capture.arguments = keepsShadow ? ["-x", "-l", "\(number)", out] : ["-x", "-o", "-l", "\(number)", out]
    try? capture.run()
    capture.waitUntilExit()

    guard let data = try? Data(contentsOf: URL(fileURLWithPath: out)),
          let rep = NSBitmapImageRep(data: data) else { continue }
    let slack: CGFloat = keepsShadow ? 400 : 4
    if CGFloat(rep.pixelsWide) >= wanted.width * scale - 4,
       CGFloat(rep.pixelsWide) <= wanted.width * scale + slack,
       CGFloat(rep.pixelsHigh) >= wanted.height * scale - 4,
       CGFloat(rep.pixelsHigh) <= wanted.height * scale + slack {
        print(out)
        exit(0)
    }
    // The stale bounds case: the file is the right window squeezed into
    // the wrong size. It is deleted rather than left for someone to read
    // as evidence.
    try? FileManager.default.removeItem(atPath: out)
}

fail("could not capture a file matching the \(owner) window; nothing written")
