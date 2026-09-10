import AppKit
import XCTest
@testable import Drawer

/// The actions added for 1.0: the ones that act on other apps, on the
/// machine, and on switches that live in another app's preferences.
///
/// Nothing here touches a real preference or a real app. The switch tests
/// drive `SystemSwitch.set` with a recorded shell rather than the real one,
/// which is also what lets them assert the exact `defaults` line: the whole
/// risk in this batch is writing the wrong key into somebody else's domain.
final class SystemActionsTests: XCTestCase {
    private struct Recorder {
        var calls: [(String, [String])] = []
    }

    private func recording(status: Int32 = 0) -> (@Sendable (String, [String]) async throws -> ShellResult, () -> [(String, [String])]) {
        let box = NSMutableArray()
        let run: @Sendable (String, [String]) async throws -> ShellResult = { tool, arguments in
            box.add([tool, arguments] as [Any])
            return ShellResult(status: status, stdout: "", stderr: "")
        }
        return (run, {
            box.compactMap { entry in
                guard let pair = entry as? [Any], let tool = pair.first as? String,
                      let arguments = pair.last as? [String] else { return nil }
                return (tool, arguments)
            }
        })
    }

    // MARK: - The switches

    func testEachSwitchWritesItsOwnKeyAndRestartsItsOwnApp() async throws {
        let cases: [(ActionID, String, String, String?)] = [
            (.desktopIcons, "com.apple.finder", "CreateDesktop", "Finder"),
            (.hiddenFiles, "com.apple.finder", "AppleShowAllFiles", "Finder"),
            (.dockAutohide, "com.apple.dock", "autohide", "Dock"),
            (.menuBarAutohide, "Apple Global Domain", "_HIHideMenuBar", nil),
            (.batteryPercentage, "com.apple.controlcenter", "BatteryShowPercentage", "ControlCenter"),
        ]
        for (id, identifier, key, restarts) in cases {
            let domain = ActionRegistry.domain(for: id)
            XCTAssertEqual(domain.identifier, identifier, "\(id) writes the wrong domain")
            XCTAssertEqual(domain.key, key, "\(id) writes the wrong key")
            XCTAssertEqual(domain.restarts, restarts, "\(id) restarts the wrong app")
        }
    }

    /// The command line, exactly. A typo here writes a stray key into the
    /// Finder's or the Dock's preferences on someone's real Mac.
    func testTheSwitchWritesADefaultsBoolAndThenRestartsTheOwner() async throws {
        let (run, calls) = recording()
        let domain = SystemSwitch.Domain(identifier: "com.advegaf.drawer.notarealdomain",
                                         key: "TestKey", defaultsToOn: false, restarts: "Finder")
        do {
            try await SystemSwitch.set(domain, on: true, run: run)
            XCTFail("a domain nothing ever wrote should not read back as on")
        } catch {
            // `notApplied` is the point: the read back is real even when the
            // write is recorded, so a switch that does not land says so.
            XCTAssertEqual(error as? ActionError, .notApplied)
        }
        let recorded = calls()
        XCTAssertEqual(recorded.first?.0, "/usr/bin/defaults")
        XCTAssertEqual(recorded.first?.1, ["write", "com.advegaf.drawer.notarealdomain", "TestKey", "-bool", "true"])
        XCTAssertEqual(recorded.last?.0, "/usr/bin/killall")
        XCTAssertEqual(recorded.last?.1, ["Finder"])
    }

    func testAFailedWriteIsReportedRatherThanAssumed() async throws {
        let (run, _) = recording(status: 1)
        do {
            try await SystemSwitch.set(.dockAutohide, on: true, run: run)
            XCTFail("a defaults write that failed should throw")
        } catch {
            XCTAssertEqual(error as? ActionError, .failed("The setting could not be written."))
        }
    }

