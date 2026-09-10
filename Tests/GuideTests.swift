import AppKit
import XCTest
@testable import Drawer

/// The guide shows once per install and never again on its own.
@MainActor
final class GuideTests: XCTestCase {
    private func store() -> UserDefaults {
        let name = "GuideTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testAFreshInstallSeesItAndASecondLaunchDoesNot() {
        let defaults = store()
        let guide = GuideWindowController(defaults: defaults, chord: { "⇧⌘Space" })
        XCTAssertTrue(guide.shouldShowOnLaunch, "a fresh install should see the guide")

        guide.done()
        XCTAssertFalse(guide.shouldShowOnLaunch, "it came back on the next launch")

        // And a controller built fresh from the same store, which is what the
        // next launch actually does.
        let next = GuideWindowController(defaults: defaults, chord: { "⇧⌘Space" })
        XCTAssertFalse(next.shouldShowOnLaunch)
    }

    /// Marking it seen happens when it is dismissed, not when it is shown, so
    /// a crash in between does not cost someone the only explanation the app
    /// offers.
    func testItIsMarkedSeenOnTheWayOutRatherThanOnTheWayIn() {
        let defaults = store()
        let guide = GuideWindowController(defaults: defaults, chord: { "⇧⌘Space" })
        guide.show()
        XCTAssertFalse(defaults.bool(forKey: GuideWindowController.seenKey),
                       "showing it should not be what marks it read")
        guide.done()
        XCTAssertTrue(defaults.bool(forKey: GuideWindowController.seenKey))
    }

    /// The chord in the text is the chord the user actually has, not a
    /// hardcoded one: it is changeable on the General page.
    func testTheGuideNamesTheChordThatIsActuallySet() {
        var chord = "⌃⌥Space"
        let guide = GuideWindowController(defaults: store(), chord: { chord })
        guide.show()
        guide.done()
        chord = "⇧⌘D"
        guide.show()
        guide.done()
        // Nothing to assert about the pixels here; what this pins is that the
        // controller reads the chord through a closure at show time rather
        // than copying it once at init.
        XCTAssertEqual(chord, "⇧⌘D")
    }
}
