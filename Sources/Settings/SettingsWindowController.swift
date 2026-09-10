import AppKit
import SwiftUI

/// Hosts the settings sheet in its own window.
///
/// A real window rather than a panel attached to the notch: settings are a place
/// you go, not something you glance at, and a floating panel that follows the
/// notch would be one more thing hovering over the screen edge.
@MainActor
final class SettingsWindowController: NSObject {
    private var session = SettingsSession()
    private var window: NSWindow?
    private let preferences: Preferences
    private let liveLevels: LiveLevels?
    private var levelVisibilityObservers: [NSObjectProtocol] = []
    private let shortcuts = ShortcutsCatalog()
    private let apps = AppCatalog()
    private var keyObserver: NSObjectProtocol?

    init(preferences: Preferences, liveLevels: LiveLevels? = nil) {
        self.preferences = preferences
        self.liveLevels = liveLevels
        super.init()
    }

    /// Bring the window to the front from an accessory app.
    ///
    /// `makeKeyAndOrderFront` plus `activate` is not enough on its own here:
    /// an app with no dock icon is not always allowed to pull itself in front
    /// of whatever the user is working in, and the window then opens silently
    /// behind everything. `orderFrontRegardless` is the part that does not ask
    /// permission, and it is why the window appears at all.
    private func surface(_ window: NSWindow) {
        if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
            let available = window.contentRect(forFrameRect: visible).size
            window.contentMinSize = Self.minimum(fitting: available)
            window.setFrame(Self.clampedFrame(window.frame, to: visible), display: false)
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    /// `page` only matters the first time this ever opens a window: once the
    /// window exists it is only ever surfaced again, same as before, so
    /// there is no path that would need to steer an already-open window to
    /// a different page. The orb and the menus keep calling `show()` with no
    /// page, which lands on `.items`; only the DEBUG screenshot lever in
    /// `AppDelegate` ever passes one, and it always runs against a fresh
    /// launch.
    func show(page: SettingsPage = .items) {
        if let window {
            surface(window)
            return
        }

        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 720)
        // Tall on purpose, and as tall as the screen allows short of
        // filling it. The preview canvas is a fraction of the page height
        // (`ItemsPage.canvasHeight`), so the window's own height is what
        // decides whether the drawer is legible without dragging the
        // window bigger first, which is what the user was doing.
        let contentSize = CGSize(width: min(960, visible.width), height: min(1000, max(200, visible.height - 40)))
        let window = DrawerSettingsWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentMinSize = Self.minimum(fitting: CGSize(width: visible.width, height: max(200, visible.height - 40)))
        window.title = "Drawer Settings"
        window.toolbarStyle = .unified
        session = SettingsSession(page: page)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // Two things here are load bearing, and both are about the
        // sidebar's collapse button. It is an item the split view vends,
        // not one drawn anywhere in this app, and it only reaches the
        // titlebar if SwiftUI owns the window: hence no `NSToolbar` of our
        // own, which used to be installed with a delegate that vended
        // nothing and won over SwiftUI's, and hence the hosting view being
        // the content view rather than a subview pinned to
        // `contentLayoutGuide`, which was also what held the sidebar down
        // below the titlebar instead of level with the traffic lights.
        //
        // The cost is that SwiftUI now sizes this window to what the page
        // says it needs, so what the page says has to be true. See the
        // note on the section header's subtitle, which on its own asked
        // for a window as tall as the screen.
        window.contentView = NSHostingView(
            rootView: SettingsView(preferences: preferences, shortcuts: shortcuts, apps: apps,
                                   initialPage: page, undoManager: window.editorUndoManager, editor: window.editorState, liveLevels: liveLevels, session: session)
        )
        window.center()
        window.isReleasedWhenClosed = false
        self.window = window

        // Registered before `surface(window)`: `makeKeyAndOrderFront` inside
        // it is what posts this notification, so an observer added after
        // would miss the very first show.
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.shortcuts.reload() }
        }

        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            let observer = NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self, weak window] notification in
                MainActor.assumeIsolated {
                    self?.liveLevels?.setSettingsWindowKey(notification.name == NSWindow.didBecomeKeyNotification && window?.isKeyWindow == true)
                }
            }
            levelVisibilityObservers.append(observer)
        }
        surface(window)
        window.makeFirstResponder(nil)
    }
    /// The window's fixed floor, clamped to what the display leaves.
    ///
    /// The clamp only bites on a display shorter than the minimum, a 13
    /// inch with its dock showing, say. There the window is smaller than
    /// its own minimum and the page cannot fit; the split view is top
    /// aligned so the overflow goes off the bottom rather than up over the
    /// traffic lights.
    static func minimum(fitting available: CGSize) -> CGSize {
        CGSize(width: min(SettingsStyle.windowMinimum.width, available.width),
               height: min(SettingsStyle.windowMinimum.height, available.height))
    }

    static func clampedFrame(_ frame: CGRect, to visible: CGRect) -> CGRect {
        let size = CGSize(width: min(frame.width, visible.width), height: min(frame.height, visible.height))
        return CGRect(x: min(max(frame.minX, visible.minX), visible.maxX - size.width),
                      y: min(max(frame.minY, visible.minY), visible.maxY - size.height),
                      width: size.width, height: size.height)
    }
}

private final class DrawerSettingsWindow: NSWindow {
    let editorUndoManager = UndoManager()
    let editorState = DrawerEditor()

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard editorState.ownsUndoFocus, !(firstResponder is NSTextView), event.modifierFlags.contains(.command),
              event.charactersIgnoringModifiers?.lowercased() == "z" else {
            return super.performKeyEquivalent(with: event)
        }
        if event.modifierFlags.contains(.shift) { editorUndoManager.redo() }
        else { editorUndoManager.undo() }
        return true
    }
}
