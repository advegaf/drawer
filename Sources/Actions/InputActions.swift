import AppKit
import CoreGraphics
import SwiftUI

/// The one permission this batch shares.
///
/// Posting a key, swallowing a key, and pasting all go through the same
/// door: macOS will not let a process synthesise or intercept input unless
/// it is trusted for Accessibility. Asking is a system prompt this app
/// cannot draw itself, so the first attempt opens it and says what happened
/// rather than failing silently, which is what an untrusted `CGEvent.post`
/// does.
enum InputPermission {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Opens the system prompt, once. macOS shows it only the first time a
    /// process asks; after that the switch has to be found in System
    /// Settings, so the message says where.
    @discardableResult
    static func request() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func require() throws {
        guard !isTrusted else { return }
        request()
        throw ActionError.failed("Allow Drawer in System Settings > Privacy & Security > Accessibility")
    }
}

/// The transport keys, sent the way a keyboard sends them.
///
/// Not an AppleScript to a named player: this is the system-wide media key,
/// so whatever is playing answers it, the same as pressing the key on the
/// keyboard. Music, a browser tab, a video call's own player.
enum MediaKeys {
    /// The `NX_KEYTYPE_` constants, which are not exposed to Swift.
    enum Key: Int32 {
        case playPause = 16
        case next = 17
        case previous = 18
    }

    @MainActor
    static func press(_ key: Key, post: (NSEvent) -> Void = { $0.cgEvent?.post(tap: .cghidEventTap) }) throws {
        try InputPermission.require()
        for isDown in [true, false] {
            let data1 = Int((key.rawValue << 16) | (isDown ? 0x0A00 : 0x0B00))
            guard let event = NSEvent.otherEvent(
                with: .systemDefined, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1
            ) else { throw ActionError.failed("The key could not be sent.") }
            post(event)
        }
    }
}

/// Paste, with the formatting taken off first.
///
/// The clipboard keeps every flavour a copy put on it, and a paste picks the
/// richest one the destination accepts. This drops all of them but the
/// string, then sends Command V, so the text lands in the destination's own
/// font instead of the source's.
enum PlainPaste {
    @MainActor
    static func run(pasteboard: NSPasteboard = .general,
                    post: (CGEvent?) -> Void = { $0?.post(tap: .cghidEventTap) }) throws {
        try InputPermission.require()
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else {
            throw ActionError.failed("There is no text on the clipboard.")
        }
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            throw ActionError.failed("The clipboard could not be rewritten.")
        }
        let source = CGEventSource(stateID: .combinedSessionState)
        let v: CGKeyCode = 9
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: isDown)
            event?.flags = .maskCommand
            post(event)
        }
    }
}

/// Locks the keyboard so it can be wiped.
///
/// A dark screen with a countdown, and every key that arrives while it is up
/// goes nowhere. Without the tap, a cloth across the keyboard types into
/// whatever was in front, renames files, and answers dialogs.
///
/// The way out is deliberately not a key: Escape held for a second, or the
/// button. A single Escape would end the lock the first time a cloth brushed
/// it.
@MainActor
final class KeyboardCleaning: NSObject {
    static let shared = KeyboardCleaning()

    static let duration: TimeInterval = 30
    /// How long Escape has to be held to end it early.
    static let escapeHold: TimeInterval = 1

    private var window: NSWindow?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var timer: Timer?
    private var escapeDown: Date?
    private(set) var remaining: TimeInterval = 0
    var isRunning: Bool { window != nil }

    /// Called every second while the lock is up, so the drawer's own cell can
    /// count down with it.
    var onTick: ((TimeInterval) -> Void)?

    func start(duration: TimeInterval = KeyboardCleaning.duration) throws {
        guard !isRunning else { return }
        try InputPermission.require()
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(
                (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
                    | (1 << CGEventType.flagsChanged.rawValue)),
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let cleaning = Unmanaged<KeyboardCleaning>.fromOpaque(context).takeUnretainedValue()
                // macOS switches a tap off when it takes too long to answer,
                // and when something takes secure input. Without turning it
                // back on the overlay would keep saying the keyboard is
                // locked while every key went through to whatever is behind
                // it, which is the one failure this must not have.
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    MainActor.assumeIsolated { cleaning.reenable() }
                    return nil
                }
                MainActor.assumeIsolated { cleaning.saw(type: type, event: event) }
                // Nothing is passed on: that is the whole point.
                return nil
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            throw ActionError.failed("The keyboard could not be locked.")
        }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        remaining = duration
        present()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.remaining -= 1
                self.onTick?(self.remaining)
                self.refresh()
                if self.remaining <= 0 { self.stop() }
            }
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil; escapeDown = nil
        window?.orderOut(nil); window = nil
        remaining = 0
        onTick?(0)
    }

    func reenable() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// Escape held, rather than pressed: a cloth dragged across the keyboard
    /// hits Escape as readily as anything else.
    private func saw(type: CGEventType, event: CGEvent) {
        let escape: Int64 = 53
        guard event.getIntegerValueField(.keyboardEventKeycode) == escape else { return }
        switch type {
        case .keyDown:
            if escapeDown == nil { escapeDown = Date() }
            if let escapeDown, Date().timeIntervalSince(escapeDown) >= Self.escapeHold { stop() }
        case .keyUp:
            escapeDown = nil
        default:
            break
        }
    }

    private func present() {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = .screenSaver
        window.backgroundColor = .black
        window.isOpaque = true
        window.ignoresMouseEvents = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.contentView = NSHostingView(rootView: KeyboardCleaningView(cleaning: self))
        window.orderFrontRegardless()
        self.window = window
    }

    /// The countdown is drawn by a SwiftUI view reading `remaining`, and a
    /// borderless window does not redraw on its own when a plain property
    /// changes, so the hosting view is rebuilt on each tick.
    private func refresh() {
        window?.contentView = NSHostingView(rootView: KeyboardCleaningView(cleaning: self))
    }
}

private struct KeyboardCleaningView: View {
    let cleaning: KeyboardCleaning

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "keyboard")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(.white.opacity(0.9))
            Text("Keyboard locked")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.white)
            Text("Wipe away. Keys do nothing until this ends.")
                .font(.system(size: 16))
                .foregroundStyle(.white.opacity(0.65))
            Text("\(Int(max(0, cleaning.remaining)))")
                .font(.system(size: 76, weight: .thin).monospacedDigit())
                .foregroundStyle(.white)
                .contentTransition(.numericText())
            Button("Done") { cleaning.stop() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            Text("or hold Escape")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.45))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}
