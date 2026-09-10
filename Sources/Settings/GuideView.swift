import AppKit
import SwiftUI

/// What Drawer says the first time it is opened, and nothing after that.
///
/// An app that lives on a screen edge has a real problem the first time it
/// runs: there is a small black pill against the bezel and no reason to
/// believe it does anything. This is four sentences and a button, shown once
/// per install, and reachable afterwards from the menu bar item for anyone
/// who dismissed it before reading it.
struct GuideView: View {
    let chord: String
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsStyle.s24) {
            HStack(spacing: SettingsStyle.s16) {
                Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                    .resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .frame(width: 56, height: 56)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: SettingsStyle.s4) {
                    Text("Drawer")
                        .settingsFont(SettingsStyle.sectionHeading)
                        .foregroundStyle(SettingsStyle.ink)
                        .accessibilityAddTraits(.isHeader)
                    Text("A drawer at the edge of the screen.")
                        .settingsFont(SettingsStyle.body)
                        .foregroundStyle(SettingsStyle.textSecondary)
                }
            }

            VStack(alignment: .leading, spacing: SettingsStyle.s16) {
                tip("Point at the edge", "hand.point.up.left",
                    "The pill on the right edge unfolds when the pointer reaches it, and folds away when it leaves.")
                tip("Open it from anywhere", "command",
                    "Press \(chord). The drawer holds the keyboard while it is open, so the arrows move between items and Escape closes it.")
                tip("Fill it from the library", "square.grid.2x2",
                    "Settings has every action, app and shortcut. Drag one onto the preview, or use the Add button on its row.")
                tip("Some actions ask once", "lock.shield",
                    "Keyboard and media actions need Accessibility, and dark mode needs Automation. macOS asks the first time you use one.")
            }

            HStack(spacing: SettingsStyle.s12) {
                Text("This shows once. The menu bar item brings it back.")
                    .settingsFont(SettingsStyle.captionLight)
                    .foregroundStyle(SettingsStyle.textSecondary)
                Spacer(minLength: SettingsStyle.s16)
                Button("Get started", action: onDone)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("guide-done")
            }
        }
        .padding(SettingsStyle.s32)
        .frame(width: 520)
        .background(SettingsStyle.canvas)
        .onExitCommand(perform: onDone)
    }

    private func tip(_ title: String, _ symbol: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: SettingsStyle.s12) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(SettingsStyle.accent)
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SettingsStyle.s2) {
                Text(title)
                    .settingsFont(SettingsStyle.bodyMedium)
                    .foregroundStyle(SettingsStyle.ink)
                Text(detail)
                    .settingsFont(SettingsStyle.body)
                    .foregroundStyle(SettingsStyle.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Owns the one window the guide gets, so a second call brings the existing
/// one forward rather than opening another.
@MainActor
final class GuideWindowController {
    static let seenKey = "hasSeenGuide"

    private var window: NSWindow?
    private let defaults: UserDefaults
    private let chord: () -> String
    /// Where Get started goes. The guide says to fill the drawer from the
    /// library, so the button opens the page the library is on rather than
    /// leaving someone to find it.
    private let openSettings: () -> Void

    init(defaults: UserDefaults = .standard, chord: @escaping () -> String,
         openSettings: @escaping () -> Void = {}) {
        self.defaults = defaults
        self.chord = chord
        self.openSettings = openSettings
    }

    /// Whether a fresh install should see it. The screenshot lever forces it
    /// so the guide can be captured without wiping anything.
    var shouldShowOnLaunch: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["DRAWER_GUIDE"] == "1" { return true }
        #endif
        return !defaults.bool(forKey: Self.seenKey)
    }

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        // A guide has nothing to minimise and nothing to zoom, and two dead
        // grey circles beside the close button read as an unfinished window.
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.title = "Drawer"
        window.contentView = NSHostingView(rootView: GuideView(chord: chord(), onDone: { [weak self] in self?.done() }))
        window.center()
        window.isReleasedWhenClosed = false
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    /// Marking it seen happens on the way out rather than on the way in, so
    /// a crash between the two does not cost someone the only explanation
    /// the app offers.
    func done() {
        defaults.set(true, forKey: Self.seenKey)
        window?.close()
        window = nil
        openSettings()
    }
}
