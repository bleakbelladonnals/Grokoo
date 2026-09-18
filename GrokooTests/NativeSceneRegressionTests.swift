import AppKit
import QuartzCore
import XCTest
@testable import Grokoo

final class NativeSceneRegressionTests: XCTestCase {
    @MainActor
    func testReplacingOneOfSixBotsReusesVacantPhaseWithoutMovingSurvivors() throws {
        let scene = makeScene()
        defer { scene.shutdown() }
        let original = (0..<6).map { BotIdentity(id: "phase-\($0)", name: "Bot \($0)", shape: .blob, color: .blue) }
        scene.synchronize(identities: original)
        let before = Dictionary(uniqueKeysWithValues: try original.map {
            ($0.id, try XCTUnwrap(scene.motionPhaseSlot(for: $0.id)))
        })
        XCTAssertEqual(Set(before.values), Set(0..<6))

        let survivors = original.enumerated().filter { $0.offset != 3 }.map(\.element)
        scene.synchronize(identities: survivors)
        let replacement = BotIdentity(id: "replacement", name: "Replacement", shape: .blob, color: .blue)
        let current = survivors + [replacement]
        scene.synchronize(identities: current)
        let after = Dictionary(uniqueKeysWithValues: try current.map {
            ($0.id, try XCTUnwrap(scene.motionPhaseSlot(for: $0.id)))
        })
        XCTAssertEqual(Set(after.values), Set(0..<6), "Roster churn must not make two Done phrases share a phase")
        XCTAssertEqual(after[replacement.id], before[original[3].id])
        for identity in survivors { XCTAssertEqual(after[identity.id], before[identity.id]) }

        scene.synchronize(identities: Array(current.reversed()))
        for identity in current { XCTAssertEqual(scene.motionPhaseSlot(for: identity.id), after[identity.id]) }
    }

    @MainActor
    func testDoneFocusSettlesThenResumesAndNewWorkRemovesFocusedPose() async throws {
        let scene = makeScene()
        defer { scene.shutdown() }
        let identity = BotIdentity(id: "focus-native", name: "Focus", shape: .teardrop, color: .cyan)
        scene.synchronize(identities: [identity])
        scene.updatePresence(.done, botId: identity.id, revision: 1)
        scene.showAll()
        try await Task.sleep(for: .seconds(0.8))
        let pet = try XCTUnwrap(scene.petLayer(for: identity.id))
        let view = try XCTUnwrap(scene.panel.contentView as? InteractiveSceneView)
        scene.refreshInteraction()
        view.focusBot(identity.id)
        let heldTime = try XCTUnwrap(scene.motionTime(for: identity.id))
        XCTAssertTrue(pet.isDoneFocused)
        XCTAssertEqual(pet.nativeMotionLayer.animation(forKey: "done.focus")?.duration, 0.18)
        try await Task.sleep(for: .seconds(0.24))
        XCTAssertEqual(pet.nativeMotionLayer.presentation()?.opacity ?? pet.nativeMotionLayer.opacity, 0, accuracy: 0.01)
        let stableLayer = try XCTUnwrap(pet.sublayers?.compactMap { $0 as? NativeMotionLayer }.first {
            $0 !== pet.nativeMotionLayer && $0.opacity > 0.99
        })
        let stableFrame = try XCTUnwrap(stableLayer.motionFrame)
        XCTAssertFalse(stableFrame.doneActionActive)
        XCTAssertEqual(stableFrame.surfaceTurn, 0, accuracy: 0.001)
        XCTAssertTrue(stableFrame.frontRibbons.isEmpty && stableFrame.backRibbons.isEmpty)
        XCTAssertEqual(scene.motionTime(for: identity.id), heldTime, "Focus must freeze the state clock while showing the stable pose")
        XCTAssertFalse(view.dismissButton.isHidden)

        view.updatePointer(at: CGPoint(x: 880, y: 580))
        XCTAssertFalse(pet.isDoneFocused)
        let now = CACurrentMediaTime()
        scene.advanceMotion(now: now)
        scene.advanceMotion(now: now + 0.25)
        XCTAssertGreaterThan(try XCTUnwrap(scene.motionTime(for: identity.id)), heldTime)

        view.focusBot(identity.id)
        XCTAssertTrue(pet.isDoneFocused)
        scene.updatePresence(.working, botId: identity.id, revision: 2)
        XCTAssertFalse(pet.isDoneFocused)
        XCTAssertEqual(pet.nativeMotionLayer.opacity, 1)
        XCTAssertEqual(scene.motionTime(for: identity.id), 0)
        XCTAssertTrue(view.dismissButton.isHidden)
    }

    @MainActor
    private func makeScene() -> PetSceneController {
        PetSceneController(frame: CGRect(x: 0, y: 0, width: 900, height: 600),
                           visibleFrame: CGRect(x: 0, y: 70, width: 900, height: 530),
                           allowsEdgeMotion: false)
    }
}
