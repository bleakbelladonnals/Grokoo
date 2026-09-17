import AppKit
import QuartzCore
import XCTest
@testable import Grokoo

final class SceneInteractionMotionTests: XCTestCase {
    func testStableBatchReservationsHaveAtMostTwoStartsEveryPointEighteenSeconds() {
        var schedule = WorkspaceTransitionSchedule()
        let starts = (0..<6).map { schedule.reserve(botID: "b\($0)", now: 100) }
        for (actual, expected) in zip(starts, [100, 100, 100.18, 100.18, 100.36, 100.36]) {
            XCTAssertEqual(actual, expected, accuracy: 0.0001)
        }
        XCTAssertEqual(schedule.reserve(botID: "b4", now: 100.1), 100.36, accuracy: 0.0001)
        XCTAssertEqual(WorkspaceTransitionSchedule.enteringDuration, 0.68)
        XCTAssertEqual(WorkspaceTransitionSchedule.leavingDuration, 0.58)
    }

    @MainActor
    func testDoneHoverNativeButtonsAndAccessibilityUseSameActions() {
        let view = InteractiveSceneView(frame: CGRect(x: 0, y: 0, width: 800, height: 300))
        let targets = [
            SceneInteractionTarget(botID: "a", name: "Ada", state: .done, frame: CGRect(x: 200, y: 70, width: 42, height: 42)),
            SceneInteractionTarget(botID: "b", name: "Sandy", state: .done, frame: CGRect(x: 260, y: 70, width: 42, height: 42))
        ]
        var acknowledged: [BotID] = []
        var acknowledgedAll = false
        view.onAcknowledge = { acknowledged.append($0) }
        view.onAcknowledgeAll = { acknowledgedAll = true }
        view.updateTargets(targets)
        XCTAssertTrue(view.dismissButton.isHidden)
        XCTAssertFalse(view.dismissAllButton.isHidden)
        XCTAssertFalse(view.containsInteractivePoint(CGPoint(x: 30, y: 30)))
        view.updatePointer(at: CGPoint(x: 220, y: 90))
        XCTAssertEqual(view.highlightedBotID, "a")
        XCTAssertFalse(view.dismissButton.isHidden)
        XCTAssertGreaterThanOrEqual(view.dismissButton.frame.height, 28)
        XCTAssertEqual(view.dismissButton.accessibilityLabel(), "收起 Ada 的已完成任务")
        view.dismissButton.performClick(nil)
        view.dismissAllButton.performClick(nil)
        XCTAssertEqual(acknowledged, ["a"])
        XCTAssertTrue(acknowledgedAll)
        view.focusBot("b")
        view.updatePointer(at: CGPoint(x: 220, y: 90))
        XCTAssertEqual(view.highlightedBotID, "b", "A stationary pointer must not overwrite keyboard focus")
        view.focusBot("a")
        view.updateTargets([targets[1]])
        XCTAssertTrue(view.dismissAllButton.isHidden)
        XCTAssertTrue(view.dismissButton.isHidden)
        XCTAssertNil(view.hitTest(CGPoint(x: 220, y: 90)))
    }