    func testRelaunchingRunsKillallAndReportsAFailure() async throws {
        let (run, calls) = recording()
        try await SystemSwitch.restart("Dock", run: run)
        XCTAssertEqual(calls().first?.0, "/usr/bin/killall")
        XCTAssertEqual(calls().first?.1, ["Dock"])

        let (failing, _) = recording(status: 1)
        do {
            try await SystemSwitch.restart("Dock", run: failing)
            XCTFail("a killall that failed should throw")
        } catch {
            XCTAssertEqual(error as? ActionError, .failed("Dock could not be restarted."))
        }
    }

    /// The Finder's desktop icons are on when the key is absent, which is the
    /// state a Mac ships in. Reading that as off would draw the cell wrong on
    /// every Mac that has never changed it.
    func testAnAbsentKeyReadsAsItsOwnDefault() {
        let on = SystemSwitch.Domain(identifier: "com.advegaf.drawer.notarealdomain",
                                     key: "AbsentKey", defaultsToOn: true, restarts: nil)
        let off = SystemSwitch.Domain(identifier: "com.advegaf.drawer.notarealdomain",
                                      key: "AbsentKey", defaultsToOn: false, restarts: nil)
        XCTAssertEqual(SystemSwitch.isOn(on), true)
        XCTAssertEqual(SystemSwitch.isOn(off), false)
    }

    // MARK: - Apps and disks

    @MainActor
    func testQuitAndHideOthersSayUnavailableRatherThanActingOnNothing() {
        XCTAssertThrowsError(try SystemActions.quit(nil)) {
            XCTAssertEqual($0 as? ActionError, .unavailable)
        }
        // Hiding with nothing to hide is not a silent success either.
        let others = SystemActions.otherApps()
        if others.isEmpty {
            XCTAssertThrowsError(try SystemActions.hideOthers(except: nil))
        }
    }

    @MainActor
    func testHideOthersNeverIncludesThisAppOrTheFinder() {
        let ids = SystemActions.otherApps().map(\.processIdentifier)
        XCTAssertFalse(ids.contains(ProcessInfo.processInfo.processIdentifier))
        XCTAssertFalse(SystemActions.otherApps().contains { $0.bundleIdentifier == "com.apple.finder" })
    }

    /// The boot volume is not ejectable, so it is never in the list. This is
    /// the one action here that could take something away from someone.
    func testEjectNeverOffersTheBootVolume() {
        let ejectable = SystemActions.ejectableVolumes()
        XCTAssertFalse(ejectable.contains(URL(fileURLWithPath: "/")))
        for url in ejectable {
            let values = try? url.resourceValues(forKeys: [.volumeIsEjectableKey, .volumeIsRemovableKey])
            XCTAssertTrue(values?.volumeIsEjectable == true || values?.volumeIsRemovable == true, "\(url.path)")
        }
    }

    @MainActor
    func testEjectingNothingIsUnavailableRatherThanASilentSuccess() {
        XCTAssertThrowsError(try SystemActions.ejectAll(volumes: [])) {
            XCTAssertEqual($0 as? ActionError, .unavailable)
        }
    }

    // MARK: - Force quit

    /// Force Quit used to send Command Option Escape through System Events,
    /// which opens Apple's picker window and quits nothing. It now kills the
    /// app that was in front, the same one Quit App targets.
    @MainActor
    func testForceQuitTargetsTheAppThatWasInFrontAndSaysSoWhenThereIsNone() {
        XCTAssertThrowsError(try SystemActions.forceQuit(nil)) {
            XCTAssertEqual($0 as? ActionError, .unavailable, "no app in front is unavailable, not a failure")
        }
        // Destructive, so the cell arms first. The pairing of the two is what
        // stops a misclick killing unsaved work.
        if case .fire(let destructive) = ActionRegistry.kind[.forceQuit] {
            XCTAssertTrue(destructive, "force quit has to arm before it fires")
        } else {
            XCTFail("force quit is not a fire action")
        }
        XCTAssertTrue(ActionRegistry.spec(for: .forceQuit).detail.contains("in front"),
                      "the row still describes Apple's picker window")
    }

    // MARK: - Asking for a permission once

