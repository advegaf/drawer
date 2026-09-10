import AppKit
import Combine
import CoreGraphics
import CoreWLAN
import Foundation
import IOKit.pwr_mgt

enum ActionID: String, Codable, CaseIterable {
    case wifi, bluetooth, darkMode, nightShift, stageManager, mute, volume, brightness,
         keepAwake, lockScreen, sleep, emptyTrash, screenshot, captureWindow, captureDisplay,
         missionControl, showDesktop, startScreenSaver,
         quitApp, hideOthers, forceQuit, sleepDisplays, ejectDisks, restart, shutDown, logOut,
         desktopIcons, hiddenFiles, dockAutohide, menuBarAutohide, batteryPercentage,
         relaunchFinder, relaunchDock,
         playPause, nextTrack, previousTrack, micMute, keyboardCleaning, plainPaste, screenRecording,
         focus,
         dockMagnification, dockRecents, minimizeIntoIcon, clickWallpaper,
         finderPathBar, finderStatusBar, fileExtensions, screenshotThumbnail, clockSeconds,
         trueTone, micLevel
}

enum ActionError: Error, Equatable {
    case unavailable
    case notApplied
    case failed(String)
}

struct ActionSpec {
    let id: ActionID
    let title: String
    let symbol: String
    /// A one-line description for the Items page's Actions section.
    let detail: String
    let control: Control

    enum Control {
        case toggle(read: @Sendable () async -> Bool?,
                    write: @Sendable (Bool) async throws -> Void,
                    observe: AnyPublisher<Bool, Never>?)
        case level(read: @Sendable () async -> Double?,
                   write: @Sendable (Double) async throws -> Void,
                   observe: AnyPublisher<Double, Never>?)
        case fire(run: @Sendable () async throws -> Void, destructive: Bool)
        case unavailable
    }
}

enum ActionRegistry {
    /// One row per action: title, symbol and the cell `Kind` it resolves to
    /// once it has a real control. Every `ActionID` case needs an entry here;
    /// `RegistryTests` checks that this stays true.
    private struct Row {
        let id: ActionID
        let title: String
        let symbol: String
        let detail: String
        let kind: Kind
    }

