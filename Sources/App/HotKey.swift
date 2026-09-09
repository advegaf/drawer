import AppKit
import Carbon

/// A chord as Carbon sees it: a virtual key code plus a Carbon modifier
/// mask. This is the one thing that gets persisted; everything else (the
/// glyphs, the menu key equivalent) is derived from it on demand.
struct HotKeyChord: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32
}

extension HotKeyChord {
    /// Command-Shift-Space: the chord Drawer ships with, and what a garbled
    /// or absent stored value falls back to.
    static let `default` = HotKeyPreset.commandShiftSpace.chord
}

/// The three chords Drawer used to offer as fixed choices. The picker is
/// gone; this only survives as the migration table for whichever of the
/// three a defaults domain still has recorded under the old key, plus the
/// source of `HotKeyChord.default`.
enum HotKeyPreset: String, CaseIterable {
    case commandShiftSpace, controlOptionSpace, optionBacktick

    var keyCode: UInt32 {
        switch self {
        case .commandShiftSpace, .controlOptionSpace: return 49   // Space
        case .optionBacktick: return 50                           // `
        }
    }

    var carbonModifiers: UInt32 {
        switch self {
        case .commandShiftSpace: return UInt32(cmdKey | shiftKey)
        case .controlOptionSpace: return UInt32(controlKey | optionKey)
        case .optionBacktick: return UInt32(optionKey)
        }
    }

    var chord: HotKeyChord { HotKeyChord(keyCode: keyCode, carbonModifiers: carbonModifiers) }
}

/// A system-wide chord that fires even when Drawer has no window and no
/// focus. AppKit has nothing for that; Carbon's Hot Key API, deprecated as it
/// is, is still the only thing that reaches an app that isn't running key
/// events through its own responder chain.
@MainActor
final class HotKey {
    private(set) var chord: HotKeyChord
    private let handler: () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    /// Set after registration; nil means the chord was claimed cleanly.
    private(set) var problem: String?

    init(chord: HotKeyChord, handler: @escaping () -> Void) {
        self.chord = chord
        self.handler = handler
        installHandler()
        register()
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    /// Releases the old chord before claiming the new one, so the two are
    /// never both held at once. If the new chord is refused, the old one is
    /// put back exactly as it was, registration and stored value both:
    /// otherwise a refused chord would leave the app with no working chord
    /// at all, plus a bad value already sitting in `chord`. Returns whether
    /// the new chord took.
    @discardableResult
    func update(chord newChord: HotKeyChord) -> Bool {
        let previous = chord
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        chord = newChord
        register()
        guard let failure = problem else { return true }
        chord = previous
        register()
        problem = failure
        return false
    }

    /// Releases the chord without replacing it: what the General page's
    /// recorder calls the moment it arms, so pressing the live chord while
    /// typing a new one does not also toggle the drawer.
    func suspend() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }

    /// Re-claims the current chord after `suspend()`: what Escape calls to
    /// cancel a recording in progress.
    func resume() {
        register()
    }

    private func installHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { hotKey.handler() }
            return noErr
        }, 1, &spec, userData, &handlerRef)
    }

    private func register() {
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x44_52_57_52), id: 1)   // 'DRWR'
        let status = RegisterEventHotKey(
            chord.keyCode, chord.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref
        )
        hotKeyRef = ref
        problem = Self.problem(for: status)
    }

    static func problem(for status: OSStatus) -> String? {
        switch status {
        case noErr: return nil
        case OSStatus(eventHotKeyExistsErr): return "That chord is taken by another app"
        default: return "Could not register the chord (status \(status))"
        }
    }

    /// Lets Carbon judge a candidate without committing to it: registers it
    /// under a second, disposable id and immediately releases it again. Only
    /// meaningful once the live chord has been suspended, or the app's own
    /// registration shows up as a false "taken" conflict against itself.
    static func attempt(_ chord: HotKeyChord) -> String? {
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x44_52_57_52), id: 2)
        let status = RegisterEventHotKey(
            chord.keyCode, chord.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref
        )
        if let ref { UnregisterEventHotKey(ref) }
        return problem(for: status)
    }
}

/// The local checks the recorder runs before ever asking Carbon, and the
/// conversion between AppKit's and Carbon's two different modifier
/// vocabularies.
enum HotKeyValidation {
    /// In order: an Fn chord first (Carbon has no dependable Fn modifier),
    /// then a chord with none of Command, Control or Option (which is also
    /// what refuses a bare Shift-plus-letter, and a bare Space, Return, Tab
    /// or Escape, since none of those carry a real modifier either).
    /// Anything that passes is Carbon's to accept or refuse.
    static func localProblem(keyCode: UInt32, modifierFlags: NSEvent.ModifierFlags) -> String? {
        if modifierFlags.contains(.function), !functionClassKeyCodes.contains(keyCode) {
            return "Drawer cannot use an Fn key here: Carbon has no dependable Fn modifier for hot keys."
        }
        let real: NSEvent.ModifierFlags = [.command, .control, .option]
        guard !modifierFlags.isDisjoint(with: real) else {
            return "Add Command, Control, or Option: Shift alone is not enough."
        }
        return nil
    }