    /// The prompt returned on every click, because `require` called the
    /// prompting API each time it found the app untrusted. macOS honours it
    /// once per signed copy, so every later call put a dialog on screen that
    /// could not grant anything.
    @MainActor
    func testTheAccessibilityPromptIsAskedForOnceAndThenTheSettingsPaneOpens() throws {
        let name = "InputPermission.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        InputPermission.defaults = defaults
        var opened = 0
        InputPermission.openSettings = { opened += 1 }
        defer {
            InputPermission.defaults = .standard
            InputPermission.openSettings = {}
        }

        guard !InputPermission.isTrusted else {
            throw XCTSkip("this run is already trusted, so the untrusted path cannot be exercised")
        }
        XCTAssertThrowsError(try InputPermission.require())
        XCTAssertTrue(defaults.bool(forKey: InputPermission.askedKey), "the first ask was not remembered")
        XCTAssertEqual(opened, 0, "the first refusal shows Apple's prompt, not our pane")

        XCTAssertThrowsError(try InputPermission.require())
        XCTAssertEqual(opened, 1, "the second refusal should open the pane instead of prompting again")
    }

    // MARK: - Screen recording

    /// `task.run()` succeeds the moment the binary is exec'd, so a refusal
    /// that arrives a beat later used to leave the cell reading On with
    /// nothing recording. The preflight is what stops it starting at all.
    @MainActor
    func testARecordingWithoutPermissionIsRefusedRatherThanStartedAndLost() throws {
        let name = "ScreenRecording.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        ScreenRecording.defaults = defaults
        ScreenRecording.preflight = { false }
        var requested = 0
        var opened = 0
        ScreenRecording.request = { requested += 1; return false }
        ScreenRecording.openSettings = { opened += 1 }
        defer {
            ScreenRecording.defaults = .standard
            ScreenRecording.preflight = { CGPreflightScreenCaptureAccess() }
            ScreenRecording.request = { CGRequestScreenCaptureAccess() }
            ScreenRecording.openSettings = {}
        }

        let destination = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(UUID().uuidString).mov")
        XCTAssertThrowsError(try ScreenRecording.shared.toggle(destination: destination)) {
            XCTAssertEqual($0 as? ActionError, .failed(ScreenRecording.missing))
        }
        XCTAssertFalse(ScreenRecording.shared.isRunning, "a refused recording must not leave the cell reading On")
        XCTAssertEqual(requested, 1, "the first refusal should show Apple's prompt")
        XCTAssertEqual(opened, 0)

        XCTAssertThrowsError(try ScreenRecording.shared.toggle(destination: destination))
        XCTAssertEqual(requested, 1, "the prompt must not be asked for twice")
        XCTAssertEqual(opened, 1, "the second refusal should open the pane instead")
    }

    // MARK: - The switches added this round

    /// Ten new switches, each of which has to name a domain, a key and a real
    /// symbol, and none of which may fall through to the battery percentage
    /// default that `domain(for:)` ends with.
    func testEachNewSwitchNamesItsOwnPreference() {
        let added: [ActionID] = [.dockMagnification, .dockRecents, .minimizeIntoIcon, .clickWallpaper,
                                 .finderPathBar, .finderStatusBar, .fileExtensions,
                                 .screenshotThumbnail, .clockSeconds]
        var keys: Set<String> = []
        for id in added {
            let spec = ActionRegistry.spec(for: id)
            XCTAssertNotNil(NSImage(systemSymbolName: spec.symbol, accessibilityDescription: nil),
                            "\(id) names a symbol this system does not have: \(spec.symbol)")
            XCTAssertFalse(spec.detail.isEmpty, "\(id) has no detail line")
            let domain = ActionRegistry.domain(for: id)
            XCTAssertNotEqual(domain.key, "BatteryShowPercentage", "\(id) fell through to the default domain")
            XCTAssertTrue(keys.insert("\(domain.identifier).\(domain.key)").inserted,
                          "\(id) shares a preference with another switch")
            guard case .toggle = spec.control else {
                return XCTFail("\(id) should be a toggle")
            }
        }
    }

