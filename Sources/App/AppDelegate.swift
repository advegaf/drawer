import AppKit
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var notchController: NotchWindowController?
    private var preferences: Preferences?
    private var settings: SettingsWindowController?
    private var statusItem: StatusItemController?
    private var resolver: ItemResolver?
    private var liveLevels: LiveLevels?
    private var runner: ActionRunner?
    private var hotKey: HotKey?
    private var guide: GuideWindowController?
    private var cancellables = Set<AnyCancellable>()

    /// The in-flight resolve, cancelled and replaced whenever `items` changes
    /// again before it finishes.
    private var resolveTask: Task<Void, Never>?
    /// Guards a resolve that finishes after a newer one has already started:
    /// only the result whose generation still matches gets applied.
    private var resolveGeneration = 0

    /// The unit bundle is hosted by this app, so `xcodebuild test` launches it
    /// for real. Without this guard every test run would put up the notch panel
    /// and wire real system state, which is not what a unit test should touch.
    private var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set here, not in the Info.plist: this call is applied at launch and
        // overrides `LSUIElement` either way. Removing the plist key alone left
        // the app registered as a UIElement with no Dock tile, which looked
        // exactly like the icon having failed to install. The user's choice
        // replaces this a moment later, once preferences exist.
        NSApp.setActivationPolicy(.regular)
        guard !isRunningTests else { return }

        let env = ProcessInfo.processInfo.environment
        #if DEBUG
        if let appearance = env["DRAWER_APPEARANCE"] {
            if appearance == "light" { NSApp.appearance = NSAppearance(named: .aqua) }
            if appearance == "dark" { NSApp.appearance = NSAppearance(named: .darkAqua) }
        }
        #endif
        let demoMode = env["DRAWER_DEMO"]
        let demo = demoMode == "1" || demoMode == "states" || demoMode == "many" || demoMode == "curated"
        let open = env["DRAWER_OPEN"] == "1"
        let edge = NotchEdge(rawValue: env["DRAWER_EDGE"] ?? "")
        let hover = Int(env["DRAWER_HOVER"] ?? "")
        #if DEBUG
        // DRAWER_ITEMS=<json> is reserved for a later phase.
        #endif

        let controller = NotchWindowController()

        // A demo run gets its own defaults domain, wiped before use, so it
        // never seeds or reads the real `hasLaunched` switch or the user's
        // saved preferences.
        let preferences: Preferences
        let defaultsStore: UserDefaults
        if demo {
            let suite = "com.advegaf.drawer.demo"
            UserDefaults.standard.removePersistentDomain(forName: suite)
            defaultsStore = UserDefaults(suiteName: suite)!
            preferences = Preferences(defaults: defaultsStore)
        } else {
            defaultsStore = .standard
            preferences = Preferences()
        }
        self.preferences = preferences

        if let edge { preferences.notchEdge = edge }

        // The curated run pins the same actions the panel fixture shows, so
        // the preview in Settings and the drawer beside it are not two
        // different drawers in one picture. The seed list is eight actions
        // chosen for a fresh install; this is six chosen for a photograph.
        if demoMode == "curated" {
            preferences.items = [.action("wifi"), .action("bluetooth"), .action("volume"),
                                 .action("darkMode"), .action("screenshot"), .action("lockScreen")]
        }

        #if DEBUG
        // A screenshot lever: DRAWER_THEME=accent=purple,bar=oled,... in
        // the compact form `Theme.demoString` writes and `init?(demoString:)`
        // reads. Set on `preferences` here, before the model reads it below,
        // for the same flash reason `notchEdge` is set above rather than
        // left to the sink.
        if let raw = env["DRAWER_THEME"], let theme = Theme(demoString: raw) {
            preferences.theme = theme
        }
        #endif

        // The stored edge and theme go in before the panel is ever put up.
        // The sinks below deliver on the next run loop turn, by which time
        // the notch has already been shown on the defaults, so without
        // this, every launch on a different edge or theme opens with a
        // flash of the old one and then crossfades away from it.
        controller.model.edge = preferences.notchEdge
        controller.model.theme = preferences.theme
        controller.hotKeyChord = preferences.hotKey

        let liveLevels = LiveLevels.system(enabled: !demo)
        self.liveLevels = liveLevels
        controller.onExpandedChange = { [weak liveLevels] visible in liveLevels?.setDrawerVisible(visible) }
        let settings = SettingsWindowController(preferences: preferences, liveLevels: demo ? nil : liveLevels)
        controller.onOpenSettings = { [weak settings] in settings?.show() }
        controller.onRemove = { [weak preferences] id in preferences?.remove(id: id) }
        self.settings = settings

        #if DEBUG
        // For a screenshot run: open Settings without waiting on first launch
        // or a click, and independent of demo mode. DRAWER_SETTINGS_PAGE
        // picks which page it opens to; an unrecognized or absent value
        // falls back to Items.
        if env["DRAWER_SETTINGS"] == "1" {
            let page = SettingsPage(rawValue: env["DRAWER_SETTINGS_PAGE"] ?? "") ?? .items
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak settings] in
                settings?.show(page: page)
            }
        }
        #endif

        let runner = ActionRunner(
            liveLevels: liveLevels,
            launcher: WorkspaceLauncher(),
            shell: ShellRunner(),
            fold: { [weak controller] in controller?.foldForAction() },
            update: { [weak controller] id, state, live in controller?.model.updateCell(id: id, state: state, live: live) },
            openSettings: { [weak settings] in settings?.show() }
        )
        // Quit App and Hide Others act on the app the user was in, not on
        // this one. Only the window controller knows which that is once the
        // chord has taken focus.
        SystemActions.appInFront = { [weak controller] in controller?.appBeforeDrawer }
        controller.onActivate = { [weak runner] cell in runner?.activate(cell) }
        controller.onSetLevel = { [weak runner] cell, value in runner?.setLevel(cell, to: value) }
        controller.onBeginLevelInteraction = { [weak runner] cell in runner?.beginLevelInteraction(cell) }
        controller.onEndLevelInteraction = { [weak runner] cell in runner?.endLevelInteraction(cell) }
        self.runner = runner

        // An app that lives on a screen edge has a real problem the first
        // time it runs: there is a small black pill against the bezel and no
        // reason to believe it does anything. So the first launch after an
        // install shows four sentences and a button, and never again. A demo
        // run skips it: its defaults domain is wiped every time, so it would
        // be the first launch on every capture.
        let guide = GuideWindowController(defaults: defaultsStore, chord: { preferences.hotKey.glyphs },
                                          openSettings: { [weak settings] in settings?.show() })
        self.guide = guide
        // A demo run never introduces itself, since its defaults are wiped
        // before every launch and every capture would be a first launch. The
        // exception is the screenshot lever, which exists to photograph this
        // window.
        var showsGuide = !demo
        #if DEBUG
        if env["DRAWER_GUIDE"] == "1" { showsGuide = true }
        #endif
        if showsGuide {
            let introduce = { [weak guide] in
                guard guide?.shouldShowOnLaunch == true else { return }
                guide?.show()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: introduce)
        }
        if !demo {
            if preferences.isFirstLaunch { controller.revealOnce() }

            // Skipped under DRAWER_DEMO: a screenshot run must not grab the chord.
            let hotKey = HotKey(chord: preferences.hotKey) { [weak controller] in
                controller?.toggleFromHotKey()
            }
            preferences.hotKeyProblem = hotKey.problem
            self.hotKey = hotKey

            // What lets the General page's recorder pause the live chord
            // while it is capturing a new one, and put it back if the
            // attempt is cancelled.
            preferences.suspendHotKey = { [weak self] in self?.hotKey?.suspend() }
            preferences.resumeHotKey = { [weak self] in self?.hotKey?.resume() }

            preferences.$hotKey
                .dropFirst()
                .receive(on: RunLoop.main)
                .sink { [weak self] chord in
                    guard let self, let hotKey = self.hotKey else { return }
                    hotKey.update(chord: chord)
                    self.preferences?.hotKeyProblem = hotKey.problem
                }
                .store(in: &cancellables)
        }

        let statusItem = StatusItemController(
            hotKeyChord: preferences.hotKey,
            onShowDrawer: { [weak controller] in controller?.toggleFromHotKey() },
            onOpenSettings: { [weak settings] in settings?.show() },
            onOpenGuide: { [weak guide] in guide?.show() }
        )
        self.statusItem = statusItem

        // Keeps "Show drawer"'s glyph in the bar and cell menus in step with
        // Settings, independent of the chord registration above, which is
        // skipped under demo.
        preferences.$hotKey
            .receive(on: RunLoop.main)
            .sink { [weak controller, weak statusItem] chord in
                controller?.hotKeyChord = chord
                statusItem?.update(hotKeyChord: chord)
            }
            .store(in: &cancellables)

        preferences.$appPresence
            .receive(on: RunLoop.main)
            .sink { presence in
                NSApp.setActivationPolicy(presence.activationPolicy)
                if presence.wantsStatusItem { statusItem.show() } else { statusItem.hide() }
            }
            .store(in: &cancellables)

        preferences.$notchVisibility
            .receive(on: RunLoop.main)
            .sink { [weak controller] in controller?.apply($0) }
            .store(in: &cancellables)

        preferences.$notchEdge
            .receive(on: RunLoop.main)
            .sink { [weak controller] in controller?.apply(edge: $0) }
            .store(in: &cancellables)

        preferences.$theme
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak controller] theme in
                controller?.model.theme = theme
                controller?.relocate()
            }
            .store(in: &cancellables)

        let resolver = ItemResolver(liveLevels: liveLevels)
        self.resolver = resolver

        preferences.$items
            .receive(on: RunLoop.main)
            .sink { [weak self, weak controller] items in
                guard let self, let controller else { return }
                self.resolveTask?.cancel()
                self.resolveGeneration += 1
                let generation = self.resolveGeneration
                self.resolveTask = Task { @MainActor in
                    var cells = await resolver.resolve(items)
                    guard generation == self.resolveGeneration, !controller.model.isDemo else { return }
                    for index in cells.indices where cells[index].kind == .level {
                        if let id = ActionID(rawValue: String(cells[index].id.dropFirst("action:".count))) {
                            cells[index].state = liveLevels.state(for: id)
                        }
                    }
                    controller.model.replaceCells(cells)
                }
            }
            .store(in: &cancellables)

        // Setting this ahead of `show()` needs no ordering trick: the sink
        // above delivers its first value a run loop turn later regardless of
        // when it was set, so it always sees this by the time it fires.
        if open { preferences.notchVisibility = .alwaysShow }

        controller.show()
        notchController = controller

        if demo {
            switch demoMode {
            case "curated": controller.model.cells = Fixtures.curated()
            case "states": controller.model.cells = Fixtures.vocabulary()
            case "many": controller.model.cells = Fixtures.cells(17)
            default: controller.model.cells = Fixtures.cells()
            }
            controller.model.isDemo = true
        }

        // The cursor poll can clear a hovered cell within a second, until
        // keyboard focus becomes its own source of truth in a later phase.
        // Enough for a screenshot taken 1.5s after launch only if the poll
        // has not already cleared it by then; not a guarantee either way.
        if open, let hover {
            // `preferences.$notchVisibility`'s sink still has its pre-`alwaysShow`
            // initial value queued for a coming run loop turn, and `apply(.onHover)`
            // clears `hoveredIndex` on its way through. A short real delay, not
            // just the next turn, is what reliably lands after that has settled.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                controller.model.hoveredIndex = hover
                controller.holdHover = true
            }
        }
    }

    @MainActor
    func showSettings() {
        settings?.show()
    }

    /// Closing the settings window must not take the app with it.
    ///
    /// The default for a Dock app is to quit once its last window closes, which
    /// here would kill the notch (the part that is actually the product)
    /// every time someone shut the settings they had just opened.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// The way back in when the notch is hidden.
    ///
    /// With no dock icon, no menu bar item and no notch on screen, there is
    /// otherwise nothing left to click, and choosing Hide would be a one-way door.
    /// Launching the app again while it is already running lands here, so
    /// opening it from Applications or Spotlight reopens settings.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows: Bool) -> Bool {
        settings?.show()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        notchController?.stop()
    }
}
