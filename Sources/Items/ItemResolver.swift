import AppKit

@MainActor
final class ItemResolver {
    private var iconCache: [String: (title: String, icon: NSImage)] = [:]
    private let controlFor: (ActionID) -> ActionSpec.Control
    private let liveLevels: LiveLevels

    init(controlFor: @escaping (ActionID) -> ActionSpec.Control = { ActionRegistry.spec(for: $0).control },
         liveLevels: LiveLevels? = nil) {
        self.controlFor = controlFor
        self.liveLevels = liveLevels ?? LiveLevels(controlFor: { id, _ in controlFor(id) }, targetFor: { _ in 1 })
    }

    func resolve(_ items: [DrawerItem]) async -> [DrawerCell] {
        let indexed = await withTaskGroup(of: (Int, DrawerCell).self) { group in
            for (index, item) in items.enumerated() {
                group.addTask { (index, await self.cell(for: item)) }
            }
            var collected: [(Int, DrawerCell)] = []
            collected.reserveCapacity(items.count)
            for await pair in group { collected.append(pair) }
            return collected
        }
        return indexed.sorted { $0.0 < $1.0 }.map(\.1)
    }

    func invalidateIcons() {
        iconCache.removeAll()
    }

    private func cell(for item: DrawerItem) async -> DrawerCell {
        switch item {
        case .app(let bundleID):
            return resolveApp(id: item.id, bundleID: bundleID)
        case .action(let raw):
            return await resolveAction(id: item.id, raw: raw)
        case .shortcut(let name):
            return DrawerCell(id: item.id, title: name, icon: .symbol("square.2.layers.3d.fill"),
                              kind: .shortcut, state: .ready)
        }
    }

    private func resolveApp(id: String, bundleID: String) -> DrawerCell {
        if let cached = iconCache[bundleID] {
            return DrawerCell(id: id, title: cached.title, icon: .image(cached.icon),
                              kind: .launch, state: .ready)
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return DrawerCell(id: id, title: bundleID, icon: .symbol("app.dashed"),
                              kind: .launch, state: .notInstalled)
        }
        let title = displayName(for: url)
        let icon = NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false))
        iconCache[bundleID] = (title, icon)
        return DrawerCell(id: id, title: title, icon: .image(icon), kind: .launch, state: .ready)
    }

    private func displayName(for url: URL) -> String {
        let bundle = Bundle(url: url)
        if let name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, !name.isEmpty {
            return name
        }
        if let name = bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String, !name.isEmpty {
            return name
        }
        return url.deletingPathExtension().lastPathComponent
    }

    private func resolveAction(id: String, raw: String) async -> DrawerCell {
        guard let actionID = ActionID(rawValue: raw) else {
            return DrawerCell(id: id, title: raw, icon: .symbol("questionmark.circle"),
                              kind: .fire(destructive: false), state: .unavailable)
        }
        let spec = ActionRegistry.spec(for: actionID)
        let kind = ActionRegistry.kind[actionID] ?? .fire(destructive: false)
        let resolved: CellState
        if kind == .level {
            resolved = await liveLevels.value(for: actionID)
        } else if Self.wedged.contains(actionID) || PrivateCall.isWedged(actionID) {
            resolved = .unavailable
        } else if let read = await state(for: controlFor(actionID)) {
            resolved = PrivateCall.isWedged(actionID) ? .unavailable : read
        } else {
            // A private symbol that never answers (IOBluetooth has been seen
            // to deadlock inside its own coordinator) must not hold the whole
            // list hostage, and must not be asked again this session: every
            // retry would park another thread on the same lock.
            Self.wedged.insert(actionID)
            Log.drawer.error("\(actionID.rawValue, privacy: .public) read timed out; unavailable for this session")
            resolved = .unavailable
        }
        return DrawerCell(id: id, title: spec.title, icon: .symbol(spec.symbol), kind: kind, state: resolved)
    }

    /// Actions whose read never returned. Reset only by relaunch.
    static var wedged: Set<ActionID> = []

    /// How long a state read may take before the action is written off.
    static var readTimeout: Duration = .seconds(2)

    /// Nil when the read did not answer in time.
    private func timed<T: Sendable>(_ read: @escaping @Sendable () async -> T?) async -> T?? {
        await withTaskGroup(of: T??.self) { group in
            group.addTask { .some(await ActionRegistry.read(read)) }
            group.addTask {
                try? await Task.sleep(for: Self.readTimeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Nil means the read timed out, which the caller treats as wedged.
    private func state(for control: ActionSpec.Control) async -> CellState? {
        switch control {
        case .unavailable:
            return .unavailable
        case .toggle(let read, _, _):
            guard let value = await timed(read) else { return nil }
            return value.map { $0 ? .on : .off } ?? .unknown
        case .level:
            return .unknown
        case .fire:
            return .ready
        }
    }
}
