import AppKit

/// The switches that live in another app's preferences: the Finder's desktop
/// icons and hidden files, the Dock's auto-hide, the menu bar's, and the
/// battery percentage in Control Center.
///
/// Read through `CFPreferences` rather than `UserDefaults(suiteName:)`,
/// because a `UserDefaults` instance caches what it read first and these
/// values are written from outside this process, by the real System Settings
/// as well as by us. `CFPreferencesAppSynchronize` drops that cache, so a
/// cell that someone changed in System Settings a moment ago still reads
/// right.
enum SystemSwitch {
    /// The preference this switch reads and writes, and what has to be
    /// restarted for the change to show.
    struct Domain {
        let identifier: String
        let key: String
        /// Whether the value being absent means on. The Finder's
        /// `CreateDesktop` is the one that works this way: no key at all is
        /// the default, and the default is icons showing.
        let defaultsToOn: Bool
        /// The process to restart so the change takes effect. Nil where the
        /// system picks the change up on its own.
        let restarts: String?

        static let desktopIcons = Domain(identifier: "com.apple.finder", key: "CreateDesktop",
                                         defaultsToOn: true, restarts: "Finder")
        static let hiddenFiles = Domain(identifier: "com.apple.finder", key: "AppleShowAllFiles",
                                        defaultsToOn: false, restarts: "Finder")
        static let dockAutohide = Domain(identifier: "com.apple.dock", key: "autohide",
                                         defaultsToOn: false, restarts: "Dock")
        static let menuBarAutohide = Domain(identifier: "Apple Global Domain", key: "_HIHideMenuBar",
                                            defaultsToOn: false, restarts: nil)
        static let batteryPercentage = Domain(identifier: "com.apple.controlcenter", key: "BatteryShowPercentage",
                                              defaultsToOn: false, restarts: "ControlCenter")
        static let dockMagnification = Domain(identifier: "com.apple.dock", key: "magnification",
                                              defaultsToOn: false, restarts: "Dock")
        static let dockRecents = Domain(identifier: "com.apple.dock", key: "show-recents",
                                        defaultsToOn: true, restarts: "Dock")
        static let minimizeIntoIcon = Domain(identifier: "com.apple.dock", key: "minimize-to-application",
                                             defaultsToOn: false, restarts: "Dock")
        /// WindowManager watches its own domain, the way Stage Manager does,
        /// so nothing needs restarting.
        static let clickWallpaper = Domain(identifier: "com.apple.WindowManager",
                                           key: "EnableStandardClickToShowDesktop",
                                           defaultsToOn: true, restarts: nil)
        static let finderPathBar = Domain(identifier: "com.apple.finder", key: "ShowPathbar",
                                          defaultsToOn: false, restarts: "Finder")
        static let finderStatusBar = Domain(identifier: "com.apple.finder", key: "ShowStatusBar",
                                            defaultsToOn: false, restarts: "Finder")
        static let fileExtensions = Domain(identifier: "Apple Global Domain", key: "AppleShowAllExtensions",
                                           defaultsToOn: false, restarts: "Finder")
        /// `screencapture` reads its preferences on every run, so there is
        /// nothing to restart here either.
        static let screenshotThumbnail = Domain(identifier: "com.apple.screencapture", key: "show-thumbnail",
                                                defaultsToOn: true, restarts: nil)
        static let clockSeconds = Domain(identifier: "com.apple.menuextra.clock", key: "ShowSeconds",
                                         defaultsToOn: false, restarts: "ControlCenter")
    }

    static func isOn(_ domain: Domain) -> Bool? {
        CFPreferencesAppSynchronize(domain.identifier as CFString)
        guard let value = CFPreferencesCopyAppValue(domain.key as CFString, domain.identifier as CFString) else {
            return domain.defaultsToOn
        }
        return (value as? NSNumber)?.boolValue ?? domain.defaultsToOn
    }

