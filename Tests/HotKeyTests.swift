import Carbon
import XCTest
@testable import Drawer

@MainActor
final class HotKeyTests: XCTestCase {
    func testProblemMapsTheTwoKnownStatuses() {
        XCTAssertNil(HotKey.problem(for: noErr))
        XCTAssertEqual(HotKey.problem(for: OSStatus(eventHotKeyExistsErr)), "That chord is taken by another app")
        XCTAssertEqual(HotKey.problem(for: -1), "Could not register the chord (status -1)")
    }

    func testAChordRoundTripsThroughPreferencesAndDefaultsToCommandShiftSpace() {
        let suite = "com.advegaf.drawer.tests.hotkey"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = Preferences(defaults: defaults)
        XCTAssertEqual(first.hotKey, .default)
        XCTAssertEqual(first.hotKey, HotKeyChord(keyCode: 49, carbonModifiers: UInt32(cmdKey | shiftKey)))

        let recorded = HotKeyChord(keyCode: 0, carbonModifiers: UInt32(controlKey | optionKey))   // Control-Option-A
        first.hotKey = recorded
        let second = Preferences(defaults: defaults)
        XCTAssertEqual(second.hotKey, recorded)
    }

    func testEachOldPresetMigratesToTheSameKeyCodeAndModifiersItHad() {
        let suite = "com.advegaf.drawer.tests.hotkey.migration"
        let defaults = UserDefaults(suiteName: suite)!
        for preset in HotKeyPreset.allCases {
            defaults.removePersistentDomain(forName: suite)
            defaults.set(preset.rawValue, forKey: "hotKey")

            let preferences = Preferences(defaults: defaults)

            XCTAssertEqual(preferences.hotKey.keyCode, preset.keyCode, "\(preset) key code")
            XCTAssertEqual(preferences.hotKey.carbonModifiers, preset.carbonModifiers, "\(preset) modifiers")
            // S364: "written under the new key" is `loadHotKeyChord`'s own
            // job (Preferences.swift), separate from the value it returns;
            // reading the raw defaults back is what actually pins that half
            // of the sentence, not just the decoded chord equality above.
            guard let data = defaults.data(forKey: "hotKeyChord"),
                  let stored = try? JSONDecoder().decode(HotKeyChord.self, from: data) else {
                XCTFail("\(preset) should have been written under the new hotKeyChord key on first read")
                continue
            }
            XCTAssertEqual(stored, preset.chord, "\(preset) written under the new key")
        }
        defaults.removePersistentDomain(forName: suite)
    }

    /// S329: `HotKey.update(chord:)` unregisters the old chord before it
    /// registers the new one (`HotKey.swift`'s own comment says so), not
    /// something `NotchWindowController`'s pointer seam reaches. `attempt`
    /// is the same registration-conflict probe
    /// `testRefusedRegistrationRollsBackToThePreviousChordAndKeepsItRegistered`
    /// already uses below: registering a chord elsewhere only succeeds if
    /// nothing else is currently holding it.
    func testUpdateReleasesTheOldChordBeforeClaimingTheNew() {
        let oldChord = HotKeyChord(keyCode: 40, carbonModifiers: UInt32(controlKey | optionKey | cmdKey))
        let newChord = HotKeyChord(keyCode: 41, carbonModifiers: UInt32(controlKey | optionKey | cmdKey))
        let hotKey = HotKey(chord: oldChord) {}
        XCTAssertNil(hotKey.problem, "setup: the old chord should have registered cleanly")

        let succeeded = hotKey.update(chord: newChord)

        XCTAssertTrue(succeeded)
        XCTAssertEqual(hotKey.chord, newChord)
        XCTAssertNil(HotKey.attempt(oldChord), "the old chord should be released: registering it elsewhere should now succeed")
        XCTAssertEqual(HotKey.attempt(newChord), "That chord is taken by another app",
                       "the new chord should be the one hotKey now holds")
    }

    func testAChordWithNoRealModifierIsRefused() {
        // A plain letter, no modifier at all.
        XCTAssertNotNil(HotKeyValidation.localProblem(keyCode: 0, modifierFlags: []))
    }

    func testAShiftOnlyChordIsRefused() {
        XCTAssertNotNil(HotKeyValidation.localProblem(keyCode: 0, modifierFlags: [.shift]))
    }

    func testABareSpaceIsRefused() {
        XCTAssertNotNil(HotKeyValidation.localProblem(keyCode: 49, modifierFlags: []))
    }

    func testARealModifierClearsLocalValidation() {
        XCTAssertNil(HotKeyValidation.localProblem(keyCode: 0, modifierFlags: [.command]))
    }

    func testAnFnChordIsRefusedWithItsOwnMessage() {
        let problem = HotKeyValidation.localProblem(keyCode: 0, modifierFlags: [.function, .command])
        XCTAssertEqual(problem, "Drawer cannot use an Fn key here: Carbon has no dependable Fn modifier for hot keys.")
    }

