import AppKit
import Combine

protocol AppLaunching {
    func open(bundleID: String) async throws
}

protocol DetachedRunning {
    func launchDetached(_ executable: String, _ arguments: [String], onExit: @escaping @Sendable (ShellResult) -> Void) throws
}

struct WorkspaceLauncher: AppLaunching {
    func open(bundleID: String) async throws {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            throw ActionError.failed("Couldn't find that app.")
        }
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}

struct ShellRunner: DetachedRunning {
    func launchDetached(_ executable: String, _ arguments: [String], onExit: @escaping @Sendable (ShellResult) -> Void) throws {
        try Shell.launchDetached(executable, arguments, onExit: onExit)
    }
}

@MainActor
final class ActionRunner {
    private let controlFor: (ActionID) -> ActionSpec.Control
    private let launcher: AppLaunching
    private let shell: DetachedRunning
    private let fold: () -> Void
    /// Brings the drawer back after a fire action has failed. Without it the
    /// failure is real, correct and invisible: `runFireWithFold` folds before
    /// it runs, and the red ring is then drawn into a closed drawer at zero
    /// opacity. Every permission failure the keyboard lock and force quit
    /// have ever reported was lost this way.
    private let reveal: () -> Void
    private let publishCell: (String, CellState, Bool) -> Void

    /// Everything except a live level goes through here. `live` only means
    /// anything to a level bar, and every other state change is a state
    /// change rather than a value the user is dragging.
    private func update(_ id: String, _ state: CellState) { publishCell(id, state, true) }
    private let openSettings: () -> Void
    private let liveLevels: LiveLevels
    private var levelUpdates: AnyCancellable?

    var foldGrace: TimeInterval = 0.45
    var armWindow: TimeInterval = 3
    var failureDisplay: TimeInterval = 2

    private var toggleWatches: [ActionID: AnyCancellable] = [:]
    private var armTimers: [String: DispatchWorkItem] = [:]
    private var latest: [String: () async -> Void] = [:]
    private var running: Set<String> = []

    init(controlFor: @escaping (ActionID) -> ActionSpec.Control = { ActionRegistry.spec(for: $0).control },
         liveLevels: LiveLevels? = nil,
         launcher: AppLaunching, shell: DetachedRunning,
         fold: @escaping () -> Void, reveal: @escaping () -> Void = {},
         update: @escaping (String, CellState, Bool) -> Void, openSettings: @escaping () -> Void) {
        self.controlFor = controlFor
        self.launcher = launcher
        self.shell = shell
        self.fold = fold
        self.reveal = reveal
        self.publishCell = update
        self.openSettings = openSettings
        let levels = liveLevels ?? LiveLevels(controlFor: { id, _ in controlFor(id) }, targetFor: { _ in 1 })
        self.liveLevels = levels
        // Only the entries that actually changed, and only those. `states`
        // is republished whole on every write, so forwarding all of it made
        // a volume drag reassign the brightness cell on every sample.
        var previous: [ActionID: CellState] = [:]
        levelUpdates = levels.$states.sink { [weak levels] states in
            for (id, state) in states where previous[id] != state {
                update(DrawerItem.action(id.rawValue).id, state, levels?.isInteracting(with: id) ?? true)
            }
            previous = states
        }
    }

    /// Subscribes to the pinned toggles that can change without us.
    ///
    /// Two of them can: dark mode fires a distributed notification when the
    /// system appearance changes, and mute publishes on every audio device
    /// change. `ActionRegistry` has always built those publishers, and until
    /// this existed nothing subscribed to either one, so a change made
    /// anywhere else left the cell showing its old ring until the items list
    /// happened to resolve again.
    ///
    /// Called with the whole pinned set rather than one id at a time, so an
    /// item that has been removed drops its subscription with it.
    func watchToggles(_ ids: [ActionID]) {
        let wanted = Set(ids)
        toggleWatches = toggleWatches.filter { wanted.contains($0.key) }
        for id in wanted where toggleWatches[id] == nil {
            guard case .toggle(_, _, let observe) = controlFor(id), let observe else { continue }
            toggleWatches[id] = observe
                .receive(on: DispatchQueue.main)
                .sink { [weak self] on in
                    self?.update(DrawerItem.action(id.rawValue).id, on ? .on : .off)
                }
        }
    }

    func activate(_ cell: DrawerCell) {
        guard cell.state != .pending else { return }
        switch cell.kind {
        case .add:
            openSettings()
        case .launch:
            activateLaunch(cell)
        case .shortcut:
            activateShortcut(cell)
        case .toggle:
            activateToggle(cell)
        case .level:
            break
        case .fire(let destructive):
            activateFire(cell, destructive: destructive)
        }
    }