    /// Writes through the `defaults` tool rather than `CFPreferencesSetAppValue`.
    ///
    /// Writing another app's domain from inside this process leaves the
    /// change in this process's own preferences cache as often as not: the
    /// owning app never notices, and the next read here answers with what we
    /// wrote rather than with what is true. `defaults` writes it the way the
    /// system does, and the read back below is what proves it landed.
    static func set(_ domain: Domain, on: Bool,
                    run: (String, [String]) async throws -> ShellResult = { try await Shell.run($0, $1) }) async throws {
        let result = try await run("/usr/bin/defaults",
                                   ["write", domain.identifier, domain.key, "-bool", on ? "true" : "false"])
        guard result.status == 0 else {
            throw ActionError.failed("The setting could not be written.")
        }
        if let restarts = domain.restarts {
            _ = try? await run("/usr/bin/killall", [restarts])
        }
        try await Task.sleep(nanoseconds: 400_000_000)
        guard isOn(domain) == on else { throw ActionError.notApplied }
    }

    /// Restarting the Finder or the Dock is its own action, and the same call.
    static func restart(_ process: String,
                        run: (String, [String]) async throws -> ShellResult = { try await Shell.run($0, $1) }) async throws {
        let result = try await run("/usr/bin/killall", [process])
        guard result.status == 0 else { throw ActionError.failed("\(process) could not be restarted.") }
    }
}

/// The actions that act on running apps, the screen, and the machine itself.
enum SystemActions {
    /// Whatever was in front before the drawer opened.
    ///
    /// A closure rather than a call, because the answer depends on how the
    /// drawer was opened: hovering it does not take focus, so the frontmost
    /// app is still the user's, while the chord does take focus and the
    /// window controller is the only thing that remembers what it took it
    /// from. The app wires that in at launch; the default is what the menu
    /// bar says, which is right whenever this app is not in front.
    @MainActor
    static var appInFront: () -> NSRunningApplication? = { NSWorkspace.shared.menuBarOwningApplication }

    /// Everything with a Dock tile that is not this app and not the Finder,
    /// which has no quit and would take the desktop with it.
    @MainActor
    static func otherApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular
                && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
                && $0.bundleIdentifier != "com.apple.finder"
        }
    }

    /// The app in front, which is never this one: the drawer takes focus
    /// while it is open, so `frontmostApplication` would be Drawer by the
    /// time a cell is clicked. `previousFrontmost` is passed in by the
    /// runner, which knows what was in front before the drawer opened.
    @MainActor
    static func quit(_ app: NSRunningApplication?) throws {
        guard let app, !app.isTerminated else { throw ActionError.unavailable }
        guard app.terminate() else { throw ActionError.failed("\(app.localizedName ?? "That app") would not quit.") }
    }

    /// The same target as `quit`, killed rather than asked.
    ///
    /// `terminate()` sends a quit Apple Event, which an app that is hung
    /// never answers, and hung is the whole reason anyone reaches for this.
    /// `forceTerminate()` is SIGKILL, so unsaved work is gone, which is why
    /// the cell arms first and fires on the second click.
    @MainActor
    static func forceQuit(_ app: NSRunningApplication?) throws {
        guard let app, !app.isTerminated else { throw ActionError.unavailable }
        let name = app.localizedName ?? "That app"
        guard app.forceTerminate() else { throw ActionError.failed("\(name) would not force quit.") }
    }

    @MainActor
    static func hideOthers(except front: NSRunningApplication?) throws {
        let others = otherApps().filter { $0.processIdentifier != front?.processIdentifier }
        guard !others.isEmpty else { throw ActionError.unavailable }
        for app in others { app.hide() }
    }

    /// Every volume that can be ejected: a disk image, a USB stick, a network
    /// share. The boot volume and the system's own read-only mounts are not
    /// ejectable and are skipped by `resourceValues` rather than by name.
    static func ejectableVolumes(
        manager: FileManager = .default
    ) -> [URL] {
        let keys: [URLResourceKey] = [.volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsInternalKey]
        let volumes = manager.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return volumes.filter { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return false }
            return values.volumeIsEjectable == true || values.volumeIsRemovable == true
        }
    }

    @MainActor
    static func ejectAll(volumes: [URL]? = nil, workspace: NSWorkspace = .shared) throws {
        let targets = volumes ?? ejectableVolumes()
        guard !targets.isEmpty else { throw ActionError.unavailable }
        var failed: [String] = []
        for url in targets {
            do { try workspace.unmountAndEjectDevice(at: url) }
            catch { failed.append(url.lastPathComponent) }
        }
        guard failed.isEmpty else {
            throw ActionError.failed("\(failed.joined(separator: ", ")) would not eject.")
        }
    }
}