    /// AppKit sets `.function` on these regardless of whether Fn is actually
    /// held: the arrows, the twelve F-keys, and the small cluster sharing
    /// their row (Help, Home, Page Up, Forward Delete, End, Page Down). A
    /// chord built on one of these must not be refused for a bit that was
    /// never about Fn in the first place.
    private static let functionClassKeyCodes: Set<UInt32> = [
        123, 124, 125, 126,                                     // arrows
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,  // F1-F12
        114, 115, 116, 117, 119, 121,                            // Help, Home, Page Up, Forward Delete, End, Page Down
    ]

    /// `event.modifierFlags` masked with `.deviceIndependentFlagsMask`: the
    /// mask a caller should check `localProblem` against, or the right-hand
    /// Option and Control keys carry device bits Carbon will not match.
    static func maskedFlags(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags.intersection(.deviceIndependentFlagsMask)
    }

    /// The masked flags, with `.function` stripped: what actually goes into
    /// a `HotKeyChord`, once `localProblem` has already refused an Fn chord.
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        let flags = flags.subtracting(.function)
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }
}

// MARK: - Glyphs

extension HotKeyChord {
    /// What the recorder and the menu captions show at rest: the modifiers
    /// in the standard Mac order (Control, Option, Shift, Command), then the
    /// key itself.
    var glyphs: String { modifierGlyphs + Self.keyGlyph(for: keyCode) }

    private var modifierGlyphs: String {
        var result = ""
        if carbonModifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        return result
    }

    /// Keys with no printable character of their own. Everything else goes
    /// through `UCKeyTranslate`.
    private static let namedKeys: [UInt32: String] = [
        49: "Space", 36: "Return", 48: "Tab", 51: "Delete", 53: "Escape",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    private static func keyGlyph(for keyCode: UInt32) -> String {
        namedKeys[keyCode] ?? translatedGlyph(for: keyCode)?.uppercased() ?? "?"
    }

    /// `UCKeyTranslate` on the current keyboard layout, dead keys off: without
    /// `kUCKeyTranslateNoDeadKeysBit`, Option-E, U, I, N and backtick all come
    /// back empty, since each one is a dead key on a US layout waiting on
    /// whatever letter follows it.
    fileprivate static func translatedGlyph(for keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(layoutData).takeUnretainedValue() as Data
        return data.withUnsafeBytes { rawBuffer -> String? in
            guard let keyLayout = rawBuffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return nil }
            var deadKeyState: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(
                keyLayout, UInt16(keyCode), UInt16(kUCKeyActionDown), 0,
                UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState, chars.count, &length, &chars
            )
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: length)
        }
    }
}

// MARK: - Menu key equivalent

extension HotKeyChord {
    /// The same chord, as a menu item's `keyEquivalent` and
    /// `keyEquivalentModifierMask`. A separate mapping from `glyphs`, not a
    /// reuse of it: `NSMenuItem.keyEquivalent` wants a lowercase character
    /// with `.shift` folded into the modifier mask, and the `NSXxxFunctionKey`
    /// scalars AppKit defines for non-printing keys, neither of which is what
    /// `glyphs` draws on screen.
    var menuKeyEquivalent: (key: String, modifiers: NSEvent.ModifierFlags) {
        (Self.menuKeyCharacter(for: keyCode), menuModifierFlags)
    }

    private var menuModifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if carbonModifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if carbonModifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if carbonModifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if carbonModifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        return flags
    }

    private static let menuFunctionKeyCodes: [UInt32: Int] = [
        123: NSLeftArrowFunctionKey, 124: NSRightArrowFunctionKey,
        125: NSDownArrowFunctionKey, 126: NSUpArrowFunctionKey,
        122: NSF1FunctionKey, 120: NSF2FunctionKey, 99: NSF3FunctionKey,
        118: NSF4FunctionKey, 96: NSF5FunctionKey, 97: NSF6FunctionKey,
        98: NSF7FunctionKey, 100: NSF8FunctionKey, 101: NSF9FunctionKey,
        109: NSF10FunctionKey, 103: NSF11FunctionKey, 111: NSF12FunctionKey,
    ]

    private static func menuKeyCharacter(for keyCode: UInt32) -> String {
        switch keyCode {
        case 49: return " "
        case 36: return "\r"
        case 48: return "\t"
        case 53: return "\u{1b}"
        default:
            if let scalar = menuFunctionKeyCodes[keyCode], let unicode = UnicodeScalar(scalar) {
                return String(Character(unicode))
            }
            return translatedGlyph(for: keyCode)?.lowercased() ?? ""
        }
    }
}
