import Combine
import XCTest
@testable import Drawer

@MainActor
private final class LevelHardware {
    var value: Double? = 0.25
    var readCount = 0
    var writes: [Double] = []
    var activeCalls = 0
    var maximumActiveCalls = 0
    var delayRead = false
    var delayWrite = false
    var failWrite = false
    var readStarted: XCTestExpectation?
    var writeStarted: XCTestExpectation?
    var readContinuation: CheckedContinuation<Void, Never>?
    var writeContinuation: CheckedContinuation<Void, Never>?
    let observed = PassthroughSubject<Double, Never>()

    func control() -> ActionSpec.Control {
        .level(read: { await self.read() }, write: { try await self.write($0) },
               observe: observed.eraseToAnyPublisher())
    }

    private func read() async -> Double? {
        activeCalls += 1
        maximumActiveCalls = max(maximumActiveCalls, activeCalls)
        defer { activeCalls -= 1 }
        readCount += 1
        let snapshot = value
        if delayRead {
            await withCheckedContinuation { continuation in
                readContinuation = continuation
                readStarted?.fulfill()
                readStarted = nil
            }
        } else {
            readStarted?.fulfill()
            readStarted = nil
        }
        return snapshot
    }

    private func write(_ value: Double) async throws {
        activeCalls += 1
        maximumActiveCalls = max(maximumActiveCalls, activeCalls)
        defer { activeCalls -= 1 }
        writes.append(value)
        if delayWrite {
            await withCheckedContinuation { continuation in
                writeContinuation = continuation
                writeStarted?.fulfill()
                writeStarted = nil
            }
        } else {
            writeStarted?.fulfill()
            writeStarted = nil
        }
        if failWrite { throw ActionError.unavailable }
        self.value = value
    }

    func finishRead() {
        delayRead = false
        readContinuation?.resume()
        readContinuation = nil
    }

    func finishWrite() {
        delayWrite = false
        writeContinuation?.resume()
        writeContinuation = nil
    }
}

@MainActor
final class LiveLevelsTests: XCTestCase {
    private func owner(_ hardware: LevelHardware, ticks: PassthroughSubject<Void, Never>? = nil) -> LiveLevels {
        LiveLevels(controlFor: { _, _ in hardware.control() }, targetFor: { _ in 1 },
                   isWedged: { _ in false }, ticks: ticks?.eraseToAnyPublisher())
    }

    private func state(_ expected: CellState, from levels: LiveLevels, id: ActionID = .volume) async {
        if levels.state(for: id) == expected { return }
        let changed = expectation(description: "level state changed")
        let subscription = levels.$states.first { $0[id] == expected }.sink { _ in changed.fulfill() }
        await fulfillment(of: [changed], timeout: 1)
        withExtendedLifetime(subscription) {}
    }

    /// CoreAudio reports the app's own volume write back to it as though
    /// somebody else had made it, so every write during a drag arrived as
    /// a refresh. `run` already refused to read while interacting, so all
    /// that refresh ever did was resolve the target again and spin up a
    /// worker that exited on the next line. Now it returns before any of
    /// that, and the read on release still happens.
    func testARefreshDuringADragDoesNoWorkAndStillReconcilesOnRelease() async {
        let hardware = LevelHardware()
        let levels = owner(hardware)
        _ = await levels.value(for: .volume)
        let baseline = hardware.readCount

        levels.beginInteraction(for: .volume)
        levels.set(0.4, for: .volume)
        // One per write, which is what the echo would look like.
        for _ in 0..<5 { levels.refresh(.volume) }
        _ = await levels.value(for: .volume)
        XCTAssertEqual(hardware.readCount, baseline, "a refresh during a drag read the hardware")
        XCTAssertEqual(levels.state(for: .volume), .level(0.4), "a refresh during a drag moved the bar")

        levels.endInteraction(for: .volume)
        _ = await levels.value(for: .volume)
        XCTAssertEqual(hardware.readCount, baseline + 1, "the read on release did not happen")
    }