    @MainActor
    func testFocusRevealsDoneActionWithoutHoverAndDeleteAcknowledges() throws {
        let panel = DesktopScenePanel(contentRect: CGRect(x: 0, y: 0, width: 600, height: 250), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let view = InteractiveSceneView(frame: panel.contentRect(forFrameRect: panel.frame))
        panel.contentView = view
        view.updateTargets([SceneInteractionTarget(botID: "a", name: "Ada", state: .done, frame: CGRect(x: 200, y: 70, width: 42, height: 42))])
        var acknowledged: BotID?
        view.onAcknowledge = { acknowledged = $0 }
        view.focusPendingCompletions()
        XCTAssertFalse(view.dismissButton.isHidden)
        XCTAssertTrue(panel.firstResponder === view.botButtons["a"])
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 51))
        view.keyDown(with: event)
        XCTAssertEqual(acknowledged, "a")
    }

    @MainActor
    func testReducedMotionRetainsStaticDoneAndWorkspaceBodySize() async throws {
        let fixture = ExperienceFixture(id: "motion-check", visibleBotCount: 2, states: [.done, .idle], groups: [], dockEdge: .bottom, wallpaper: .light, reducedTransparency: false, reducedMotion: true)
        let scene = PetSceneController(frame: CGRect(x: 0, y: 0, width: 900, height: 600), visibleFrame: CGRect(x: 0, y: 70, width: 900, height: 530), experienceFixture: fixture)
        defer { scene.shutdown() }
        let identities = Array(AcceptanceFixtureGatewayRuntime.identities.prefix(2))
        scene.synchronize(identities: identities)
        scene.updatePresence(.done, botId: identities[0].id, revision: 1)
        scene.updatePresence(.idle, botId: identities[1].id, revision: 1)
        scene.showAll()
        try await Task.sleep(for: .seconds(0.85))
        XCTAssertTrue(scene.reducesMotion)
        let done = try XCTUnwrap(scene.petLayer(for: identities[0].id))
        XCTAssertNotNil(done.stateDecorationLayer.path)
        XCTAssertEqual(done.bodyShapeLayer.frame.width * done.affineTransform().a, 42, accuracy: 0.01)
        let body = done.convert(done.bodyShapeLayer.frame, to: scene.sceneLayer)
        XCTAssertEqual(body.minY, scene.currentPlacement.petFrames[identities[0].id]!.minY, accuracy: 0.01)
        for pet in scene.petLayers.values {
            XCTAssertTrue(pet.animationKeys()?.isEmpty ?? true)
            XCTAssertTrue(pet.bodyShapeLayer.animationKeys()?.isEmpty ?? true)
        }
        scene.refreshInteraction()
        let view = try XCTUnwrap(scene.panel.contentView as? InteractiveSceneView)
        XCTAssertEqual(view.targets.count, 2)
        XCTAssertNil(view.hitTest(CGPoint(x: 800, y: 500)))
    }

    @MainActor
    func testSystemReduceMotionFreezesPresentationAndStopsExistingRoute() async throws {
        let scene = PetSceneController(frame: CGRect(x: 0, y: 0, width: 900, height: 600), visibleFrame: CGRect(x: 0, y: 70, width: 900, height: 530))
        defer { scene.shutdown() }
        let identity = AcceptanceFixtureGatewayRuntime.identities[0]
        scene.synchronize(identities: [identity])
        scene.updatePresence(.idle, botId: identity.id, revision: 1)
        scene.applyAccessibilityPreferences(systemReducedMotion: false, systemReducedTransparency: false)
        scene.showAll()
        let pet = try XCTUnwrap(scene.petLayer(for: identity.id))
        let motion = CABasicAnimation(keyPath: "position")
        motion.fromValue = NSValue(point: pet.position)
        motion.toValue = NSValue(point: CGPoint(x: 700, y: 70))
        motion.duration = 8
        pet.add(motion, forKey: "system-preference-live-route")
        try await Task.sleep(for: .seconds(0.08))
        let before = pet.presentation()?.position ?? pet.position
        let priorTransform = pet.presentation()?.transform ?? pet.transform
        scene.applyAccessibilityPreferences(systemReducedMotion: true, systemReducedTransparency: false)
        XCTAssertTrue(scene.reducesMotion)
        XCTAssertEqual(pet.position.x, before.x, accuracy: 3)
        XCTAssertEqual(pet.position.y, before.y, accuracy: 3)
        XCTAssertEqual(pet.transform.m11, priorTransform.m11, accuracy: 0.01)
        XCTAssertTrue(pet.animationKeys()?.isEmpty ?? true)
        let pausedPosition = pet.position
        try await Task.sleep(for: .seconds(0.7))
        XCTAssertEqual(pet.position, pausedPosition)
        XCTAssertTrue(pet.animationKeys()?.isEmpty ?? true)
    }

    @MainActor
    func testFixtureCannotTurnOffSystemAccessibilityPreferences() {
        let fixture = ExperienceFixture(id: "normal-motion", visibleBotCount: 1, states: [.idle], groups: [], dockEdge: .bottom, wallpaper: .light, reducedTransparency: false, reducedMotion: false)
        let scene = PetSceneController(frame: CGRect(x: 0, y: 0, width: 900, height: 600), visibleFrame: CGRect(x: 0, y: 70, width: 900, height: 530), experienceFixture: fixture)
        defer { scene.shutdown() }
        scene.applyAccessibilityPreferences(systemReducedMotion: true, systemReducedTransparency: true)
        XCTAssertTrue(scene.reducesMotion)
        XCTAssertTrue(scene.fogLayer.isReducedTransparency)
    }

    @MainActor
    func testNewTaskReplacesSettledDoneInPlaceWithoutAnotherFade() async throws {
        let scene = PetSceneController(frame: CGRect(x: 0, y: 0, width: 900, height: 600), visibleFrame: CGRect(x: 0, y: 70, width: 900, height: 530), allowsEdgeMotion: false)
        defer { scene.shutdown() }
        let identity = AcceptanceFixtureGatewayRuntime.identities[0]
        scene.synchronize(identities: [identity])
        scene.updatePresence(.done, botId: identity.id, revision: 1)
        scene.showAll()
        try await Task.sleep(for: .seconds(0.8))
        let pet = try XCTUnwrap(scene.petLayer(for: identity.id))
        let station = pet.position
        scene.updatePresence(.working, botId: identity.id, revision: 2)
        XCTAssertNil(pet.animation(forKey: "workspace.opacity"))
        XCTAssertEqual(pet.position, station)
        XCTAssertEqual(pet.opacity, 1)
    }

    @MainActor
    func testNewTaskInterruptsLeavingDoneFromCurrentPresentation() async throws {
        let scene = PetSceneController(frame: CGRect(x: 0, y: 0, width: 900, height: 600), visibleFrame: CGRect(x: 0, y: 70, width: 900, height: 530), allowsEdgeMotion: false)
        defer { scene.shutdown() }
        let identity = AcceptanceFixtureGatewayRuntime.identities[0]
        scene.synchronize(identities: [identity])
        scene.updatePresence(.done, botId: identity.id, revision: 1)
        scene.showAll()
        try await Task.sleep(for: .seconds(0.8))
        let pet = try XCTUnwrap(scene.petLayer(for: identity.id))
        let station = pet.position
        scene.updatePresence(.idle, botId: identity.id, revision: 2)
        try await Task.sleep(for: .seconds(0.10))
        let before = pet.presentation()?.opacity ?? pet.opacity
        scene.updatePresence(.working, botId: identity.id, revision: 3)
        let animation = try XCTUnwrap(pet.animation(forKey: "workspace.opacity") as? CABasicAnimation)
        XCTAssertEqual((animation.fromValue as? Float) ?? -1, before, accuracy: 0.12)
        XCTAssertEqual(pet.position, station)
        try await Task.sleep(for: .seconds(0.8))
        XCTAssertEqual(pet.position, station)
        XCTAssertEqual(pet.opacity, 1)
    }
}
