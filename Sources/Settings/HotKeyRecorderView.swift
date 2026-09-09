import AppKit
import SwiftUI

/// The Open with control: a single field that shows the current chord at
/// rest and records a new one in place of it. Wraps `HotKeyRecorderControl`
/// because SwiftUI's `onKeyPress` never exposes a raw `keyCode`, and a
/// chord is defined by its key code, not by whatever character it types.
struct HotKeyRecorderView: NSViewRepresentable {
    var chord: HotKeyChord
    var onCommit: (HotKeyChord) -> Void
    var suspend: () -> Void
    var resume: () -> Void

    func makeNSView(context: Context) -> HotKeyRecorderControl {
        let view = HotKeyRecorderControl()
        view.chord = chord
        view.onCommit = onCommit
        view.suspend = suspend
        view.resume = resume
        return view
    }

    func updateNSView(_ view: HotKeyRecorderControl, context: Context) {
        view.chord = chord
        view.onCommit = onCommit
        view.suspend = suspend
        view.resume = resume
    }
}

/// A focusable field that doubles as a hot key recorder. Idle, it shows the
/// current chord's glyphs. Click it, or focus it and press Space or Return,
/// and it arms: the live chord is suspended so pressing it while typing does
/// not also toggle the drawer, and the next key down is judged as a
/// candidate rather than typed. Escape cancels back to the chord it had
/// before; Delete or Backspace clears to the default.
final class HotKeyRecorderControl: NSView {
    var chord = HotKeyChord.default { didSet { if !isArmed { needsDisplay = true } } }
    var onCommit: (HotKeyChord) -> Void = { _ in }
    var suspend: () -> Void = {}
    var resume: () -> Void = {}

    private var isArmed = false
    /// Set on a refused attempt, shown in place of "Press a combination"
    /// until the next key down or the recorder disarms.
    private var message: String?

    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        focusRingType = .none   // drawn by hand in draw(_:) instead
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Open with hot key")
    }
    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 22) }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
        NSColor.textBackgroundColor.setFill()
        path.fill()

        let focused = window?.firstResponder === self
        let borderColor: NSColor = isArmed || focused ? .controlAccentColor : .separatorColor
        path.lineWidth = isArmed || focused ? 2 : 1
        borderColor.setStroke()
        path.stroke()

        let text = isArmed ? (message ?? "Press a combination") : chord.glyphs
        let color: NSColor = message != nil ? .systemOrange : (isArmed ? .secondaryLabelColor : .labelColor)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: color,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let textRect = NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                               width: size.width, height: size.height)
        (text as NSString).draw(in: textRect, withAttributes: attrs)
        setAccessibilityValue(text)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        needsDisplay = true
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        if isArmed { cancel() }
        let accepted = super.resignFirstResponder()
        needsDisplay = true
        return accepted
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        arm()
    }

    /// Idle, only Space and Return arm the recorder; every other key is
    /// left to the normal responder chain (Tab still moves focus along).
    /// Armed, every key down is the recorder's to judge.
    override func keyDown(with event: NSEvent) {
        guard isArmed else {
            switch event.keyCode {
            case 49, 36: arm()   // Space, Return
            default: super.keyDown(with: event)
            }
            return
        }
        handleArmedKeyDown(event)
    }

    /// Armed, this has to swallow the event itself, or Command-Q, W, H and M
    /// reach the app menu before `keyDown` ever runs.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isArmed else { return super.performKeyEquivalent(with: event) }
        handleArmedKeyDown(event)
        return true
    }

    private func arm() {
        guard !isArmed else { return }
        isArmed = true
        message = nil
        suspend()
        needsDisplay = true
    }

    private func cancel() {
        isArmed = false
        message = nil
        resume()
        needsDisplay = true
    }

    private func commit(_ newChord: HotKeyChord) {
        isArmed = false
        message = nil
        chord = newChord
        needsDisplay = true
        onCommit(newChord)
    }

    private func handleArmedKeyDown(_ event: NSEvent) {
        switch event.keyCode {
        case 53: cancel(); return          // Escape
        case 51, 117: commit(.default); return   // Delete, Forward Delete
        default: break
        }

        let masked = HotKeyValidation.maskedFlags(event.modifierFlags)
        let keyCode = UInt32(event.keyCode)
        if let problem = HotKeyValidation.localProblem(keyCode: keyCode, modifierFlags: masked) {
            show(problem)
            return
        }
        let candidate = HotKeyChord(keyCode: keyCode, carbonModifiers: HotKeyValidation.carbonModifiers(from: masked))
        if let problem = HotKey.attempt(candidate) {
            show(problem)
            return
        }
        commit(candidate)
    }

    private func show(_ problem: String) {
        message = problem
        needsDisplay = true
    }
}