    /// AppKit sets `.function` on an arrow or F-key event whether or not Fn
    /// is actually held, so those two chords must not trip the Fn refusal.
    func testAnArrowOrFunctionKeyChordIsNotMistakenForAnFnChord() {
        XCTAssertNil(HotKeyValidation.localProblem(keyCode: 126, modifierFlags: [.command, .function]))   // Up arrow
        XCTAssertNil(HotKeyValidation.localProblem(keyCode: 96, modifierFlags: [.command, .function]))    // F5
    }

    func testGlyphsForCommandShiftSpace() {
        let chord = HotKeyChord(keyCode: 49, carbonModifiers: UInt32(cmdKey | shiftKey))
        XCTAssertEqual(chord.glyphs, "⇧⌘Space")
    }

    func testGlyphsForOptionBacktick() {
        let chord = HotKeyChord(keyCode: 50, carbonModifiers: UInt32(optionKey))
        XCTAssertEqual(chord.glyphs, "⌥`")
    }

    func testGlyphsForAPlainLetterChord() {
        let chord = HotKeyChord(keyCode: 0, carbonModifiers: UInt32(cmdKey))   // Command-A
        XCTAssertEqual(chord.glyphs, "⌘A")
    }

    func testMenuKeyEquivalentForALetterChord() {
        let chord = HotKeyChord(keyCode: 0, carbonModifiers: UInt32(cmdKey))
        let equivalent = chord.menuKeyEquivalent
        XCTAssertEqual(equivalent.key, "a")
        XCTAssertEqual(equivalent.modifiers, [.command])
    }

    func testMenuKeyEquivalentForAnArrowChord() {
        let chord = HotKeyChord(keyCode: 126, carbonModifiers: UInt32(cmdKey))   // Command-UpArrow
        let equivalent = chord.menuKeyEquivalent
        XCTAssertEqual(equivalent.key, String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)))
        XCTAssertEqual(equivalent.modifiers, [.command])
    }

    func testRefusedRegistrationRollsBackToThePreviousChordAndKeepsItRegistered() {
        // Two obscure, unlikely-to-collide-with-anything-real chords, so the
        // conflict this test provokes is the only one at play.
        let takenChord = HotKeyChord(keyCode: 34, carbonModifiers: UInt32(controlKey | optionKey | cmdKey))
        let workingChord = HotKeyChord(keyCode: 35, carbonModifiers: UInt32(controlKey | optionKey | cmdKey))

        let blocker = HotKey(chord: takenChord) {}
        XCTAssertNil(blocker.problem)

        let hotKey = HotKey(chord: workingChord) {}
        XCTAssertNil(hotKey.problem)

        let succeeded = hotKey.update(chord: takenChord)

        XCTAssertFalse(succeeded)
        XCTAssertEqual(hotKey.problem, "That chord is taken by another app")
        XCTAssertEqual(hotKey.chord, workingChord, "the previous chord is still the stored one")

        // Still registered: a second attempt at the same chord now finds it
        // taken too, which is only possible if `hotKey` is still holding it.
        XCTAssertEqual(HotKey.attempt(workingChord), "That chord is taken by another app")
    }

    func testAtLeastOneKeyboardInputSourceIsEnabled() {
        XCTAssertGreaterThanOrEqual(Preferences.enabledKeyboardInputSourceCount, 1)
    }
}

/// `HotKeyRecorderControl` is a plain `NSView`; its `mouseDown`, `keyDown`
/// and `performKeyEquivalent` overrides are ordinary methods a synthetic
/// `NSEvent` can drive directly, the same way `ControllerTests` calls
/// `pointerDown(at:)` directly instead of routing through real mouse
/// events. `arm()`, `cancel()`, `commit()` and `isArmed` itself are
/// private, so every assertion below reads back through `chord`,
/// `onCommit`, `suspend` and `resume`, exactly what a real caller
/// (`GeneralPage`, `AppDelegate`) has to work with too.
@MainActor
final class HotKeyRecorderControlTests: XCTestCase {
    private func click() -> NSEvent {
        NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                           windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    private func key(_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                         windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                         isARepeat: false, keyCode: keyCode)!
    }

    /// S358: clicking arms the recorder and suspends the live chord so
    /// pressing it while typing does not also toggle the drawer.
    func testClickArmsTheRecorderAndSuspendsTheLiveChord() {
        let control = HotKeyRecorderControl()
        var suspended = false
        control.suspend = { suspended = true }
        control.mouseDown(with: click())
        XCTAssertTrue(suspended, "clicking the field should suspend the live chord")
    }