    private static let rows: [Row] = [
        Row(id: .wifi, title: "Wi-Fi", symbol: "wifi",
            detail: "Turn Wi-Fi on or off", kind: .toggle),
        // "bluetooth" is not an SF Symbol name on this Mac.
        Row(id: .bluetooth, title: "Bluetooth", symbol: "dot.radiowaves.left.and.right",
            detail: "Turn Bluetooth on or off", kind: .toggle),
        Row(id: .darkMode, title: "Dark mode", symbol: "circle.lefthalf.filled",
            detail: "Switch the system appearance", kind: .toggle),
        Row(id: .nightShift, title: "Night Shift", symbol: "moon.haze.fill",
            detail: "Warm the display at night", kind: .toggle),
        Row(id: .stageManager, title: "Stage Manager", symbol: "squares.leading.rectangle",
            detail: "Turn Stage Manager on or off", kind: .toggle),
        Row(id: .mute, title: "Mute", symbol: "speaker.slash.fill",
            detail: "Silence the output device", kind: .toggle),
        Row(id: .volume, title: "Volume", symbol: "speaker.wave.2.fill",
            detail: "Output volume, dragged in the card", kind: .level),
        Row(id: .brightness, title: "Brightness", symbol: "sun.max.fill",
            detail: "Display brightness, dragged in the card", kind: .level),
        Row(id: .keepAwake, title: "Keep awake", symbol: "cup.and.saucer.fill",
            detail: "Stop the Mac from sleeping", kind: .toggle),
        Row(id: .lockScreen, title: "Lock screen", symbol: "lock.fill",
            detail: "Lock the screen now", kind: .fire(destructive: false)),
        Row(id: .sleep, title: "Sleep", symbol: "powersleep",
            detail: "Put the Mac to sleep", kind: .fire(destructive: false)),
        Row(id: .emptyTrash, title: "Empty Trash", symbol: "trash.fill",
            detail: "Empty the Trash after a second click", kind: .fire(destructive: true)),
        Row(id: .screenshot, title: "Screenshot", symbol: "camera.viewfinder",
            detail: "Select a region or window to copy to the clipboard", kind: .fire(destructive: false)),
        Row(id: .captureWindow, title: "Capture Window", symbol: "macwindow",
            detail: "Choose a window to copy to the clipboard", kind: .fire(destructive: false)),
        Row(id: .captureDisplay, title: "Capture Display", symbol: "display",
            detail: "Copy the main display to the clipboard", kind: .fire(destructive: false)),
        Row(id: .missionControl, title: "Mission Control", symbol: "rectangle.3.group",
            detail: "See your open windows and desktops", kind: .fire(destructive: false)),
        Row(id: .showDesktop, title: "Show Desktop", symbol: "desktopcomputer",
            detail: "Move windows aside to reveal the desktop", kind: .fire(destructive: false)),
        Row(id: .startScreenSaver, title: "Start Screen Saver", symbol: "sparkles.tv",
            detail: "Start your current screen saver", kind: .fire(destructive: false)),

        // Apps and windows.
        Row(id: .quitApp, title: "Quit App", symbol: "xmark.app",
            detail: "Quit whatever was in front", kind: .fire(destructive: false)),
        Row(id: .hideOthers, title: "Hide Others", symbol: "rectangle.stack",
            detail: "Hide every app but the one in front", kind: .fire(destructive: false)),
        Row(id: .forceQuit, title: "Force Quit", symbol: "exclamationmark.octagon",
            detail: "Force quit the app in front after a second click", kind: .fire(destructive: true)),
        Row(id: .sleepDisplays, title: "Sleep Displays", symbol: "display.trianglebadge.exclamationmark",
            detail: "Turn the screen off without sleeping", kind: .fire(destructive: false)),

        // The four that cannot be taken back.
        Row(id: .ejectDisks, title: "Eject Disks", symbol: "eject.fill",
            detail: "Eject every removable disk after a second click", kind: .fire(destructive: true)),
        Row(id: .restart, title: "Restart", symbol: "arrow.clockwise.circle",
            detail: "Restart the Mac after a second click", kind: .fire(destructive: true)),
        Row(id: .shutDown, title: "Shut Down", symbol: "power.circle",
            detail: "Shut the Mac down after a second click", kind: .fire(destructive: true)),
        Row(id: .logOut, title: "Log Out", symbol: "person.crop.circle.badge.xmark",
            detail: "Log out after a second click", kind: .fire(destructive: true)),

        // Switches that live in another app's preferences.
        Row(id: .desktopIcons, title: "Desktop Icons", symbol: "menucard",
            detail: "Show or hide everything on the desktop", kind: .toggle),
        Row(id: .hiddenFiles, title: "Hidden Files", symbol: "eye.trianglebadge.exclamationmark",
            detail: "Show dotfiles in the Finder", kind: .toggle),
        Row(id: .dockAutohide, title: "Hide Dock", symbol: "dock.rectangle",
            detail: "Hide the Dock until you point at it", kind: .toggle),
        Row(id: .menuBarAutohide, title: "Hide Menu Bar", symbol: "menubar.rectangle",
            detail: "Hide the menu bar until you point at it", kind: .toggle),
        Row(id: .batteryPercentage, title: "Battery Percent", symbol: "battery.75percent",
            detail: "Show the battery percentage in the menu bar", kind: .toggle),
        Row(id: .relaunchFinder, title: "Relaunch Finder", symbol: "arrow.triangle.2.circlepath",
            detail: "Restart the Finder", kind: .fire(destructive: false)),
        Row(id: .relaunchDock, title: "Relaunch Dock", symbol: "arrow.triangle.2.circlepath.circle",
            detail: "Restart the Dock", kind: .fire(destructive: false)),

        // Whatever is playing answers these, the same as the keys on the
        // keyboard do.
        Row(id: .playPause, title: "Play or Pause", symbol: "playpause.fill",
            detail: "Play or pause whatever is playing", kind: .fire(destructive: false)),
        Row(id: .nextTrack, title: "Next Track", symbol: "forward.end.fill",
            detail: "Skip to the next track", kind: .fire(destructive: false)),
        Row(id: .previousTrack, title: "Previous Track", symbol: "backward.end.fill",
            detail: "Back to the previous track", kind: .fire(destructive: false)),
        Row(id: .micMute, title: "Mute Mic", symbol: "mic.slash.fill",
            detail: "Mute the microphone every call uses", kind: .toggle),
        Row(id: .keyboardCleaning, title: "Clean Keyboard", symbol: "keyboard",
            detail: "Lock the keys for thirty seconds so you can wipe them", kind: .fire(destructive: false)),
        Row(id: .plainPaste, title: "Paste as Text", symbol: "doc.on.clipboard",
            detail: "Paste the clipboard with its formatting taken off", kind: .fire(destructive: false)),
        Row(id: .screenRecording, title: "Screen Recording", symbol: "record.circle",
            detail: "Start a recording, and stop it with a second click", kind: .toggle),
        Row(id: .dockMagnification, title: "Dock Magnification", symbol: "arrow.up.left.and.arrow.down.right",
            detail: "Grow a Dock icon as the pointer passes it", kind: .toggle),
        Row(id: .dockRecents, title: "Dock Recents", symbol: "clock.arrow.circlepath",
            detail: "The recent apps section at the end of the Dock", kind: .toggle),
        Row(id: .minimizeIntoIcon, title: "Minimise Into Icon", symbol: "arrow.down.right.and.arrow.up.left",
            detail: "Minimised windows go into the app's own Dock icon", kind: .toggle),
        Row(id: .clickWallpaper, title: "Click Wallpaper", symbol: "rectangle.on.rectangle.slash",
            detail: "Clicking the wallpaper moves every window aside", kind: .toggle),
        Row(id: .finderPathBar, title: "Path Bar", symbol: "point.topleft.down.curvedto.point.bottomright.up",
            detail: "The folder path along the bottom of a Finder window", kind: .toggle),
        Row(id: .finderStatusBar, title: "Status Bar", symbol: "text.line.first.and.arrowtriangle.forward",
            detail: "The item count along the bottom of a Finder window", kind: .toggle),
        Row(id: .fileExtensions, title: "File Extensions", symbol: "textformat.abc.dottedunderline",
            detail: "Show every file extension in the Finder", kind: .toggle),
        Row(id: .screenshotThumbnail, title: "Shot Thumbnail", symbol: "photo.badge.checkmark",
            detail: "The preview that floats after a screenshot", kind: .toggle),
        Row(id: .clockSeconds, title: "Clock Seconds", symbol: "clock",
            detail: "Seconds on the menu bar clock", kind: .toggle),
        Row(id: .trueTone, title: "True Tone", symbol: "sun.max.trianglebadge.exclamationmark",
            detail: "Match the display's white to the room", kind: .toggle),
        Row(id: .micLevel, title: "Mic Level", symbol: "mic.and.signal.meter",
            detail: "Input volume for the microphone in use", kind: .level),
        Row(id: .focus, title: "Focus", symbol: "moon.circle",
            detail: "Open Control Center's Focus modes", kind: .fire(destructive: false)),
    ]

