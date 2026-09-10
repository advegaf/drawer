import XCTest
@testable import Drawer

/// Thread-safe by hand, the same way `PrivateCall` is: it is written to from
/// inside `@Sendable` closures the runner hands off to its own tasks, and
/// read back from the test's own MainActor code.
final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [String] = []
    private var _states: [String: CellState] = [:]

    var events: [String] {
        lock.lock(); defer { lock.unlock() }
        return _events
    }

    func state(_ id: String) -> CellState? {
        lock.lock(); defer { lock.unlock() }
        return _states[id]
    }

    func note(_ event: String) {
        lock.lock(); defer { lock.unlock() }
        _events.append(event)
    }

    func recordUpdate(_ id: String, _ state: CellState) {
        lock.lock(); defer { lock.unlock() }
        _events.append("update:\(id)")
        _states[id] = state
    }
}

final class FakeLauncher: AppLaunching {
    private(set) var opened: [String] = []
    var errorToThrow: Error?

    func open(bundleID: String) async throws {
        opened.append(bundleID)
        if let errorToThrow { throw errorToThrow }
    }
}

final class FakeShell: DetachedRunning {
    private(set) var executable: String?
    private(set) var arguments: [String]?
    var errorToThrow: Error?
    private var onExit: (@Sendable (ShellResult) -> Void)?

    func launchDetached(_ executable: String, _ arguments: [String], onExit: @escaping @Sendable (ShellResult) -> Void) throws {
        if let errorToThrow { throw errorToThrow }
        self.executable = executable
        self.arguments = arguments
        self.onExit = onExit
    }

    func finish(_ result: ShellResult) {
        onExit?(result)
    }
}

