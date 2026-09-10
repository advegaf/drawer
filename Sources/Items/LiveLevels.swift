import AppKit
import Combine
import CoreGraphics

@MainActor
final class LiveLevels: ObservableObject {
    @Published private(set) var states: [ActionID: CellState] = [:]

    private struct Write {
        let value: Double
        let generation: UInt64
    }

    private final class Entry {
        var target: UInt32?
        var generation: UInt64 = 0
        var control: ActionSpec.Control = .unavailable
        var observation: AnyCancellable?
        var write: Write?
        var needsRead = false
        var isInteracting = false
        var interactionInvalidated = false
        var worker: Task<Void, Never>?
        var waiters: [CheckedContinuation<CellState, Never>] = []
    }

    private let controlFor: (ActionID, UInt32) -> ActionSpec.Control
    private let targetFor: (ActionID) -> UInt32?
    private let isWedged: (ActionID) -> Bool
    private let enabled: Bool
    private let pollInterval: Duration
    private var entries: [ActionID: Entry] = [:]
    private var volumeChanges: AnyCancellable?
    private var displayChanges: AnyCancellable?
    private var wakeChanges: AnyCancellable?
    private var tickSubscription: AnyCancellable?
    private let usesExternalTicks: Bool
    private var visibleInterest = false
    private var polling: Task<Void, Never>?
    private var drawerVisible = false
    private var settingsVisible = false
    private var settingsWindowKey = false

    init(enabled: Bool = true,
         controlFor: @escaping (ActionID, UInt32) -> ActionSpec.Control = LiveLevels.systemControl,
         targetFor: @escaping (ActionID) -> UInt32? = LiveLevels.systemTarget,
         isWedged: @escaping (ActionID) -> Bool = PrivateCall.isWedged,
         volumeChanges: AnyPublisher<Void, Never>? = nil,
         ticks: AnyPublisher<Void, Never>? = nil,
         pollInterval: Duration = .milliseconds(100)) {
        self.enabled = enabled
        self.controlFor = controlFor
        self.targetFor = targetFor
        self.isWedged = isWedged
        self.pollInterval = pollInterval
        self.usesExternalTicks = ticks != nil
        if let ticks {
            tickSubscription = ticks.receive(on: DispatchQueue.main).sink { [weak self] in self?.pollBrightness() }
        }
        if enabled, let volumeChanges {
            self.volumeChanges = volumeChanges.receive(on: DispatchQueue.main).sink { [weak self] in
                self?.refresh(.volume)
            }
        }
        if enabled {
            wakeChanges = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
                .receive(on: DispatchQueue.main).sink { [weak self] _ in
                    self?.refresh(.volume)
                    self?.refresh(.brightness)
                }
            displayChanges = NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
                .receive(on: DispatchQueue.main).sink { [weak self] _ in
                    self?.refresh(.brightness)
                }
        }
    }

    deinit { polling?.cancel() }

    static func system(enabled: Bool = true) -> LiveLevels {
        LiveLevels(enabled: enabled, volumeChanges: enabled ? AudioOutput.changes : nil)
    }

    func state(for id: ActionID) -> CellState {
        states[id] ?? .unknown
    }

    func value(for id: ActionID) async -> CellState {
        guard enabled, Self.supports(id) else { return .unknown }
        let entry = entry(for: id)
        synchronizeTarget(id, entry: entry)
        if let state = states[id], !entry.needsRead, entry.worker == nil { return state }
        return await withCheckedContinuation { continuation in
            entry.waiters.append(continuation)
            if entry.worker == nil { entry.needsRead = true }
            start(id, entry: entry)
        }
    }

    func refresh(_ id: ActionID) {
        guard enabled, Self.supports(id) else { return }
        let entry = entry(for: id)
        // Nothing to do while the user is dragging. `run` refuses to read
        // during an interaction anyway, so going further would only
        // resolve the target and spin up a worker that immediately exits.
        // Volume pays this on every single write, because CoreAudio
        // reports the app's own change back to it as an external one.
        // `endInteraction` sets `needsRead` itself, so the reconciling
        // read on release still happens and nothing is missed.
        guard !entry.isInteracting else { return }
        synchronizeTarget(id, entry: entry)
        entry.needsRead = true
        start(id, entry: entry)
    }

    /// Whether this level is being dragged right now.
    ///
    /// The drawn bar wants to know: a value the user is dragging has to
    /// land instantly, and a value that arrived from a key or another app
    /// has to be animated into place.
    func isInteracting(with id: ActionID) -> Bool { entries[id]?.isInteracting ?? false }

    func beginInteraction(for id: ActionID) {
        guard enabled, Self.supports(id) else { return }
        let entry = entry(for: id)
        synchronizeTarget(id, entry: entry)
        guard !entry.isInteracting else { return }
        entry.isInteracting = true
        entry.interactionInvalidated = false
    }

    func endInteraction(for id: ActionID) {
        guard enabled, let entry = entries[id], entry.isInteracting else { return }
        entry.isInteracting = false
        entry.interactionInvalidated = false
        synchronizeTarget(id, entry: entry)
        entry.needsRead = true
        start(id, entry: entry)
    }

    func set(_ value: Double, for id: ActionID) {
        guard enabled, Self.supports(id), value.isFinite else { return }
        let entry = entry(for: id)
        synchronizeTarget(id, entry: entry)
        guard !entry.interactionInvalidated else { return }
        guard entry.target != nil, !isWedged(id), case .level = entry.control else {
            publish(.unavailable, for: id, entry: entry)
            return
        }
        entry.generation &+= 1
        let value = min(1, max(0, value))
        entry.write = Write(value: value, generation: entry.generation)
        publish(.level(value), for: id, entry: entry)
        start(id, entry: entry)
    }