    /// S359: an armed, Carbon-accepted candidate becomes the new chord at
    /// once. The bar and cell menus picking it up is `MenuTests`
    /// `testShowDrawerCarriesEachPresetsChordInTurn`'s to prove, a pure
    /// function of whatever chord `preferences.hotKey` (which `onCommit`
    /// feeds directly) holds; nothing about that path is specific to a
    /// preset.
    func testArmedValidChordCommitsAndUpdatesTheField() {
        let control = HotKeyRecorderControl()
        control.chord = HotKeyChord(keyCode: 1, carbonModifiers: UInt32(cmdKey))
        control.suspend = {}
        var committed: HotKeyChord?
        control.onCommit = { committed = $0 }
        control.mouseDown(with: click())

        let candidate = HotKeyChord(keyCode: 42, carbonModifiers: UInt32(controlKey | optionKey))
        XCTAssertTrue(control.performKeyEquivalent(with: key(42, [.control, .option])))

        XCTAssertEqual(committed, candidate)
        XCTAssertEqual(control.chord, candidate)
    }

    /// S360: Escape cancels back to the chord the recorder had before, and
    /// resumes it.
    func testEscapeWhileArmedCancelsAndResumesThePreviousChord() {
        let control = HotKeyRecorderControl()
        let original = HotKeyChord(keyCode: 1, carbonModifiers: UInt32(cmdKey))
        control.chord = original
        control.suspend = {}
        var resumed = false
        control.resume = { resumed = true }
        control.mouseDown(with: click())

        XCTAssertTrue(control.performKeyEquivalent(with: key(53)))   // Escape

        XCTAssertTrue(resumed, "Escape should resume the suspended chord")
        XCTAssertEqual(control.chord, original, "cancelling should not change the stored chord")
    }

    /// S361: Delete or Forward Delete clears to the default chord instead
    /// of being judged as a candidate.
    func testDeleteWhileArmedClearsToTheDefaultChord() {
        let control = HotKeyRecorderControl()
        control.chord = HotKeyChord(keyCode: 1, carbonModifiers: UInt32(cmdKey))
        control.suspend = {}
        var committed: HotKeyChord?
        control.onCommit = { committed = $0 }
        control.mouseDown(with: click())

        XCTAssertTrue(control.performKeyEquivalent(with: key(51)))   // Delete

        XCTAssertEqual(committed, .default)
        XCTAssertEqual(control.chord, .default)
    }

    /// S362: a candidate with no real modifier is refused and the recorder
    /// stays armed. A refusal alone does not prove "stays armed"; a
    /// following valid chord still being judged (rather than falling
    /// through to the idle Space/Return-only path) does.
    func testArmedBareKeyIsRefusedAndTheRecorderStaysArmedToTryAgain() {
        let control = HotKeyRecorderControl()
        control.suspend = {}
        var committed: HotKeyChord?
        control.onCommit = { committed = $0 }
        control.mouseDown(with: click())

        XCTAssertTrue(control.performKeyEquivalent(with: key(49)))   // bare Space, no modifier
        XCTAssertNil(committed, "a bare space should not commit a chord")

        let candidate = HotKeyChord(keyCode: 43, carbonModifiers: UInt32(controlKey | optionKey))
        XCTAssertTrue(control.performKeyEquivalent(with: key(43, [.control, .option])))
        XCTAssertEqual(committed, candidate, "a valid chord right after a refusal should still commit, proving the recorder stayed armed")
    }

    /// S363: a candidate another app already holds is refused with
    /// Carbon's own message, and the chord that app was already holding
    /// (`liveHotKey`, standing in for the one `AppDelegate` keeps live)
    /// stays registered throughout, never suspended by the refusal.
    func testArmedChordAlreadyTakenIsRefusedAndThePreviousChordStaysRegistered() {
        let takenChord = HotKeyChord(keyCode: 44, carbonModifiers: UInt32(controlKey | optionKey | cmdKey))
        let blocker = HotKey(chord: takenChord) {}
        XCTAssertNil(blocker.problem, "setup: the blocking chord should register cleanly")
        let previous = HotKeyChord(keyCode: 45, carbonModifiers: UInt32(controlKey | optionKey | cmdKey))
        let liveHotKey = HotKey(chord: previous) {}
        XCTAssertNil(liveHotKey.problem, "setup: the previous chord should register cleanly")

        let control = HotKeyRecorderControl()
        control.chord = previous
        control.suspend = {}
        var committed: HotKeyChord?
        control.onCommit = { committed = $0 }
        control.mouseDown(with: click())

        XCTAssertTrue(control.performKeyEquivalent(with: key(44, [.control, .option, .command])))

        XCTAssertNil(committed, "a taken chord should not commit")
        XCTAssertEqual(control.chord, previous, "the field should keep showing the previous chord")
        XCTAssertEqual(HotKey.attempt(previous), "That chord is taken by another app",
                       "liveHotKey should still be holding the previous chord")
    }
}