@MainActor
final class RunnerTests: XCTestCase {
    private func waitUntil(timeout: TimeInterval = 1, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func makeRunner(
        recorder: Recorder,
        controls: [ActionID: ActionSpec.Control] = [:],
        launcher: AppLaunching = FakeLauncher(),
        shell: DetachedRunning = FakeShell()
    ) -> ActionRunner {
        ActionRunner(
            controlFor: { controls[$0] ?? .unavailable },
            launcher: launcher,
            shell: shell,
            fold: { recorder.note("fold") },
            update: { id, state, _ in recorder.recordUpdate(id, state) },
            openSettings: { recorder.note("openSettings") }
        )
    }

    // MARK: - Level updates

    /// Two things about the level path, both of which the drawn bar
    /// depends on. A value the user is dragging is forwarded as live, so
    /// the bar draws it instantly. And only the level that actually
    /// changed is forwarded: `states` is republished whole on every write,
    /// so before this a volume drag reassigned the brightness cell on
    /// every single sample.
    func testOnlyTheChangedLevelIsForwardedAndADraggedOneIsMarkedLive() async {
        var seen: [(id: String, state: CellState, live: Bool)] = []
        let levels = LiveLevels(controlFor: { _, _ in
            ActionSpec.Control.level(read: { 0.5 }, write: { _ in }, observe: nil)
        }, targetFor: { _ in 1 }, isWedged: { _ in false })
        // Held, not discarded: the subscription that forwards these lives
        // on the runner, so letting it go would make this test pass or fail
        // on deallocation timing rather than on the behaviour.
        let runner = ActionRunner(
            controlFor: { ActionRegistry.spec(for: $0).control }, liveLevels: levels,
            launcher: FakeLauncher(), shell: FakeShell(), fold: {},
            update: { id, state, live in seen.append((id, state, live)) }, openSettings: {}
        )

        levels.beginInteraction(for: .volume)
        levels.set(0.7, for: .volume)
        let dragSeen = seen
        levels.endInteraction(for: .volume)
        withExtendedLifetime(runner) {}
        seen = dragSeen

        let volume = DrawerItem.action(ActionID.volume.rawValue).id
        let brightness = DrawerItem.action(ActionID.brightness.rawValue).id
        let dragged = seen.filter { $0.id == volume && $0.state == .level(0.7) }
        XCTAssertEqual(dragged.count, 1, "the dragged value was forwarded \(dragged.count) times")
        XCTAssertEqual(dragged.first?.live, true, "a dragged value was not marked live")
        XCTAssertFalse(seen.contains { $0.id == brightness },
                       "a volume drag forwarded the brightness cell too")
    }

    // MARK: - add and launch

    func testAddOpensSettings() {
        let recorder = Recorder()
        let runner = makeRunner(recorder: recorder)
        runner.activate(DrawerCell.add)
        XCTAssertEqual(recorder.events, ["openSettings"])
    }

    func testNotInstalledLaunchOpensSettings() {
        let recorder = Recorder()
        let runner = makeRunner(recorder: recorder)
        let cell = DrawerCell(id: "app:com.example.missing", title: "Missing", icon: .symbol("app.dashed"),
                              kind: .launch, state: .notInstalled)
        runner.activate(cell)
        XCTAssertEqual(recorder.events, ["openSettings"])
    }

    func testLaunchGoesPendingThenReadyThenFolds() async {
        let recorder = Recorder()
        let launcher = FakeLauncher()
        let runner = makeRunner(recorder: recorder, launcher: launcher)
        let cell = DrawerCell(id: "app:com.apple.finder", title: "Finder", icon: .symbol("macwindow"),
                              kind: .launch, state: .ready)

        runner.activate(cell)
        XCTAssertEqual(recorder.state(cell.id), .pending)

        await waitUntil { recorder.events.contains("fold") }
        XCTAssertEqual(launcher.opened, ["com.apple.finder"])
        XCTAssertEqual(recorder.state(cell.id), .ready)
        XCTAssertEqual(recorder.events, ["update:\(cell.id)", "update:\(cell.id)", "fold"],
                       "pending, then ready, then fold, in that order")
    }

    func testLaunchErrorKeepsTheDrawerOpenAndRestores() async {
        let recorder = Recorder()
        let launcher = FakeLauncher()
        launcher.errorToThrow = ActionError.failed("nope")
        let runner = makeRunner(recorder: recorder, launcher: launcher)
        XCTAssertEqual(runner.failureDisplay, 2, "S058: the shipped failure display default should be two seconds")
        runner.failureDisplay = 0.05
        let cell = DrawerCell(id: "app:com.example.thing", title: "Thing", icon: .symbol("macwindow"),
                              kind: .launch, state: .ready)

        runner.activate(cell)
        await waitUntil { recorder.state(cell.id) == .failed("Couldn't open") }
        XCTAssertFalse(recorder.events.contains("fold"), "a launch failure should leave the drawer open")

        await waitUntil(timeout: 2) { recorder.state(cell.id) == .ready }
        XCTAssertEqual(recorder.state(cell.id), .ready)
    }

    func testPendingIgnoresASecondClick() async {
        let recorder = Recorder()
        let launcher = FakeLauncher()
        let runner = makeRunner(recorder: recorder, launcher: launcher)
        let cell = DrawerCell(id: "app:com.apple.finder", title: "Finder", icon: .symbol("macwindow"),
                              kind: .launch, state: .ready)

        runner.activate(cell)
        runner.activate(DrawerCell(id: cell.id, title: cell.title, icon: cell.icon, kind: cell.kind, state: .pending))

        await waitUntil { recorder.events.contains("fold") }
        XCTAssertEqual(launcher.opened.count, 1, "a second click on a pending cell should be ignored")
    }

    // MARK: - shortcut

    func testShortcutFoldsAtOnceAndPassesTheRightArguments() {
        let recorder = Recorder()
        let shell = FakeShell()
        let runner = makeRunner(recorder: recorder, shell: shell)
        let cell = DrawerCell(id: "shortcut:Focus Mode", title: "Focus Mode", icon: .symbol("square.2.layers.3d.fill"),
                              kind: .shortcut, state: .ready)

        runner.activate(cell)

        XCTAssertEqual(recorder.events, ["fold"])
        XCTAssertEqual(shell.executable, "/usr/bin/shortcuts")
        XCTAssertEqual(shell.arguments, ["run", "--", "Focus Mode"])
    }

    func testShortcutNotFoundExitWritesNotFound() async {
        let recorder = Recorder()
        let shell = FakeShell()
        let runner = makeRunner(recorder: recorder, shell: shell)
        let cell = DrawerCell(id: "shortcut:Ghost", title: "Ghost", icon: .symbol("square.2.layers.3d.fill"),
                              kind: .shortcut, state: .ready)

        runner.activate(cell)
        shell.finish(ShellResult(status: 1, stdout: "", stderr: "Couldn't find shortcut \"Ghost\""))

        await waitUntil { recorder.state(cell.id) == .notFound }
        XCTAssertEqual(recorder.state(cell.id), .notFound)
    }

    // MARK: - toggle

    func testToggleWritesTheOppositeReReadsAndUpdatesWithoutFolding() async {
        let recorder = Recorder()
        let control: ActionSpec.Control = .toggle(read: { true }, write: { _ in }, observe: nil)
        let runner = makeRunner(recorder: recorder, controls: [.wifi: control])
        let cell = DrawerCell(id: "action:wifi", title: "Wi-Fi", icon: .symbol("wifi"), kind: .toggle, state: .off)

        runner.activate(cell)
        // S060: `activateToggle` calls `update(id, .pending)` synchronously,
        // before the write/read `enqueue`s onto its own `Task`, so this is
        // observable the instant `activate` returns, no waiting needed.
        XCTAssertEqual(recorder.state(cell.id), .pending, "a toggle click should show pending immediately")

        await waitUntil { recorder.state(cell.id) == .on }
        XCTAssertEqual(recorder.state(cell.id), .on)
        XCTAssertFalse(recorder.events.contains("fold"), "a toggle should never fold the drawer")
    }

    private func assertToggleThrowShowsSentence(_ error: Error, _ expected: String,
                                                  file: StaticString = #filePath, line: UInt = #line) async {
        let recorder = Recorder()
        let control: ActionSpec.Control = .toggle(read: { true }, write: { _ in throw error }, observe: nil)
        let runner = makeRunner(recorder: recorder, controls: [.wifi: control])
        runner.failureDisplay = 0.05
        let cell = DrawerCell(id: "action:wifi", title: "Wi-Fi", icon: .symbol("wifi"), kind: .toggle, state: .off)

        runner.activate(cell)
        await waitUntil { recorder.state(cell.id) == .failed(expected) }
        XCTAssertEqual(recorder.state(cell.id), .failed(expected), file: file, line: line)

        await waitUntil(timeout: 2) { recorder.state(cell.id) == .off }
        XCTAssertEqual(recorder.state(cell.id), .off, "it should restore the state from before the click", file: file, line: line)
    }

    func testToggleThrowShowsTheSentenceForEachErrorTypeAndRestores() async {
        await assertToggleThrowShowsSentence(ActionError.unavailable, "Unavailable")
        await assertToggleThrowShowsSentence(ActionError.notApplied, "Didn't take")
        await assertToggleThrowShowsSentence(ActionError.failed("boom"), "boom")
        await assertToggleThrowShowsSentence(AppleScriptError.automationDenied,
                                             "Allow Drawer in System Settings > Privacy & Security > Automation")
        await assertToggleThrowShowsSentence(AppleScriptError.failed("whatever"), "Failed")
    }

    // MARK: - fire

    func testFireFoldsBeforeRunAndWaitsFoldGrace() async {
        let recorder = Recorder()
        let control: ActionSpec.Control = .fire(run: { recorder.note("run") }, destructive: false)
        let runner = makeRunner(recorder: recorder, controls: [.lockScreen: control])
        runner.foldGrace = 0.05
        let cell = DrawerCell(id: "action:lockScreen", title: "Lock screen", icon: .symbol("lock.fill"),
                              kind: .fire(destructive: false), state: .ready)

        runner.activate(cell)
        XCTAssertEqual(recorder.events, ["fold"], "fold happens before run is even scheduled")

        await waitUntil { recorder.events.contains("run") }
        XCTAssertEqual(recorder.events, ["fold", "run"])
    }

    func testFireErrorShowsTheSentenceAndRestoresToReady() async {
        let recorder = Recorder()
        let control: ActionSpec.Control = .fire(run: { throw ActionError.failed("boom") }, destructive: false)
        let runner = makeRunner(recorder: recorder, controls: [.lockScreen: control])
        runner.foldGrace = 0.01
        runner.failureDisplay = 0.05
        let cell = DrawerCell(id: "action:lockScreen", title: "Lock screen", icon: .symbol("lock.fill"),
                              kind: .fire(destructive: false), state: .ready)

        runner.activate(cell)
        await waitUntil { recorder.state(cell.id) == .failed("boom") }

        await waitUntil(timeout: 2) { recorder.state(cell.id) == .ready }
        XCTAssertEqual(recorder.state(cell.id), .ready)
    }

    func testDestructiveArmsThenRunsOnTheSecondClick() async {
        let recorder = Recorder()
        let control: ActionSpec.Control = .fire(run: { recorder.note("run") }, destructive: true)
        let runner = makeRunner(recorder: recorder, controls: [.emptyTrash: control])
        runner.foldGrace = 0.02
        runner.armWindow = 5
        let cell = DrawerCell(id: "action:emptyTrash", title: "Empty Trash", icon: .symbol("trash.fill"),
                              kind: .fire(destructive: true), state: .ready)

        runner.activate(cell)
        XCTAssertEqual(recorder.state(cell.id), .armed)
        XCTAssertFalse(recorder.events.contains("fold"), "arming should not fold the drawer")

        let armed = DrawerCell(id: cell.id, title: cell.title, icon: cell.icon, kind: cell.kind, state: .armed)
        runner.activate(armed)
        XCTAssertEqual(recorder.state(cell.id), .ready, "the second click should clear the armed ring before running")
        XCTAssertTrue(recorder.events.contains("fold"), "the second click runs it like a non-destructive fire")

        await waitUntil { recorder.events.contains("run") }
    }

    func testArmedDisarmsAfterTheArmWindow() async {
        let recorder = Recorder()
        let control: ActionSpec.Control = .fire(run: { recorder.note("run") }, destructive: true)
        let runner = makeRunner(recorder: recorder, controls: [.emptyTrash: control])
        XCTAssertEqual(runner.armWindow, 3, "S062: the shipped arm window default should be three seconds")
        runner.armWindow = 0.05
        let cell = DrawerCell(id: "action:emptyTrash", title: "Empty Trash", icon: .symbol("trash.fill"),
                              kind: .fire(destructive: true), state: .ready)

        runner.activate(cell)
        XCTAssertEqual(recorder.state(cell.id), .armed)

        await waitUntil(timeout: 1) { recorder.state(cell.id) == .ready }
        XCTAssertEqual(recorder.state(cell.id), .ready)
        XCTAssertFalse(recorder.events.contains("run"), "it should have disarmed rather than run")
    }

    /// S057/S064: `ActionRunner` and `NotchWindowController` are wired
    /// nowhere else in this suite, one calling into a fake `Recorder`, the
    /// other driven directly through its pointer seam, so nothing before
    /// this proved a fire action still runs under Always show, only that
    /// each side is independently correct. Wiring `fold` straight to a
    /// real controller's `foldForAction()`, the way `AppDelegate` does, is
    /// what actually closes that gap.
    func testFireStillRunsAndAlwaysShowStaysOpenAcrossTheRealFoldSeam() async {
        let controller = NotchWindowController()
        controller.apply(.alwaysShow)
        XCTAssertTrue(controller.model.isExpanded, "setup: Always show should already be open")

        var ran = false
        let control: ActionSpec.Control = .fire(run: { ran = true }, destructive: false)
        let runner = ActionRunner(
            controlFor: { _ in control }, launcher: FakeLauncher(), shell: FakeShell(),
            fold: { controller.foldForAction() }, update: { _, _, _ in }, openSettings: {}
        )
        runner.foldGrace = 0.02
        let cell = DrawerCell(id: "action:lockScreen", title: "Lock screen", icon: .symbol("lock.fill"),
                              kind: .fire(destructive: false), state: .ready)

        runner.activate(cell)
        await waitUntil { ran }

        XCTAssertTrue(ran, "the fire action should still run under Always show")
        XCTAssertTrue(controller.model.isExpanded, "Always show should keep the drawer open even though the runner asked to fold")
    }

    // MARK: - level

    func testLevelClickDoesNothing() {
        let recorder = Recorder()
        let runner = makeRunner(recorder: recorder)
        let cell = DrawerCell(id: "action:volume", title: "Volume", icon: .symbol("speaker.wave.2.fill"),
                              kind: .level, state: .level(0.5))
        runner.activate(cell)
        XCTAssertTrue(recorder.events.isEmpty, "a level cell's click is the slider's job, not the runner's")
    }

    func testSetLevelCoalescesRapidValues() async {
        let recorder = Recorder()
        let hardware = LevelValue()
        let control: ActionSpec.Control = .level(
            read: { await hardware.value },
            write: { value in
                recorder.note("write-start:\(value)")
                try? await Task.sleep(nanoseconds: 40_000_000)
                await hardware.set(value)
            },
            observe: nil
        )
        let runner = makeRunner(recorder: recorder, controls: [.volume: control])
        let cell = DrawerCell(id: "action:volume", title: "Volume", icon: .symbol("speaker.wave.2.fill"),
                              kind: .level, state: .level(0.1))

        runner.setLevel(cell, to: 0.01)
        await waitUntil { recorder.events.contains("write-start:0.01") }

        for i in 1...19 {
            runner.setLevel(cell, to: Double(i) / 20)
        }

        await waitUntil(timeout: 2) { recorder.events.contains("write-start:0.95") }
        XCTAssertEqual(recorder.state(cell.id), .level(19.0 / 20), "the last value should win")
        XCTAssertEqual(recorder.events.filter { $0.hasPrefix("write-start") }.count, 2,
                       "20 rapid values should coalesce into exactly one write in flight and one queued")
    }
}

private actor LevelValue {
    var value: Double = 0.1
    func set(_ value: Double) { self.value = value }
}