    /// What the drawn bar asks to decide whether to animate.
    func testIsInteractingFollowsTheDrag() {
        let levels = owner(LevelHardware())
        XCTAssertFalse(levels.isInteracting(with: .volume))
        levels.beginInteraction(for: .volume)
        XCTAssertTrue(levels.isInteracting(with: .volume))
        XCTAssertFalse(levels.isInteracting(with: .brightness), "one drag marked another level")
        levels.endInteraction(for: .volume)
        XCTAssertFalse(levels.isInteracting(with: .volume))
    }

    func testInteractionDefersReadsBetweenSpacedWritesAndReconcilesOnce() async {
        let hardware = LevelHardware()
        let levels = owner(hardware)
        _ = await levels.value(for: .brightness)
        levels.beginInteraction(for: .brightness)
        for value in [0.3, 0.5, 0.8] {
            levels.set(value, for: .brightness)
            XCTAssertEqual(levels.state(for: .brightness), .level(value))
            _ = await levels.value(for: .brightness)
            levels.refresh(.brightness)
            _ = await levels.value(for: .brightness)
            XCTAssertEqual(hardware.readCount, 1)
        }
        XCTAssertEqual(hardware.writes, [0.3, 0.5, 0.8])
        levels.endInteraction(for: .brightness)
        _ = await levels.value(for: .brightness)
        levels.endInteraction(for: .brightness)
        XCTAssertEqual(hardware.readCount, 2)
        XCTAssertEqual(hardware.maximumActiveCalls, 1)
        XCTAssertEqual(levels.state(for: .brightness), .level(0.8))
    }

    func testInteractionWaitsForExistingReadWithoutPublishingItsOldValue() async {
        let hardware = LevelHardware()
        hardware.delayRead = true
        let started = expectation(description: "existing read")
        hardware.readStarted = started
        let levels = owner(hardware)
        levels.refresh(.brightness)
        await fulfillment(of: [started], timeout: 1)
        levels.beginInteraction(for: .brightness)
        levels.set(0.8, for: .brightness)
        hardware.finishRead()
        _ = await levels.value(for: .brightness)
        XCTAssertEqual(levels.state(for: .brightness), .level(0.8))
        XCTAssertEqual(hardware.readCount, 1)
        levels.endInteraction(for: .brightness)
        _ = await levels.value(for: .brightness)
        XCTAssertEqual(hardware.readCount, 2)
        XCTAssertEqual(hardware.maximumActiveCalls, 1)
    }

    func testDeviceChangeRejectsRemainingGestureWritesUntilInteractionEnds() async {
        let first = LevelHardware()
        let second = LevelHardware()
        var target: UInt32 = 1
        let levels = LiveLevels(controlFor: { _, id in id == 1 ? first.control() : second.control() },
                                targetFor: { _ in target }, isWedged: { _ in false })
        _ = await levels.value(for: .brightness)
        levels.beginInteraction(for: .brightness)
        levels.set(0.6, for: .brightness)
        _ = await levels.value(for: .brightness)
        target = 2
        levels.set(0.9, for: .brightness)
        _ = await levels.value(for: .brightness)
        XCTAssertTrue(second.writes.isEmpty)
        XCTAssertEqual(second.readCount, 0)
        target = 1
        levels.set(0.95, for: .brightness)
        XCTAssertEqual(first.writes, [0.6])
        target = 2
        levels.endInteraction(for: .brightness)
        _ = await levels.value(for: .brightness)
        XCTAssertEqual(second.readCount, 1)
        levels.beginInteraction(for: .brightness)
        levels.set(0.7, for: .brightness)
        levels.endInteraction(for: .brightness)
        _ = await levels.value(for: .brightness)
        XCTAssertEqual(second.writes, [0.7])
    }

