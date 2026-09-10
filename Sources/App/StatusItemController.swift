import AppKit

/// The menu bar icon, present only while `AppPresence.menuBar` is chosen.
///
/// It exists to be a way *into* the app, so it opens settings and offers Quit:
/// with no Dock tile there is otherwise nothing to right-click, and an app you
/// cannot quit is a worse problem than one you cannot see.
@MainActor
final class StatusItemController {
    private var item: NSStatusItem?
    private var showDrawerItem: NSMenuItem?
    private let onOpenSettings: () -> Void
    private let onShowDrawer: () -> Void
    private let onOpenGuide: () -> Void
    private var hotKeyChord: HotKeyChord

    init(hotKeyChord: HotKeyChord, onShowDrawer: @escaping () -> Void, onOpenSettings: @escaping () -> Void,
         onOpenGuide: @escaping () -> Void = {}) {
        self.hotKeyChord = hotKeyChord
        self.onShowDrawer = onShowDrawer
        self.onOpenSettings = onOpenSettings
        self.onOpenGuide = onOpenGuide
    }

    var isShowing: Bool { item != nil }

    func show() {
        guard item == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.icon()
        item.button?.toolTip = "Drawer"

        let menu = NSMenu()
        let showDrawer = NSMenuItem(
            title: "Show drawer", action: #selector(showDrawerAction), keyEquivalent: hotKeyChord.menuKeyEquivalent.key
        )
        showDrawer.keyEquivalentModifierMask = hotKeyChord.menuKeyEquivalent.modifiers
        showDrawer.target = self
        menu.addItem(showDrawer)
        showDrawerItem = showDrawer

        menu.addItem(
            withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ","
        ).target = self
        // The guide shows itself once, on the first launch after an install.
        // This is how anyone who dismissed it before reading it gets it back.
        menu.addItem(
            withTitle: "Guide", action: #selector(openGuide), keyEquivalent: ""
        ).target = self
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit Drawer", action: #selector(quit), keyEquivalent: "q"
        ).target = self
        item.menu = menu

        self.item = item
    }

    /// Keeps "Show drawer"'s glyph in step with a chord chosen after the
    /// status item was already built.
    func update(hotKeyChord: HotKeyChord) {
        self.hotKeyChord = hotKeyChord
        showDrawerItem?.keyEquivalent = hotKeyChord.menuKeyEquivalent.key
        showDrawerItem?.keyEquivalentModifierMask = hotKeyChord.menuKeyEquivalent.modifiers
    }

    func hide() {
        guard let item else { return }
        NSStatusBar.system.removeStatusItem(item)
        self.item = nil
    }

    /// The menu bar mark: a system symbol, not the app icon shrunk down.
    ///
    /// A template image, which is what lets macOS tint it. Dark on a light
    /// menu bar, light on a dark one, and correct against a wallpaper-tinted
    /// bar without the app knowing any of that. The full-colour app icon can do
    /// none of it: it would fight every system item beside it and ignore the
    /// user's appearance entirely.
    static func icon() -> NSImage? {
        guard let image = NSImage(systemSymbolName: "tray.fill", accessibilityDescription: "Drawer")
        else { return nil }
        // Menu bar items are laid out on an 18pt square; taller and macOS
        // clips it, shorter and it floats.
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }

    @objc private func showDrawerAction() { onShowDrawer() }
    @objc private func openSettings() { onOpenSettings() }
    @objc private func openGuide() { onOpenGuide() }
    @objc private func quit() { NSApp.terminate(nil) }
}
