import AppKit

/// Borderless, non-activating panel that floats over everything, including the
/// menu bar and full-screen apps. Non-activating matters: glancing at the
/// notch must never take focus off what you were actually doing.
final class NotchPanel: NSPanel {
    /// Supplies the right-click menu. Handled here rather than on the content
    /// view because `NSWindow.sendEvent` sees every event first. The hosting
    /// view's hit test resolves to a SwiftUI-owned subview, which has no menu
    /// of its own and may consume the click before it reaches us.
    /// The right-click point, in window coordinates, so the caller can tell a
    /// click on a cell from one on the bare bar.
    var contextMenuProvider: ((CGPoint) -> NSMenu?)?
    /// A left click on the visible chrome. Handled here for the same reason the
    /// menu is: the hit test lands on a SwiftUI subview that may consume it.
    var onClick: (() -> Void)?
    /// Asked before `onClick`, with the mouse-down point in window
    /// coordinates. Returning true means a slider drag started, and the
    /// panel treats the event as consumed rather than as a click.
    var onPress: ((CGPoint) -> Bool)?
    /// A drag in progress, the point in window coordinates. Not gated on the
    /// hit test: once a drag has started the mouse-up has to reach us even if
    /// the pointer has wandered off the card.
    var onDrag: ((CGPoint) -> Void)?
    /// The mouse-up that ends a drag, same coordinates, same reasoning.
    var onRelease: ((CGPoint) -> Void)?

    /// True only while a chord-opened drawer holds the keyboard. `canBecomeKey`
    /// reads this rather than a fixed `false`, so glancing at the notch still
    /// never takes focus, and a chord press can grab it on purpose.
    var acceptsKey = false
    /// Escape, the arrows and Return, while `acceptsKey` is true.
    var onKey: ((KeyCommand) -> Void)?
    /// Lost key status, whether to Escape, a click elsewhere or another app
    /// coming forward.
    var onResignKey: (() -> Void)?

    override func sendEvent(_ event: NSEvent) {
        guard event.type == .rightMouseDown,
              let menu = contextMenuProvider?(event.locationInWindow),
              let view = contentView,
              // Only over the visible chrome; elsewhere the panel is a hole.
              view.hitTest(event.locationInWindow) != nil
        else { return super.sendEvent(event) }

        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    override func mouseDown(with event: NSEvent) {
        guard let view = contentView, view.hitTest(event.locationInWindow) != nil else {
            return super.mouseDown(with: event)
        }
        if onPress?(event.locationInWindow) == true { return }
        onClick?()
    }

    override func mouseDragged(with event: NSEvent) {
        onDrag?(event.locationInWindow)
    }

    override func mouseUp(with event: NSEvent) {
        onRelease?(event.locationInWindow)
    }

    override func keyDown(with event: NSEvent) {
        let command: KeyCommand?
        switch event.keyCode {
        case 53: command = .escape
        case 126: command = .up
        case 125: command = .down
        case 123: command = .left
        case 124: command = .right
        case 36, 76: command = .return
        default: command = nil
        }
        guard let command else { return super.keyDown(with: event) }
        onKey?(command)
    }

    /// Swallows a command chord while `acceptsKey`, Cmd-Q included, so driving
    /// the drawer from the keyboard never leaks a keystroke to the app menu.
    /// Plain arrows, Return and Escape carry no modifier and never reach this;
    /// they go straight to `keyDown`.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        acceptsKey && event.modifierFlags.contains(.command)
    }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { acceptsKey }
    override var canBecomeMain: Bool { false }
}