    /// True Tone hides itself on a Mac whose display has no ambient sensor,
    /// the same way Bluetooth and brightness hide when their private symbol
    /// will not resolve.
    @MainActor
    func testTrueToneIsEitherAvailableAndAToggleOrHiddenEntirely() {
        if PrivateAPI.trueTone == nil {
            XCTAssertFalse(ActionRegistry.isAvailable(.trueTone), "an unresolvable True Tone must not be offered")
        } else {
            guard case .toggle = ActionRegistry.spec(for: .trueTone).control else {
                return XCTFail("True Tone resolved but is not a toggle")
            }
        }
    }

    // MARK: - The registry

    /// The ones that cannot be taken back are the ones that arm. Force Quit
    /// joined them when it stopped opening Apple's picker window and started
    /// killing the app in front, which loses unsaved work by definition.
    func testOnlyTheIrreversibleActionsAreDestructive() {
        let destructive = ActionID.allCases.filter {
            if case .fire(let isDestructive) = ActionRegistry.kind[$0] { return isDestructive }
            return false
        }
        XCTAssertEqual(Set(destructive), [.emptyTrash, .ejectDisks, .restart, .shutDown, .logOut, .forceQuit])
    }

    /// Every new action resolves to a control that can actually run. A row
    /// with no control is a cell that does nothing when it is clicked.
    func testTheNewActionsAllHaveAControl() {
        let added: [ActionID] = [.quitApp, .hideOthers, .forceQuit, .sleepDisplays, .ejectDisks,
                                 .restart, .shutDown, .logOut, .desktopIcons, .hiddenFiles,
                                 .dockAutohide, .menuBarAutohide, .batteryPercentage,
                                 .relaunchFinder, .relaunchDock]
        for id in added {
            let spec = ActionRegistry.spec(for: id)
            XCTAssertFalse(spec.title.isEmpty, "\(id) has no title")
            XCTAssertFalse(spec.detail.isEmpty, "\(id) has no detail line")
            XCTAssertNotNil(NSImage(systemSymbolName: spec.symbol, accessibilityDescription: nil),
                            "\(id) names a symbol this system does not have: \(spec.symbol)")
            if case .unavailable = spec.control {
                XCTFail("\(id) has no control")
            }
        }
    }
}

/// The batch that shares the Accessibility permission, plus the two that do
/// not need it.
///
/// None of these post a real event: every one takes its poster as a
/// parameter, so what is asserted here is the event that would have gone
/// out. A media key sent with the wrong `data1` is a key nothing answers,
/// and there is no way to see that in a screenshot.
@MainActor
final class InputActionsTests: XCTestCase {
    func testAMediaKeyIsADownAndAnUpWithTheRightCode() throws {
        try XCTSkipUnless(InputPermission.isTrusted, "needs Accessibility, which a test host does not have")
        var sent: [NSEvent] = []
        try MediaKeys.press(.next, post: { sent.append($0) })
        XCTAssertEqual(sent.count, 2, "a key press is a down and an up")
        XCTAssertEqual(sent.first?.subtype.rawValue, 8)
        XCTAssertEqual(sent.first?.data1, Int((MediaKeys.Key.next.rawValue << 16) | 0x0A00))
        XCTAssertEqual(sent.last?.data1, Int((MediaKeys.Key.next.rawValue << 16) | 0x0B00))
    }

    func testEveryTransportKeyHasItsOwnCode() {
        XCTAssertEqual(Set([MediaKeys.Key.playPause, .next, .previous].map(\.rawValue)).count, 3)
    }

    /// Without the permission these say where to grant it rather than
    /// failing quietly, which is what an untrusted `CGEvent.post` does.
    func testTheyAskForAccessibilityRatherThanFailingSilently() throws {
        try XCTSkipIf(InputPermission.isTrusted, "this host already has the permission")
        XCTAssertThrowsError(try MediaKeys.press(.playPause, post: { _ in })) {
            XCTAssertEqual($0 as? ActionError,
                           .failed("Allow Drawer in System Settings > Privacy & Security > Accessibility"))
        }
    }

