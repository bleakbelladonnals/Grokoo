import AppKit
import QuartzCore
import XCTest
@testable import Grokoo

final class PresenceMotionClockTests: XCTestCase {
    func testRefreshPreservesStateTimeAndHiddenIntervalDoesNotCatchUp() {
        var clock = PresenceMotionClock(state: .working, phaseSlot: 1)
        clock.advance(to: 10, running: true)
        for step in 1...8 { clock.advance(to: 10 + Double(step) * 0.25, running: true) }
        XCTAssertFalse(clock.setState(.working))
        XCTAssertEqual(clock.elapsed, 2)
        XCTAssertEqual(clock.sampleTime, 1.82, accuracy: 0.001)
        clock.advance(to: 12, running: false)
        clock.advance(to: 3600, running: true)
        XCTAssertEqual(clock.elapsed, 2)
        clock.advance(to: 3600.25, running: true)
        XCTAssertEqual(clock.elapsed, 2.25)
        XCTAssertTrue(clock.setState(.done))
        XCTAssertEqual(clock.elapsed, 0)
        XCTAssertEqual(clock.sampleTime, 0)
    }

    func testSixPhasesDelayFirstPeakWithoutSkippingItsOpening() {
        var clocks = (0..<6).map { PresenceMotionClock(state: .done, phaseSlot: $0) }
        for index in clocks.indices {
            clocks[index].advance(to: 100, running: true)
            for step in 1...24 { clocks[index].advance(to: 100 + Double(step) * 0.25, running: true) }
        }
        XCTAssertEqual(Set(clocks.map(\.sampleTime)).count, 6)
        for (a, b) in zip(clocks, clocks.dropFirst()) {
            XCTAssertEqual(a.sampleTime - b.sampleTime, 6.2 / 6, accuracy: 0.0001)
        }
    }

    func testLongRunloopGapDoesNotJumpOrReplayMissedAnimation() {
        var clock = PresenceMotionClock(state: .working)
        clock.advance(to: 10, running: true)
        clock.advance(to: 10.1, running: true)
        clock.advance(to: 1000, running: true)
        XCTAssertEqual(clock.elapsed, 0.1, accuracy: 0.0001)
        clock.advance(to: 1000.1, running: true)
        XCTAssertEqual(clock.elapsed, 0.2, accuracy: 0.0001)
    }

    @MainActor
    func testSceneRefreshPauseResumeAndStateReplacementUseNativePoses() throws {
        let scene = PetSceneController(frame: CGRect(x: 0, y: 0, width: 900, height: 600),
                                      visibleFrame: CGRect(x: 0, y: 70, width: 900, height: 530), allowsEdgeMotion: false)
        defer { scene.shutdown() }
        let identity = BotIdentity(id: "clock", name: "Clock", shape: .cloud, color: .green)
        scene.synchronize(identities: [identity])
        scene.showAll()
        let pet = try XCTUnwrap(scene.petLayer(for: identity.id))
        let now = CACurrentMediaTime()
        scene.advanceMotion(now: now)
        scene.advanceMotion(now: now + 0.25)
        let elapsed = try XCTUnwrap(scene.motionTime(for: identity.id))
        scene.updatePresence(.idle, botId: identity.id, revision: 500)
        XCTAssertEqual(scene.motionTime(for: identity.id), elapsed)
        XCTAssertTrue(pet.usesNativeMotion)
        XCTAssertTrue(pet.faceLayer.isHidden)
        XCTAssertNil(pet.stateDecorationLayer.path)
        XCTAssertTrue(pet.mbtiDecorationLayer.isHidden)
        scene.hideAll()
        scene.advanceMotion(now: now + 500)
        XCTAssertEqual(scene.motionTime(for: identity.id), elapsed)
        scene.showAll()
        XCTAssertEqual(scene.motionTime(for: identity.id)!, elapsed, accuracy: 0.05)
        scene.updatePresence(.blocked, botId: identity.id, revision: 501)
        XCTAssertEqual(scene.motionTime(for: identity.id), 0)
        scene.updatePresence(.working, botId: identity.id, revision: 502)
        XCTAssertEqual(scene.motionTime(for: identity.id), 0)
        XCTAssertNil(pet.stateDecorationLayer.path)
    }
}