    /// Every action, with a real control once its own phase gives it one.
    nonisolated static let all: [ActionID: ActionSpec] = Dictionary(
        uniqueKeysWithValues: rows.map { row in
            (row.id, ActionSpec(id: row.id, title: row.title, symbol: row.symbol,
                                 detail: row.detail, control: control(for: row.id)))
        }
    )

    static let kind: [ActionID: Kind] = Dictionary(
        uniqueKeysWithValues: rows.map { ($0.id, $0.kind) }
    )

    /// Row order, for the Items page's Actions section.
    static let ordered: [ActionID] = rows.map(\.id)

    /// Every `ActionID` has a row, so this is total in practice; `RegistryTests`
    /// is what keeps that true.
    static func spec(for id: ActionID) -> ActionSpec {
        all[id]!
    }

    /// Whether an action's control can actually do anything on this Mac right
    /// now: not wedged, and, for the three private-symbol actions, not one
    /// whose `resolve()` came back nil. Cheap: reads the already-resolved
    /// `PrivateAPI` statics rather than building a fresh control closure.
    @MainActor
    static func isAvailable(_ id: ActionID) -> Bool {
        guard !PrivateCall.isWedged(id), !ItemResolver.wedged.contains(id) else { return false }
        switch id {
        case .bluetooth: return PrivateAPI.bluetooth != nil
        case .brightness: return PrivateAPI.brightness != nil
        case .lockScreen: return PrivateAPI.lockScreen != nil
    case .trueTone: return PrivateAPI.trueTone != nil
        case .showDesktop: return DesktopActions.canShowDesktop
        case .missionControl: return FileManager.default.fileExists(atPath: DesktopActions.missionControlURL.path)
        default: return true
        }
    }

