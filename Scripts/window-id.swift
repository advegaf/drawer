import CoreGraphics
import Foundation

/// Prints the window number of the on-screen window owned by the given
/// process name, for `screencapture -l`. Prefers the status bar layer (25)
/// the notch panel uses; falls back to the owner's largest window so the
/// script still finds something when the panel is not up yet. An optional
/// second argument narrows the search: "settings" picks the largest window
/// that is *not* on the status bar layer (the notch panel always is; the
/// Settings window never is), which is what stays correct as its title bar
/// text changes with the selected sidebar page; anything else is matched
/// as an exact window title.
func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

guard CommandLine.arguments.count > 1 else {
    fail("usage: window-id.swift <ownerName> [windowName|settings]")
}
let owner = CommandLine.arguments[1]
let selector = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : nil

guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
    as? [[String: AnyObject]] else {
    fail("could not read the on-screen window list")
}

let owned = windows.filter { ($0[kCGWindowOwnerName as String] as? String) == owner }
guard !owned.isEmpty else { fail("no on-screen window owned by \(owner)") }

func layer(_ window: [String: AnyObject]) -> Int { window[kCGWindowLayer as String] as? Int ?? -1 }

func width(_ window: [String: AnyObject]) -> CGFloat {
    guard let bounds = window[kCGWindowBounds as String] as? [String: Any],
          let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return 0 }
    return rect.width
}

func area(_ window: [String: AnyObject]) -> CGFloat {
    guard let bounds = window[kCGWindowBounds as String] as? [String: Any],
          let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return 0 }
    return rect.width * rect.height
}


let candidates: [[String: AnyObject]]
switch selector {
case "settings":
    // Not just "off the status bar layer": the app can have a small
    // window of its own up at the same time, and one capture that
    // caught a 184 by 250 point one instead of Settings is what put
    // this size floor here. Settings never opens under 900 points
    // wide, so anything narrow is not it.
    candidates = owned.filter { layer($0) != 25 && width($0) >= 400 }
    guard !candidates.isEmpty else {
        fail("no on-screen window owned by \(owner) that looks like Settings")
    }
case let windowName?:
    candidates = owned.filter { ($0[kCGWindowName as String] as? String) == windowName }
    guard !candidates.isEmpty else { fail("no on-screen window owned by \(owner) named \(windowName)") }
default:
    candidates = owned
}

let statusBarWindow = candidates.first { layer($0) == 25 }
let chosen = statusBarWindow ?? candidates.max { area($0) < area($1) }

guard let window = chosen, let number = window[kCGWindowNumber as String] as? Int else {
    fail("no window number for \(owner)")
}
print(number)