    func testResolverAndSubscribersShareOneInitialRead() async {
        let hardware = LevelHardware()
        hardware.delayRead = true
        let started = expectation(description: "initial read")
        hardware.readStarted = started
        let levels = owner(hardware)
        let resolver = ItemResolver(controlFor: { _ in XCTFail("resolver bypassed shared levels"); return .unavailable }, liveLevels: levels)
        let first = Task { await resolver.resolve([.action("volume")]) }
        await fulfillment(of: [started], timeout: 1)
        let second = Task { await levels.value(for: .volume) }
        hardware.finishRead()
        let cells = await first.value
        let shared = await second.value
        XCTAssertEqual(cells.first?.state, .level(0.25))
        XCTAssertEqual(shared, .level(0.25))
        XCTAssertEqual(hardware.readCount, 1)
    }

    func testExternalPublisherUpdatesSharedStateWithoutWriting() async {
        let hardware = LevelHardware()
        let levels = owner(hardware)
        _ = await levels.value(for: .volume)
        hardware.observed.send(0.73)
        await state(.level(0.73), from: levels)
        XCTAssertTrue(hardware.writes.isEmpty)
        XCTAssertEqual(hardware.readCount, 1)
    }

    func testRawVolumeNotificationsRefreshEvenWhenTargetHasNoLevel() async {
        let hardware = LevelHardware()
        let changed = PassthroughSubject<Void, Never>()
        let levels = LiveLevels(controlFor: { _, _ in hardware.control() }, targetFor: { _ in 1 },
                                isWedged: { _ in false }, volumeChanges: changed.eraseToAnyPublisher())
        _ = await levels.value(for: .volume)
        hardware.value = nil
        changed.send(())
        await state(.unavailable, from: levels)
        XCTAssertEqual(hardware.readCount, 2)
    }

    func testWriteSupersedesDelayedReadAndTracksInputImmediately() async {
        let hardware = LevelHardware()
        hardware.delayRead = true
        let started = expectation(description: "read suspended")
        hardware.readStarted = started
        let levels = owner(hardware)
        levels.refresh(.brightness)
        await fulfillment(of: [started], timeout: 1)
        levels.set(0.9, for: .brightness)
        XCTAssertEqual(levels.state(for: .brightness), .level(0.9))
        XCTAssertTrue(hardware.writes.isEmpty)
        hardware.finishRead()
        let result = await levels.value(for: .brightness)
        XCTAssertEqual(result, .level(0.9))
        XCTAssertEqual(hardware.writes, [0.9])
        XCTAssertEqual(hardware.maximumActiveCalls, 1)
    }

    func testRapidWritesCoalesceAndReadBackAfterLastWrite() async {
        let hardware = LevelHardware()
        let levels = owner(hardware)
        _ = await levels.value(for: .brightness)
        hardware.delayWrite = true
        let started = expectation(description: "write suspended")
        hardware.writeStarted = started
        levels.set(0.3, for: .brightness)
        await fulfillment(of: [started], timeout: 1)
        levels.set(0.4, for: .brightness)
        levels.set(0.8, for: .brightness)
        XCTAssertEqual(levels.state(for: .brightness), .level(0.8))
        hardware.finishWrite()
        let result = await levels.value(for: .brightness)
        XCTAssertEqual(result, .level(0.8))
        XCTAssertEqual(hardware.writes, [0.3, 0.8])
        XCTAssertEqual(hardware.readCount, 2)
        XCTAssertEqual(hardware.maximumActiveCalls, 1)
    }

    func testDeviceChangeDropsQueuedOldDeviceWriteAndOldCompletion() async {
        let old = LevelHardware()
        let new = LevelHardware()
        new.value = 0.6
        var target: UInt32? = 1
        let levels = LiveLevels(controlFor: { _, id in id == 1 ? old.control() : new.control() },
                                targetFor: { _ in target }, isWedged: { _ in false })
        _ = await levels.value(for: .volume)
        old.delayWrite = true
        let started = expectation(description: "old device write suspended")
        old.writeStarted = started
        levels.set(0.3, for: .volume)
        await fulfillment(of: [started], timeout: 1)
        levels.set(0.9, for: .volume)
        target = 2
        levels.refresh(.volume)
        XCTAssertEqual(levels.state(for: .volume), .unknown)
        XCTAssertEqual(new.readCount, 0)
        old.finishWrite()
        let result = await levels.value(for: .volume)
        XCTAssertEqual(result, .level(0.6))
        XCTAssertEqual(old.writes, [0.3])
        XCTAssertTrue(new.writes.isEmpty)
        XCTAssertEqual(new.readCount, 1)
        target = nil
        levels.refresh(.volume)
        let disconnected = await levels.value(for: .volume)
        XCTAssertEqual(disconnected, .unavailable)
    }