    /// Which preference each switch cell reads. Separate from `control` so a
    /// test can name the domain without building a control closure.
    static func domain(for id: ActionID) -> SystemSwitch.Domain {
        switch id {
        case .desktopIcons: return .desktopIcons
        case .hiddenFiles: return .hiddenFiles
        case .dockAutohide: return .dockAutohide
        case .menuBarAutohide: return .menuBarAutohide
        case .dockMagnification: return .dockMagnification
        case .dockRecents: return .dockRecents
        case .minimizeIntoIcon: return .minimizeIntoIcon
        case .clickWallpaper: return .clickWallpaper
        case .finderPathBar: return .finderPathBar
        case .finderStatusBar: return .finderStatusBar
        case .fileExtensions: return .fileExtensions
        case .screenshotThumbnail: return .screenshotThumbnail
        case .clockSeconds: return .clockSeconds
        default: return .batteryPercentage
        }
    }

    private static func isDarkModeOn() -> Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }

    private static func stageManagerEnabled() -> Bool? {
        UserDefaults(suiteName: "com.apple.WindowManager")?.bool(forKey: "GloballyEnabled")
    }

    static func control(
        for id: ActionID,
        bluetooth: BluetoothAPI? = PrivateAPI.bluetooth,
        brightness: BrightnessAPI? = PrivateAPI.brightness,
        lockScreen: LockScreenAPI? = PrivateAPI.lockScreen,
        nightShift: NightShiftAPI? = PrivateAPI.nightShift
    ) -> ActionSpec.Control {
        switch id {
        case .wifi:
            return .toggle(
                read: { CWWiFiClient.shared().interface()?.powerOn() },
                write: { on in
                    guard let interface = CWWiFiClient.shared().interface() else { throw ActionError.unavailable }
                    try interface.setPower(on)
                },
                observe: nil
            )
        case .darkMode:
            return .toggle(
                read: { isDarkModeOn() },
                write: { on in
                    guard on != isDarkModeOn() else { return }
                    try await MainActor.run {
                        NSApp.activate(ignoringOtherApps: true)
                        try AppleScript.run(AppleScript.darkModeToggle)
                    }
                },
                observe: DistributedNotificationCenter.default()
                    .publisher(for: Notification.Name("AppleInterfaceThemeChangedNotification"))
                    .map { _ in isDarkModeOn() }
                    .receive(on: DispatchQueue.main)
                    .eraseToAnyPublisher()
            )
        case .mute:
            return .toggle(
                read: { AudioOutput.isMuted() },
                write: { on in try AudioOutput.setMuted(on) },
                observe: AudioOutput.changes.compactMap { AudioOutput.isMuted() }.eraseToAnyPublisher()
            )
        case .volume:
            return .level(
                read: { AudioOutput.volume() },
                write: { value in try AudioOutput.setVolume(value) },
                observe: AudioOutput.changes.compactMap { AudioOutput.volume() }.eraseToAnyPublisher()
            )
        case .keepAwake:
            return .toggle(
                read: { KeepAwake.isHeld },
                write: { on in try KeepAwake.set(on) },
                observe: nil
            )
        case .sleep:
            return .fire(run: { _ = try await Shell.run("/usr/bin/pmset", ["sleepnow"]) }, destructive: false)
        case .emptyTrash:
            return .fire(run: {
                try await MainActor.run {
                    NSApp.activate(ignoringOtherApps: true)
                    try AppleScript.run(AppleScript.emptyTrash)
                }
            }, destructive: true)
        case .screenshot, .captureWindow, .captureDisplay:
            let mode: ScreenshotCapture.Mode = id == .captureWindow ? .window : id == .captureDisplay ? .display : .selection
            return .fire(run: { try await ScreenshotCapture.shared.capture(mode) }, destructive: false)
        case .missionControl:
            return .fire(run: { try await DesktopActions.missionControl() }, destructive: false)
        case .showDesktop:
            guard DesktopActions.canShowDesktop else { return .unavailable }
            return .fire(run: { try await DesktopActions.showDesktop() }, destructive: false)
        case .startScreenSaver:
            return .fire(run: {
                try await MainActor.run { try AppleScript.run(AppleScript.startScreenSaver) }
            }, destructive: false)
        case .quitApp:
            return .fire(run: {
                try await MainActor.run { try SystemActions.quit(SystemActions.appInFront()) }
            }, destructive: false)
        case .hideOthers:
            return .fire(run: {
                try await MainActor.run { try SystemActions.hideOthers(except: SystemActions.appInFront()) }
            }, destructive: false)
        case .forceQuit:
            return .fire(run: {
                try await MainActor.run { try SystemActions.forceQuit(SystemActions.appInFront()) }
            }, destructive: true)
        case .sleepDisplays:
            return .fire(run: { _ = try await Shell.run("/usr/bin/pmset", ["displaysleepnow"]) }, destructive: false)
        case .ejectDisks:
            return .fire(run: {
                try await MainActor.run { try SystemActions.ejectAll() }
            }, destructive: true)
        case .restart:
            return .fire(run: {
                try await MainActor.run { try AppleScript.run(AppleScript.restart) }
            }, destructive: true)
        case .shutDown:
            return .fire(run: {
                try await MainActor.run { try AppleScript.run(AppleScript.shutDown) }
            }, destructive: true)
        case .logOut:
            return .fire(run: {
                try await MainActor.run { try AppleScript.run(AppleScript.logOut) }
            }, destructive: true)
        case .desktopIcons, .hiddenFiles, .dockAutohide, .menuBarAutohide, .batteryPercentage,
             .dockMagnification, .dockRecents, .minimizeIntoIcon, .clickWallpaper,
             .finderPathBar, .finderStatusBar, .fileExtensions, .screenshotThumbnail, .clockSeconds:
            let domain = Self.domain(for: id)
            return .toggle(
                read: { SystemSwitch.isOn(domain) },
                write: { on in try await SystemSwitch.set(domain, on: on) },
                observe: nil
            )
        case .relaunchFinder:
            return .fire(run: { try await SystemSwitch.restart("Finder") }, destructive: false)
        case .relaunchDock:
            return .fire(run: { try await SystemSwitch.restart("Dock") }, destructive: false)
        case .playPause, .nextTrack, .previousTrack:
            let key: MediaKeys.Key = id == .nextTrack ? .next : id == .previousTrack ? .previous : .playPause
            return .fire(run: { try await MainActor.run { try MediaKeys.press(key) } }, destructive: false)
        case .micMute:
            return .toggle(
                read: { AudioInput.isMuted() },
                write: { on in try AudioInput.setMuted(on) },
                observe: nil
            )
        case .micLevel:
            return .level(
                read: { AudioInput.level() },
                write: { value in try AudioInput.setLevel(value) },
                observe: nil
            )
        case .trueTone:
            guard let trueTone = PrivateAPI.trueTone else { return .unavailable }
            return .toggle(
                read: { await PrivateCall.run(.trueTone) { trueTone.isEnabled() } },
                write: { on in
                    let applied = await PrivateCall.run(.trueTone) { trueTone.setEnabled(on) } ?? false
                    guard applied else { throw ActionError.notApplied }
                },
                observe: nil
            )
        case .keyboardCleaning:
            return .fire(run: {
                try await MainActor.run { try KeyboardCleaning.shared.start() }
            }, destructive: false)
        case .plainPaste:
            return .fire(run: { try await MainActor.run { try PlainPaste.run() } }, destructive: false)
        case .focus:
            return .fire(run: {
                try await MainActor.run { try AppleScript.run(AppleScript.controlCenter) }
            }, destructive: false)
        case .screenRecording:
            return .toggle(
                read: { await MainActor.run { ScreenRecording.shared.isRunning } },
                write: { on in
                    try await MainActor.run {
                        let running = try ScreenRecording.shared.toggle()
                        guard running == on else { throw ActionError.notApplied }
                    }
                },
                // A refused recording ends on its own a beat after it
                // starts, and this is what turns the ring back off.
                observe: ScreenRecording.shared.changes.eraseToAnyPublisher()
            )
        case .stageManager:
            // Whether this row survives past phase 7 is a call phase 9's
            // hands-on check makes, not this one.
            return .toggle(
                read: { stageManagerEnabled() },
                write: { on in
                    _ = try await Shell.run("/usr/bin/defaults", ["write", "com.apple.WindowManager", "GloballyEnabled", "-bool", on ? "true" : "false"])
                    try await Task.sleep(nanoseconds: 500_000_000)
                    guard stageManagerEnabled() == on else { throw ActionError.notApplied }
                },
                observe: nil
            )
        case .bluetooth:
            guard let bluetooth else { return .unavailable }
            return .toggle(
                read: { await PrivateCall.run(.bluetooth) { bluetooth.getPower() != 0 } },
                write: { on in
                    guard await PrivateCall.run(.bluetooth, { bluetooth.setPower(on ? 1 : 0) }) != nil
                    else { throw ActionError.unavailable }
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    guard let now = await PrivateCall.run(.bluetooth, { bluetooth.getPower() != 0 }), now == on
                    else { throw ActionError.notApplied }
                },
                observe: nil
            )
        case .brightness:
            guard let brightness else { return .unavailable }
            return .level(
                read: {
                    await PrivateCall.run(.brightness) { () -> Double? in
                        var value: Float = 0
                        guard brightness.get(CGMainDisplayID(), &value) == 0 else { return nil }
                        return Double(value)
                    } ?? nil
                },
                write: { value in
                    guard let status = await PrivateCall.run(.brightness, { brightness.set(CGMainDisplayID(), Float(value)) }),
                          status == 0
                    else { throw ActionError.unavailable }
                },
                observe: nil
            )
        case .nightShift:
            guard let nightShift else { return .unavailable }
            return .toggle(
                read: { await PrivateCall.run(.nightShift) { nightShift.isEnabled() } ?? nil },
                write: { on in
                    guard let ok = await PrivateCall.run(.nightShift, { nightShift.setEnabled(on) }) else {
                        throw ActionError.unavailable
                    }
                    guard ok else { throw ActionError.failed("Night Shift could not be set") }
                },
                observe: nil
            )
        case .lockScreen:
            guard let lockScreen else { return .unavailable }
            return .fire(run: {
                guard await PrivateCall.run(.lockScreen, { lockScreen.lock() }) != nil else { throw ActionError.unavailable }
            }, destructive: false)
        }
    }

    #if DEBUG
    /// Whether the last call to `read` started on the main thread, for a test
    /// to inspect. Not thread-safe on its own; fine for the single-threaded
    /// way tests use it.
    static var lastReadWasOnMain = false
    #endif

    /// Where every action's read goes through, so DEBUG bookkeeping lives in
    /// one place instead of at every call site.
    static func read<T>(_ body: @Sendable () async -> T) async -> T {
        #if DEBUG
        lastReadWasOnMain = Thread.isMainThread
        #endif
        return await body()
    }

    /// One process-wide idle-sleep assertion. macOS doesn't give a way to
    /// ask "is one held" back, so the registry has to remember it itself.
    /// Internal, not private, so a test can release it synchronously in a
    /// `defer` without going through the async registry closure.
    enum KeepAwake {
        private static var id: IOPMAssertionID = 0
        private(set) static var isHeld = false

        static func set(_ on: Bool) throws {
            if on {
                guard !isHeld else { return }
                var newID: IOPMAssertionID = 0
                let result = IOPMAssertionCreateWithName(
                    kIOPMAssertPreventUserIdleDisplaySleep as CFString,
                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                    "Drawer keep awake" as CFString,
                    &newID
                )
                guard result == kIOReturnSuccess else {
                    throw ActionError.failed("Could not create the keep-awake assertion.")
                }
                id = newID
                isHeld = true
            } else {
                guard isHeld else { return }
                IOPMAssertionRelease(id)
                isHeld = false
            }
        }
    }
}