    func beginLevelInteraction(_ cell: DrawerCell) {
        guard let actionID = resolvedActionID(cell), cell.kind == .level else { return }
        liveLevels.beginInteraction(for: actionID)
    }

    func endLevelInteraction(_ cell: DrawerCell) {
        guard let actionID = resolvedActionID(cell), cell.kind == .level else { return }
        liveLevels.endInteraction(for: actionID)
    }

    func setLevel(_ cell: DrawerCell, to value: Double) {
        guard let actionID = resolvedActionID(cell), cell.kind == .level else { return }
        liveLevels.set(value, for: actionID)
    }

    // MARK: - Launch

    private func activateLaunch(_ cell: DrawerCell) {
        guard cell.state != .notInstalled else { openSettings(); return }
        let id = cell.id
        let bundleID = suffix(after: "app:", in: id)
        update(id, .pending)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.launcher.open(bundleID: bundleID)
                self.update(id, .ready)
                self.fold()
            } catch {
                self.update(id, .failed("Couldn't open"))
                try? await Task.sleep(for: .seconds(self.failureDisplay))
                self.update(id, .ready)
            }
        }
    }

    // MARK: - Shortcut

    private func activateShortcut(_ cell: DrawerCell) {
        fold()
        let id = cell.id
        let name = suffix(after: "shortcut:", in: id)
        do {
            try shell.launchDetached("/usr/bin/shortcuts", Shell.shortcutsRunArguments(name: name)) { [weak self] result in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch Shell.classify(result) {
                    case .ok:
                        break
                    case .notFound:
                        self.update(id, .notFound)
                    case .failed, .cancelled:
                        self.update(id, .failed("Failed"))
                    }
                }
            }
        } catch {
            update(id, .failed("Failed"))
        }
    }

    // MARK: - Toggle

    private func activateToggle(_ cell: DrawerCell) {
        guard cell.state != .pending, cell.state != .unavailable, cell.state != .unknown else { return }
        guard let actionID = resolvedActionID(cell),
              case .toggle(let read, let write, _) = controlFor(actionID)
        else { return }
        let id = cell.id
        let previous = cell.state
        let desired = previous == .off
        update(id, .pending)
        enqueue(id) { [weak self] in
            guard let self else { return }
            do {
                try await write(desired)
                let on = await read() ?? desired
                self.update(id, on ? .on : .off)
            } catch {
                self.update(id, .failed(self.sentence(for: error)))
                try? await Task.sleep(for: .seconds(self.failureDisplay))
                self.update(id, previous)
            }
        }
    }

    // MARK: - Fire

    private func activateFire(_ cell: DrawerCell, destructive: Bool) {
        guard let actionID = resolvedActionID(cell), case .fire(let run, _) = controlFor(actionID) else { return }
        let id = cell.id
        guard destructive else {
            runFireWithFold(id: id, run: run)
            return
        }
        guard case .armed = cell.state else {
            armWith(id: id)
            return
        }
        armTimers[id]?.cancel()
        armTimers[id] = nil
        update(id, .ready)
        runFireWithFold(id: id, run: run)
    }

    private func armWith(id: String) {
        update(id, .armed)
        let work = DispatchWorkItem { [weak self] in
            self?.armTimers[id] = nil
            self?.update(id, .ready)
        }
        armTimers[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + armWindow, execute: work)
    }

    private func runFireWithFold(id: String, run: @escaping @Sendable () async throws -> Void) {
        fold()
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(self.foldGrace))
            do {
                try await run()
            } catch {
                self.reveal()
                self.update(id, .failed(self.sentence(for: error)))
                try? await Task.sleep(for: .seconds(self.failureDisplay))
                self.update(id, .ready)
            }
        }
    }

    // MARK: - In-flight write coalescing

    private func enqueue(_ id: String, _ work: @escaping () async -> Void) {
        latest[id] = work
        guard !running.contains(id) else { return }
        running.insert(id)
        Task { @MainActor [weak self] in
            guard let self else { return }
            while let next = self.latest.removeValue(forKey: id) {
                await next()
            }
            self.running.remove(id)
        }
    }

    // MARK: - Odds and ends

    private func resolvedActionID(_ cell: DrawerCell) -> ActionID? {
        ActionID(rawValue: suffix(after: "action:", in: cell.id))
    }

    private func suffix(after prefix: String, in id: String) -> String {
        guard id.hasPrefix(prefix) else { return id }
        return String(id.dropFirst(prefix.count))
    }

    private func sentence(for error: Error) -> String {
        switch error {
        case ActionError.unavailable: return "Unavailable"
        case ActionError.notApplied: return "Didn't take"
        case ActionError.failed(let message): return message
        case AppleScriptError.automationDenied: return "Allow Drawer in System Settings > Privacy & Security > Automation"
        default: return "Failed"
        }
    }
}