    func testWriteFailureDoesNotKeepRequestedLevelAsActual() async {
        let hardware = LevelHardware()
        hardware.failWrite = true
        let levels = owner(hardware)
        levels.set(0.8, for: .brightness)
        let result = await levels.value(for: .brightness)
        XCTAssertEqual(result, .failed("Could not change level"))
        XCTAssertEqual(hardware.value, 0.25)
    }

    func testWedgedBrightnessNeverRunsQueuedWriteOrRetries() async {
        let hardware = LevelHardware()
        hardware.delayRead = true
        var wedged = false
        let started = expectation(description: "protected read suspended")
        hardware.readStarted = started
        let levels = LiveLevels(controlFor: { _, _ in hardware.control() }, targetFor: { _ in 1 },
                                isWedged: { _ in wedged })
        levels.refresh(.brightness)
        await fulfillment(of: [started], timeout: 1)
        levels.set(0.9, for: .brightness)
        wedged = true
        hardware.finishRead()
        let result = await levels.value(for: .brightness)
        XCTAssertEqual(result, .unavailable)
        levels.refresh(.brightness)
        let retried = await levels.value(for: .brightness)
        XCTAssertEqual(retried, .unavailable)
        XCTAssertEqual(hardware.readCount, 1)
        XCTAssertTrue(hardware.writes.isEmpty)
    }

    func testBrightnessPollingRequiresVisibleDrawerOrKeyItemsPage() async {
        let hardware = LevelHardware()
        let ticks = PassthroughSubject<Void, Never>()
        let levels = owner(hardware, ticks: ticks)
        levels.setSettingsVisible(true)
        XCTAssertEqual(hardware.readCount, 0)
        levels.setSettingsWindowKey(true)
        _ = await levels.value(for: .brightness)
        _ = await levels.value(for: .volume)
        XCTAssertEqual(hardware.readCount, 2)
        let tickRead = expectation(description: "visible poll")
        hardware.readStarted = tickRead
        ticks.send(())
        await fulfillment(of: [tickRead], timeout: 1)
        _ = await levels.value(for: .brightness)
        XCTAssertEqual(hardware.readCount, 3)
        levels.setDrawerVisible(true)
        levels.setSettingsWindowKey(false)
        XCTAssertEqual(hardware.readCount, 3)
        levels.setDrawerVisible(false)
        let tickDelivered = expectation(description: "hidden tick delivered")
        let barrier = ticks.receive(on: DispatchQueue.main).sink { tickDelivered.fulfill() }
        ticks.send(())
        await fulfillment(of: [tickDelivered], timeout: 1)
        XCTAssertEqual(hardware.readCount, 3)
        withExtendedLifetime(barrier) {}
        levels.setDrawerVisible(true)
        _ = await levels.value(for: .brightness)
        _ = await levels.value(for: .volume)
        XCTAssertEqual(hardware.readCount, 5)
        levels.setDrawerVisible(false)
    }

    func testDisabledDemoNeverReadsOrWritesLiveLevels() async {
        let levels = LiveLevels(enabled: false,
            controlFor: { _, _ in XCTFail("demo loaded hardware control"); return .unavailable },
            targetFor: { _ in XCTFail("demo resolved hardware target"); return nil })
        levels.setDrawerVisible(true)
        levels.setSettingsWindowKey(true)
        levels.setSettingsVisible(true)
        levels.refresh(.volume)
        levels.set(0.8, for: .brightness)
        let result = await levels.value(for: .volume)
        XCTAssertEqual(result, .unknown)
        XCTAssertTrue(levels.states.isEmpty)
    }
}