    func testPlainPasteRewritesTheClipboardAsTextAndSendsCommandV() throws {
        try XCTSkipUnless(InputPermission.isTrusted, "needs Accessibility, which a test host does not have")
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("PlainPasteTests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        let rich = try XCTUnwrap(NSAttributedString(string: "hello", attributes: [.font: NSFont.boldSystemFont(ofSize: 24)])
            .rtf(from: NSRange(location: 0, length: 5)))
        pasteboard.setData(rich, forType: .rtf)
        pasteboard.setString("hello", forType: .string)

        var events: [CGEvent] = []
        try PlainPaste.run(pasteboard: pasteboard, post: { event in if let event { events.append(event) } })
        XCTAssertNil(pasteboard.data(forType: .rtf), "the formatted flavour survived")
        XCTAssertEqual(pasteboard.string(forType: .string), "hello")
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.first?.getIntegerValueField(.keyboardEventKeycode), 9, "not the V key")
        XCTAssertTrue(events.first?.flags.contains(.maskCommand) == true)
    }

    func testPastingAnEmptyClipboardSaysSoRatherThanPasting() throws {
        try XCTSkipUnless(InputPermission.isTrusted, "needs Accessibility, which a test host does not have")
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("PlainPasteEmpty.\(UUID().uuidString)"))
        pasteboard.clearContents()
        var posted = 0
        XCTAssertThrowsError(try PlainPaste.run(pasteboard: pasteboard, post: { _ in posted += 1 })) {
            XCTAssertEqual($0 as? ActionError, .failed("There is no text on the clipboard."))
        }
        XCTAssertEqual(posted, 0, "it sent a paste with nothing to paste")
    }

    /// Thirty seconds, and Escape has to be held rather than pressed: a
    /// cloth dragged over the keys hits Escape as readily as anything else.
    func testTheKeyboardLockIsLongEnoughToBeUsefulAndHardToLeaveByAccident() {
        XCTAssertEqual(KeyboardCleaning.duration, 30)
        XCTAssertGreaterThanOrEqual(KeyboardCleaning.escapeHold, 1)
        XCTAssertFalse(KeyboardCleaning.shared.isRunning)
    }

    /// The system switches a tap off on a secure input field or a slow
    /// callback, and the lock has to survive that rather than going quiet
    /// while the overlay still claims the keyboard is held.
    func testTurningTheTapBackOnIsSafeWhenTheLockIsNotUp() {
        KeyboardCleaning.shared.reenable()
        XCTAssertFalse(KeyboardCleaning.shared.isRunning)
    }

    func testARecordingIsNamedForItsMomentAndLandsOnTheDesktop() {
        let when = Date(timeIntervalSince1970: 1_757_000_000)
        let url = ScreenRecording.destination(date: when)
        XCTAssertEqual(url.pathExtension, "mov")
        XCTAssertTrue(url.lastPathComponent.hasPrefix("Screen Recording "), url.lastPathComponent)
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "Desktop")
        XCTAssertFalse(ScreenRecording.shared.isRunning)
    }
}

/// The pickers a cell offers on a secondary click.
///
/// Built from lists that are passed in, so nothing here asks the radio or
/// the audio hardware: what is asserted is the menu, which is the part with
/// the bugs in it. A picker that offers to join the network you are already
/// on, or that loses the item's payload, is a menu that does nothing when it
/// is clicked.
@MainActor
final class CellPickerTests: XCTestCase {
    private func actions() -> MenuActions {
        MenuActions(togglePinned: {}, openSettings: {}, showDrawer: {}, removeCell: { _ in })
    }