    func setDrawerVisible(_ visible: Bool) {
        drawerVisible = visible
        updateVisibility()
    }

    func setSettingsVisible(_ visible: Bool) {
        settingsVisible = visible
        updateVisibility()
    }

    func setSettingsWindowKey(_ key: Bool) {
        settingsWindowKey = key
        updateVisibility()
    }

    private var visible: Bool { drawerVisible || (settingsVisible && settingsWindowKey) }

    private func updateVisibility() {
        guard enabled, visible != visibleInterest else { return }
        visibleInterest = visible
        if visible {
            refresh(.volume)
            refresh(.brightness)
            guard !usesExternalTicks else { return }
            let interval = pollInterval
            polling = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: interval) } catch { return }
                    self?.pollBrightness()
                }
            }
        } else {
            polling?.cancel()
            polling = nil
        }
    }

    private func pollBrightness() {
        guard enabled, visible, !isWedged(.brightness), entries[.brightness]?.worker == nil else { return }
        refresh(.brightness)
    }

    private func entry(for id: ActionID) -> Entry {
        if let entry = entries[id] { return entry }
        let entry = Entry()
        entries[id] = entry
        return entry
    }

    private func synchronizeTarget(_ id: ActionID, entry: Entry) {
        let target = targetFor(id)
        guard target != entry.target else { return }
        if entry.isInteracting { entry.interactionInvalidated = true }
        entry.target = target
        entry.generation &+= 1
        entry.write = nil
        entry.needsRead = true
        entry.observation = nil
        entry.control = target.map { controlFor(id, $0) } ?? .unavailable
        publish(target == nil ? .unavailable : .unknown, for: id, entry: entry)
        if case .level(_, _, let observe) = entry.control, let observe {
            entry.observation = observe.receive(on: DispatchQueue.main).sink { [weak self, weak entry] value in
                guard let self, let entry, entry.target == target else { return }
                self.synchronizeTarget(id, entry: entry)
                guard !self.isWedged(id) else {
                    self.publish(.unavailable, for: id, entry: entry)
                    return
                }
                guard entry.target == target else { self.start(id, entry: entry); return }
                if entry.isInteracting || entry.worker != nil || entry.write != nil {
                    entry.needsRead = true
                } else if value.isFinite {
                    self.publish(.level(min(1, max(0, value))), for: id, entry: entry)
                } else {
                    self.publish(.unavailable, for: id, entry: entry)
                }
            }
        }
    }

    private func start(_ id: ActionID, entry: Entry) {
        guard entry.worker == nil else { return }
        entry.worker = Task { [weak self] in
            guard let self else { return }
            await self.run(id, entry: entry)
        }
    }

    private func run(_ id: ActionID, entry: Entry) async {
        defer {
            entry.worker = nil
            let waiters = entry.waiters
            entry.waiters.removeAll()
            for waiter in waiters { waiter.resume(returning: state(for: id)) }
        }
        while entry.needsRead || entry.write != nil {
            synchronizeTarget(id, entry: entry)
            guard !isWedged(id), entry.target != nil,
                  case .level(let read, let write, _) = entry.control else {
                entry.write = nil
                entry.needsRead = false
                publish(.unavailable, for: id, entry: entry)
                return
            }
            let generation = entry.generation
            let target = entry.target
            if let pending = entry.write {
                entry.write = nil
                guard pending.generation == generation else { continue }
                do {
                    try await write(pending.value)
                    synchronizeTarget(id, entry: entry)
                    guard generation == entry.generation, target == entry.target else { continue }
                    entry.needsRead = true
                } catch {
                    synchronizeTarget(id, entry: entry)
                    guard generation == entry.generation, target == entry.target else { continue }
                    entry.needsRead = false
                    publish(isWedged(id) ? .unavailable : .failed("Could not change level"), for: id, entry: entry)
                }
            } else {
                guard !entry.isInteracting else { return }
                entry.needsRead = false
                let value = await read()
                synchronizeTarget(id, entry: entry)
                guard generation == entry.generation, target == entry.target else { continue }
                if isWedged(id) {
                    entry.needsRead = false
                    publish(.unavailable, for: id, entry: entry)
                    return
                }
                if entry.isInteracting {
                    entry.needsRead = true
                    continue
                }
                if let value, value.isFinite {
                    publish(.level(min(1, max(0, value))), for: id, entry: entry)
                } else {
                    publish(.unavailable, for: id, entry: entry)
                }
            }
        }
    }

    private func publish(_ state: CellState, for id: ActionID, entry: Entry) {
        if states[id] != state { states[id] = state }
    }

    private static func supports(_ id: ActionID) -> Bool { id == .volume || id == .brightness }

    nonisolated private static func systemTarget(_ id: ActionID) -> UInt32? {
        id == .volume ? AudioOutput.defaultDeviceID() : CGMainDisplayID()
    }

    nonisolated private static func systemControl(_ id: ActionID, target: UInt32) -> ActionSpec.Control {
        if id == .volume {
            return .level(read: { AudioOutput.volume(device: target) },
                          write: { try AudioOutput.setVolume($0, device: target) }, observe: nil)
        }
        guard let brightness = PrivateAPI.brightness else { return .unavailable }
        return .level(read: {
            await PrivateCall.run(.brightness) { () -> Double? in
                var value: Float = 0
                guard brightness.get(target, &value) == 0 else { return nil }
                return Double(value)
            } ?? nil
        }, write: { value in
            guard let status = await PrivateCall.run(.brightness, { brightness.set(target, Float(value)) }), status == 0 else {
                throw ActionError.unavailable
            }
        }, observe: nil)
    }
}
