import Carbon
import Combine
import Foundation
import ServiceManagement
import os

/// What the user has chosen, kept in `UserDefaults`.
@MainActor
final class Preferences: ObservableObject {
    /// How much of itself the notch shows at rest.
    @Published var notchVisibility: NotchVisibility {
        didSet { defaults.set(notchVisibility.rawValue, forKey: Keys.visibility) }
    }

    /// Which screen edge the notch is welded to.
    @Published var notchEdge: NotchEdge {
        didSet { defaults.set(notchEdge.rawValue, forKey: Keys.edge) }
    }

    /// Where the app itself shows up: Dock, menu bar, or nowhere.
    @Published var appPresence: AppPresence {
        didSet { defaults.set(appPresence.rawValue, forKey: Keys.presence) }
    }

    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != Self.isRegisteredForLogin else { return }
            applyLaunchAtLogin()
        }
    }

    /// Set when the login-item request was refused, so the UI can say so rather
    /// than quietly flipping the switch back.
    @Published private(set) var launchAtLoginProblem: String?

    /// The chord that opens the drawer pinned, from anywhere.
    @Published var hotKey: HotKeyChord {
        didSet {
            guard let data = try? JSONEncoder().encode(hotKey) else { return }
            defaults.set(data, forKey: Keys.hotKeyChord)
        }
    }

    /// Set when the chord could not be registered, so Settings can say so.
    @Published var hotKeyProblem: String?

    /// Suspends and resumes the one live, system-wide chord registration
    /// while the General page's recorder is capturing a new one. Set by
    /// `AppDelegate`; nil in tests and previews, which have no live
    /// registration to touch.
    var suspendHotKey: (() -> Void)?
    var resumeHotKey: (() -> Void)?

    /// What's pinned to the notch, in order.
    @Published var items: [DrawerItem] {
        didSet { defaults.set(DrawerItem.encodeList(items), forKey: Keys.items) }
    }

    @Published var theme: Theme {
        didSet {
            guard let data = try? JSONEncoder().encode(theme) else { return }
            defaults.set(data, forKey: Keys.theme)
        }
    }

    private let defaults: UserDefaults
    private enum Keys {
        static let hasLaunched = "hasLaunchedBefore"
        static let visibility = "notchVisibility"
        static let presence = "appPresence"
        static let edge = "notchEdge"
        static let items = "items"
        /// The old chord key: three fixed presets, stored by raw string.
        /// Read once for migration, never written again.
        static let hotKey = "hotKey"
        /// The new chord key: any `HotKeyChord`, stored as JSON.
        static let hotKeyChord = "hotKeyChord"
        static let theme = "theme"
    }

    /// Pinned on a fresh install, so the notch has something to show before
    /// anyone has chosen anything for themselves.
    private static let seedItems: [DrawerItem] = [
        .action("wifi"), .action("bluetooth"), .action("darkMode"), .action("nightShift"),
        .action("volume"), .action("brightness"), .action("keepAwake"), .action("mute"),
    ]

    /// True the very first time this copy runs, and never again.
    ///
    /// Deliberately *not* inferred from "there is nothing pinned yet": that is
    /// also true of someone who removed every item, and re-introducing them to
    /// the app every launch would be worse than never introducing them at all.
    let isFirstLaunch: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isFirstLaunch = !defaults.bool(forKey: Keys.hasLaunched)
        defaults.set(true, forKey: Keys.hasLaunched)
        // Absent means never chosen, which is the hover behaviour the app was
        // designed around. Not hidden, which would make a fresh install look
        // like it failed to start.
        self.notchVisibility = defaults.string(forKey: Keys.visibility)
            .flatMap(NotchVisibility.init(rawValue:)) ?? .onHover
        // Absent means never chosen. The Dock is the default because it is the
        // findable one. A new user who cannot see the app anywhere has no way
        // to learn it is running.
        self.appPresence = defaults.string(forKey: Keys.presence)
            .flatMap(AppPresence.init(rawValue:)) ?? .dock
        // The right edge is where the notch has always been, and it is the one
        // side of a Mac that no system chrome claims by default. It is also
        // where an install that had chosen the bottom edge lands, since
        // `NotchEdge(rawValue: "bottom")` is nil now that the case is gone
        // and this falls back rather than crashing.
        self.notchEdge = defaults.string(forKey: Keys.edge)
            .flatMap(NotchEdge.init(rawValue:)) ?? .right
        self.hotKey = Self.loadHotKeyChord(defaults: defaults)
        // Absent or undecodable both fall back to the default look, the same
        // way a garbled hotkey or edge falls back rather than crashing.
        self.theme = defaults.data(forKey: Keys.theme)
            .flatMap { try? JSONDecoder().decode(Theme.self, from: $0) } ?? .default
        // Read from the system rather than from our own store: the user can turn
        // this off in System Settings, and a remembered `true` would then be a lie.
        self.launchAtLogin = Self.isRegisteredForLogin

        // Setting `items` here does not run its own `didSet`: Swift does not
        // call a property observer for the assignment that gives a property
        // its first value inside its own class's initializer. So a blob that
        // fails to decode can be read as empty for this run without that
        // emptiness overwriting the very data it failed to make sense of.
        // Seeded when the key has never been written, not when the list is
        // empty: someone who removed every item has a stored empty list, and
        // must not find the seed back on the next launch.
        if let data = defaults.data(forKey: Keys.items) {
            self.items = DrawerItem.decodeList(data)
        } else {
            let seeded = Self.seedItems
            self.items = seeded
            defaults.set(DrawerItem.encodeList(seeded), forKey: Keys.items)
        }
    }

    @discardableResult
    func commit(_ edit: DrawerEdit, undoManager: UndoManager? = nil) -> Bool {
        guard let updated = edit.applying(to: items) else { return false }
        let previous = DrawerItemPosition(id: edit.itemID, in: items)
        items = updated
        registerUndo(previous, actionName: edit.actionName, undoManager: undoManager)
        return true
    }

    private func registerUndo(_ position: DrawerItemPosition, actionName: String, undoManager: UndoManager?) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { [weak undoManager] preferences in
            let inverse = DrawerItemPosition(id: position.id, in: preferences.items)
            let restored = position.restoring(in: preferences.items)
            guard restored != preferences.items else { return }
            preferences.items = restored
            preferences.registerUndo(inverse, actionName: actionName, undoManager: undoManager)
        }
        undoManager.setActionName(actionName)
    }

    @discardableResult
    func commitApps(_ additions: [DrawerItem], before neighbor: String?, undoManager: UndoManager? = nil) -> Bool {
        guard !additions.isEmpty, additions.allSatisfy({ if case .app = $0 { return true }; return false }),
              Set(additions.map(\.id)).count == additions.count,
              !additions.contains(where: { addition in items.contains { $0.id == addition.id } }) else { return false }
        let index: Int
        if let neighbor {
            guard let found = items.firstIndex(where: { $0.id == neighbor }) else { return false }
            index = found
        } else { index = items.count }
        let previous = additions.map { DrawerItemPosition(id: $0.id, in: items) }
        var updated = items
        updated.insert(contentsOf: additions, at: index)
        items = updated
        registerBatchUndo(previous, undoManager: undoManager)
        return true
    }

    private func registerBatchUndo(_ positions: [DrawerItemPosition], undoManager: UndoManager?) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { [weak undoManager] preferences in
            let inverse = positions.map { DrawerItemPosition(id: $0.id, in: preferences.items) }
            let restored = positions.reversed().reduce(preferences.items) { $1.restoring(in: $0) }
            guard restored != preferences.items else { return }
            preferences.items = restored
            preferences.registerBatchUndo(inverse, undoManager: undoManager)
        }
        undoManager.setActionName("Add apps")
    }

    @discardableResult
    func add(_ item: DrawerItem) -> Bool {
        commit(.add(item, before: nil))
    }

    func remove(id: String) {
        commit(.remove(id: id))
    }

    // MARK: - Hot key

    /// The new JSON chord if one is already stored; otherwise the old
    /// three-preset string, converted and written under the new key so this
    /// only runs once; otherwise the default.
    private static func loadHotKeyChord(defaults: UserDefaults) -> HotKeyChord {
        if let data = defaults.data(forKey: Keys.hotKeyChord),
           let chord = try? JSONDecoder().decode(HotKeyChord.self, from: data) {
            return chord
        }
        guard let raw = defaults.string(forKey: Keys.hotKey), let preset = HotKeyPreset(rawValue: raw) else {
            return .default
        }
        let chord = preset.chord
        if let data = try? JSONEncoder().encode(chord) {
            defaults.set(data, forKey: Keys.hotKeyChord)
        }
        return chord
    }

    // MARK: - Login item

    static var isRegisteredForLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    // MARK: - Keyboard input sources

    /// How many keyboard layouts are enabled and selectable right now.
    static var enabledKeyboardInputSourceCount: Int {
        let filter: [String: Any] = [
            kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
            kTISPropertyInputSourceIsEnabled as String: true,
            kTISPropertyInputSourceIsSelectCapable as String: true,
        ]
        guard let sources = TISCreateInputSourceList(filter as CFDictionary, false)?
            .takeRetainedValue() as? [TISInputSource]
        else { return 0 }
        return sources.count
    }

    private func applyLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginProblem = nil
        } catch {
            // Commonly refused for an app running from a build directory rather
            // than /Applications, which is worth saying plainly.
            Log.drawer.error("launch at login failed: \(error.localizedDescription, privacy: .public)")
            launchAtLoginProblem = "macOS refused this: try moving Drawer to /Applications."
            launchAtLogin = Self.isRegisteredForLogin
        }
    }
}