    func testOnlyTheThreeCellsWithSomethingToPickHaveAPicker() {
        XCTAssertTrue(CellPicker.has(.wifi))
        XCTAssertTrue(CellPicker.has(.bluetooth))
        XCTAssertTrue(CellPicker.has(.volume))
        XCTAssertTrue(CellPicker.has(.mute))
        XCTAssertTrue(CellPicker.has(.focus))
        XCTAssertTrue(CellPicker.has(.micMute))
        XCTAssertTrue(CellPicker.has(.micLevel))
        for id in [ActionID.darkMode, .brightness, .keepAwake, .quitApp, .screenRecording] {
            XCTAssertFalse(CellPicker.has(id), "\(id) should not carry a picker")
        }
    }

    /// The Focus picker lists the modes macOS ships and ticks none of them.
    /// Nothing here can read the active mode without Full Disk Access, and a
    /// checkmark that is wrong is worse than no checkmark at all.
    @MainActor
    func testTheFocusPickerListsModesWithoutClaimingWhichIsOn() {
        let items = CellPicker.items(for: .focus, target: actions(), modes: ["Do Not Disturb", "Work"])
        XCTAssertEqual(items.first?.title, "Focus modes", "the picker lost its header")
        let dnd = items.first { $0.title == "Do Not Disturb" }
        XCTAssertEqual(dnd?.representedObject as? String, "Do Not Disturb")
        XCTAssertTrue(items.filter { $0.state == .on }.isEmpty, "a Focus item cannot know that it is the one that is on")
        XCTAssertNotNil(items.first { $0.title == "Focus Settings..." }, "no way through to the real settings")
    }

    /// The Focus cell must not fall through to the output list. The picker's
    /// default arm is the audio outputs, so a missing case would hand the
    /// Focus cell a menu of speakers.
    @MainActor
    func testTheFocusCellDoesNotGetTheOutputMenu() {
        let items = CellPicker.items(for: .focus, target: actions(), modes: ["Work"])
        XCTAssertNotEqual(items.first?.title, "Output")
    }

    /// The microphone cells offer the inputs, and an input is ticked the same
    /// way an output is.
    @MainActor
    func testTheInputPickerTicksTheOneInUse() {
        let items = CellPicker.items(for: .micMute, target: actions(), inputs: [
            .init(id: 1, name: "MacBook Pro Microphone", isDefault: true),
            .init(id: 2, name: "Podcast Mic", isDefault: false),
        ])
        XCTAssertEqual(items.first?.title, "Input")
        XCTAssertEqual(items.first { $0.title == "MacBook Pro Microphone" }?.state, .on)
        XCTAssertEqual(items.first { $0.title == "Podcast Mic" }?.state, .off)
    }

    func testTheNetworkYouAreOnIsTickedAndTheOthersAreNot() {
        let items = CellPicker.items(for: .wifi, target: actions(), networks: [
            .init(ssid: "Home", isCurrent: true), .init(ssid: "Office", isCurrent: false),
        ])
        let home = items.first { $0.title == "Home" }
        let office = items.first { $0.title == "Office" }
        XCTAssertEqual(home?.state, .on)
        XCTAssertEqual(office?.state, .off)
        XCTAssertEqual(home?.representedObject as? String, "Home", "the item lost the network it names")
        XCTAssertTrue(items.contains { $0.title == "Network Settings..." })
        XCTAssertEqual(items.last?.isSeparatorItem, true, "the picker does not close its own section")
    }

    func testAConnectedDeviceIsTickedAndSortsFirst() {
        let items = CellPicker.items(for: .bluetooth, target: actions(), devices: [
            .init(name: "Keyboard", address: "aa", isConnected: false),
            .init(name: "AirPods", address: "bb", isConnected: true),
        ])
        let titles = items.filter { !$0.isSeparatorItem }.map(\.title)
        XCTAssertEqual(titles.first, "Devices", "the section has no heading")
        XCTAssertEqual(items.first { $0.title == "AirPods" }?.state, .on)
        XCTAssertEqual(items.first { $0.title == "Keyboard" }?.representedObject as? String, "aa")
    }

    func testAnEmptyListSaysSoRatherThanShowingAnEmptyMenu() {
        let items = CellPicker.items(for: .bluetooth, target: actions(), devices: [])
        XCTAssertTrue(items.contains { $0.title == "No paired devices" })
        XCTAssertFalse(items.first { $0.title == "No paired devices" }?.isEnabled ?? true)
    }

