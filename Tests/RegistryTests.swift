import AppKit
import XCTest
@testable import Drawer

final class RegistryTests: XCTestCase {
    private func renders(_ symbol: String) -> Bool {
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) else { return false }
        return image.isValid
    }

    func testEveryActionHasASpecAndAKind() {
        for id in ActionID.allCases {
            XCTAssertNotNil(ActionRegistry.all[id], "\(id) has no spec")
            XCTAssertNotNil(ActionRegistry.kind[id], "\(id) has no kind")
        }
    }

    func testEverySymbolInTheTableRenders() {
        for spec in ActionRegistry.all.values {
            XCTAssertTrue(renders(spec.symbol), "\(spec.id) symbol \"\(spec.symbol)\" did not render")
        }
    }

    func testBluetoothSymbolIsTheFallbackAndRenders() {
        let spec = ActionRegistry.spec(for: .bluetooth)
        XCTAssertEqual(spec.symbol, "dot.radiowaves.left.and.right", "bluetooth is not an SF Symbol name")
        XCTAssertTrue(renders(spec.symbol))
    }

    func testFixtureSymbolsRender() {
        for cell in Fixtures.cells(5) {
            guard case .symbol(let name) = cell.icon else { continue }
            XCTAssertTrue(renders(name), "fixture symbol \"\(name)\" did not render")
        }
    }

    private func isUnavailable(_ id: ActionID) -> Bool {
        isUnavailable(ActionRegistry.spec(for: id).control)
    }

    private func isUnavailable(_ control: ActionSpec.Control) -> Bool {
        if case .unavailable = control { return true }
        return false
    }

    func testTheNineActionsWiredThisPhaseHaveARealControl() {
        let wired: [ActionID] = [.wifi, .darkMode, .mute, .volume, .keepAwake, .sleep, .emptyTrash, .screenshot, .stageManager]
        for id in wired {
            XCTAssertFalse(isUnavailable(id), "\(id) should have a real control by now")
        }
    }

    func testBluetoothNightShiftBrightnessAndLockScreenNowHaveARealControlOnThisMac() {
        for id: ActionID in [.bluetooth, .nightShift, .brightness, .lockScreen] {
            XCTAssertFalse(isUnavailable(id), "\(id) should have a real control now that its private symbols resolved")
        }
    }

    func testControlForWithANilHandleIsUnavailableForEachPrivateID() {
        XCTAssertTrue(isUnavailable(ActionRegistry.control(for: .bluetooth, bluetooth: nil)))
        XCTAssertTrue(isUnavailable(ActionRegistry.control(for: .brightness, brightness: nil)))
        XCTAssertTrue(isUnavailable(ActionRegistry.control(for: .lockScreen, lockScreen: nil)))
        XCTAssertTrue(isUnavailable(ActionRegistry.control(for: .nightShift, nightShift: nil)))
    }

    func testWifiDarkModeVolumeMuteKeepAwakeAndStageManagerReadsCompleteWithoutThrowing() async {
        for id: ActionID in [.wifi, .mute, .keepAwake, .stageManager] {
            guard case .toggle(let read, _, _) = ActionRegistry.spec(for: id).control else {
                XCTFail("\(id) is not a toggle")
                continue
            }
            _ = await read()
        }

        guard case .level(let volumeRead, _, _) = ActionRegistry.spec(for: .volume).control else {
            XCTFail("volume is not a level")
            return
        }
        _ = await volumeRead()

        guard case .toggle(let darkModeRead, _, _) = ActionRegistry.spec(for: .darkMode).control else {
            XCTFail("darkMode is not a toggle")
            return
        }
        let darkMode = await darkModeRead()
        XCTAssertNotNil(darkMode, "darkMode reads the global domain, so absent should read as false, not nil")
    }

    func testKeepAwakeWriteTrueThenReadTrueThenWriteFalseThenReadFalse() async throws {
        guard case .toggle(let read, let write, _) = ActionRegistry.spec(for: .keepAwake).control else {
            XCTFail("keepAwake is not a toggle")
            return
        }
        defer { try? ActionRegistry.KeepAwake.set(false) }

        try await write(true)
        let on = await read()
        XCTAssertEqual(on, true)

        try await write(false)
        let off = await read()
        XCTAssertEqual(off, false)
    }
}