    func testTheOutputPickerCarriesTheDeviceIdAndTicksTheCurrentOne() {
        let items = CellPicker.items(for: .volume, target: actions(), outputs: [
            .init(id: 41, name: "MacBook Speakers", isDefault: true),
            .init(id: 42, name: "Studio Display", isDefault: false),
        ])
        XCTAssertEqual(items.first { $0.title == "MacBook Speakers" }?.state, .on)
        XCTAssertEqual(items.first { $0.title == "Studio Display" }?.representedObject as? UInt32, 42)
    }

    /// Every enabled item has somewhere to send its click. A nil target
    /// means a menu item that greys out the moment the menu opens.
    func testEveryPickerItemHasATarget() {
        let target = actions()
        for id in [ActionID.wifi, .bluetooth, .volume] {
            for item in CellPicker.items(for: id, target: target) where item.action != nil {
                XCTAssertNotNil(item.target, "\(item.title) has no target")
            }
        }
    }
}

/// Focus, and why it is a fire action rather than a picker.
@MainActor
final class FocusActionTests: XCTestCase {
    func testFocusOpensControlCenterRatherThanClaimingToSetAMode() {
        let spec = ActionRegistry.spec(for: .focus)
        XCTAssertEqual(spec.title, "Focus")
        // A toggle would be a lie: nothing here can read which mode is on
        // without Full Disk Access, and nothing can set one without driving
        // Control Center's rows through Accessibility.
        guard case .fire(let destructive) = ActionRegistry.kind[.focus] else {
            return XCTFail("Focus should be a fire action")
        }
        XCTAssertFalse(destructive)
        XCTAssertTrue(AppleScript.controlCenter.contains("ControlCenter"))
        XCTAssertTrue(AppleScript.controlCenter.contains("menu bar item 1"))
    }

    /// The picker asks Control Center for the row by name rather than by
    /// index. Index was tried and measured as fragile here: the panel's
    /// window index moved between two queries a second apart.
    @MainActor
    func testSettingAModeAsksForTheRowByNameAndNotByIndex() throws {
        guard InputPermission.isTrusted else {
            throw XCTSkip("setting a mode needs Accessibility, which this run does not have")
        }
        var source = ""
        FocusModes.script = { source = $0 }
        defer { FocusModes.script = { try AppleScript.run($0) } }

        try FocusModes.set("Do Not Disturb")
        XCTAssertTrue(source.contains("whose name contains \"Do Not Disturb\""),
                      "the mode is not being matched by name")
        XCTAssertTrue(source.contains("menu bar item \"Focus\""), "it should open the Focus panel, not the whole panel")
        XCTAssertFalse(source.contains("window 2"), "no fixed window index: that is what broke before")
    }

    /// A Control Center that has moved reports the failure rather than
    /// pretending the mode was set. Focus has no read back, so a silent
    /// failure here would be indistinguishable from success.
    @MainActor
    func testAModeThatCannotBeFoundIsReportedRatherThanSwallowed() throws {
        guard InputPermission.isTrusted else {
            throw XCTSkip("setting a mode needs Accessibility, which this run does not have")
        }
        FocusModes.script = { _ in throw ActionError.failed("System Events got an error") }
        defer { FocusModes.script = { try AppleScript.run($0) } }

        XCTAssertThrowsError(try FocusModes.set("Work")) { error in
            guard case .failed(let message)? = error as? ActionError else {
                return XCTFail("a missing row should be a failed action, not \(error)")
            }
            XCTAssertFalse(message.isEmpty)
        }
    }

    /// The nine modes macOS ships, in the order Control Center lists them.
    func testTheStandardModesAreTheOnesMacOSShips() {
        XCTAssertEqual(FocusModes.standard.first, "Do Not Disturb")
        XCTAssertEqual(FocusModes.standard.count, 9)
        XCTAssertTrue(FocusModes.standard.contains("Sleep"))
    }
}
