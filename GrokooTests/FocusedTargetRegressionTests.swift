import AppKit
import XCTest
@testable import Grokoo

final class FocusedTargetRegressionTests: XCTestCase {
    @MainActor
    func testMovingIdleTargetsKeepControlsAndRefreshHitGeometryAndStatus() throws {
        let view = InteractiveSceneView(frame: CGRect(x: 0, y: 0, width: 800, height: 300))
        var targets = [
            SceneInteractionTarget(botID: "a", name: "Ada", state: .idle,
                                   frame: CGRect(x: 50, y: 50, width: 32, height: 32)),
            SceneInteractionTarget(botID: "b", name: "Sandy", state: .idle,
                                   frame: CGRect(x: 150, y: 50, width: 32, height: 32))
        ]
        view.updateTargets(targets)
        let firstButton = try XCTUnwrap(view.botButtons["a"])
        let secondButton = try XCTUnwrap(view.botButtons["b"])
        for _ in 0..<10 {
            targets = targets.map {
                SceneInteractionTarget(botID: $0.botID, name: $0.name, state: $0.state,
                                       frame: $0.frame.offsetBy(dx: 20, dy: 1))
            }
            view.updateTargets(targets)
            XCTAssertTrue(view.botButtons["a"] === firstButton)
            XCTAssertTrue(view.botButtons["b"] === secondButton)
            XCTAssertEqual(firstButton.frame, targets[0].frame)
            XCTAssertTrue(firstButton.nextKeyView === secondButton)
            XCTAssertTrue(secondButton.nextKeyView === firstButton)
        }
        XCTAssertFalse(view.containsInteractivePoint(CGPoint(x: 60, y: 60)))
        XCTAssertTrue(view.containsInteractivePoint(CGPoint(x: 260, y: 70)))
        XCTAssertEqual(firstButton.accessibilityLabel(), "Ada，空闲")
        XCTAssertEqual(firstButton.toolTip, "Ada · 空闲")

        targets[0] = SceneInteractionTarget(botID: "a", name: "Nova", state: .working, frame: targets[0].frame)
        view.updateTargets(targets)
        XCTAssertTrue(view.botButtons["a"] === firstButton)
        XCTAssertEqual(firstButton.accessibilityLabel(), "Nova，工作中")
        XCTAssertEqual(firstButton.toolTip, "Nova · 工作中")
        XCTAssertEqual(firstButton.accessibilityHelp(), "当前任务状态")
    }

    @MainActor
    func testMovingAndReorderingDoneTargetsPreservesFocusAndActionLayout() throws {
        let view = InteractiveSceneView(frame: CGRect(x: 0, y: 0, width: 800, height: 300))
        let first = SceneInteractionTarget(botID: "a", name: "Ada", state: .done,
                                           frame: CGRect(x: 50, y: 50, width: 42, height: 42))
        let second = SceneInteractionTarget(botID: "b", name: "Sandy", state: .done,
                                            frame: CGRect(x: 120, y: 50, width: 42, height: 42))
        view.updateTargets([first, second])
        view.focusBot("a")
        let firstButton = try XCTUnwrap(view.botButtons["a"])
        let secondButton = try XCTUnwrap(view.botButtons["b"])
        let moved = SceneInteractionTarget(botID: "a", name: "Nova", state: .done,
                                           frame: CGRect(x: 300, y: 100, width: 42, height: 42))
        view.updateTargets([second, moved])
        XCTAssertEqual(view.highlightedBotID, "a")
        XCTAssertTrue(view.botButtons["a"] === firstButton)
        XCTAssertTrue(secondButton.nextKeyView === firstButton)
        XCTAssertTrue(firstButton.nextKeyView === view.dismissButton)
        XCTAssertTrue(view.dismissButton.nextKeyView === view.dismissAllButton)
        XCTAssertTrue(view.dismissAllButton.nextKeyView === secondButton)
        XCTAssertEqual(view.dismissButton.frame.minY, moved.frame.maxY + 2)
        XCTAssertEqual(view.dismissButton.accessibilityLabel(), "收起 Nova 的已完成任务")

        view.updateTargets([moved])
        XCTAssertEqual(view.highlightedBotID, "a")
        XCTAssertNil(view.botButtons["b"])
        XCTAssertTrue(view.dismissAllButton.isHidden)
        XCTAssertTrue(view.dismissButton.nextKeyView === firstButton)
        view.updateTargets([])
        XCTAssertNil(view.highlightedBotID)
        XCTAssertTrue(view.botButtons.isEmpty)
        XCTAssertTrue(view.dismissButton.isHidden)
    }

    @MainActor
    func testRemovingTransparentDoneTargetReleasesItsQuietPose() {
        let view = InteractiveSceneView(frame: CGRect(x: 0, y: 0, width: 600, height: 300))
        let identity = BotIdentity(id: "focused-done", name: "Nova", shape: .blob, color: .blue)
        let pet = PetLayer(identity: identity)
        let quietPose = NativeMotionSampler().sample(shape: .blob, state: .done, time: 5.9,
                                                     instanceID: identity.id + ".focus")
        var highlightChanges = 0
        view.onHighlightedBot = { id in
            highlightChanges += 1
            pet.focusDone(on: id == identity.id ? quietPose : nil, duration: 0)
        }
        let target = SceneInteractionTarget(botID: identity.id, name: identity.name, state: .done,
                                             frame: CGRect(x: 50, y: 50, width: 42, height: 42))
        view.updateTargets([target])
        view.updatePointer(at: CGPoint(x: 70, y: 70))
        XCTAssertTrue(pet.isDoneFocused)

        // Sorting/layout transitions temporarily remove fully transparent targets.
        view.updateTargets([])
        XCTAssertNil(view.highlightedBotID)
        XCTAssertFalse(pet.isDoneFocused, "A target removed during a fade must release its quiet Done pose")
        XCTAssertEqual(highlightChanges, 2)

        view.updateTargets([target])
        view.updatePointer(at: CGPoint(x: 500, y: 250))
        XCTAssertFalse(pet.isDoneFocused, "Restoring the visible target must not restore a stale focus pose")
        view.updatePointer(at: CGPoint(x: 70, y: 70))
        XCTAssertTrue(pet.isDoneFocused)
        XCTAssertEqual(highlightChanges, 3)
    }

    @MainActor
    func testDoneReplacedByWorkingNotifiesFocusReleaseExactlyOnce() {
        let view = InteractiveSceneView(frame: CGRect(x: 0, y: 0, width: 600, height: 300))
        var changes: [BotID?] = []
        view.onHighlightedBot = { changes.append($0) }
        let frame = CGRect(x: 50, y: 50, width: 42, height: 42)
        view.updateTargets([SceneInteractionTarget(botID: "nova", name: "Nova", state: .done, frame: frame)])
        view.updatePointer(at: CGPoint(x: 70, y: 70))
        let working = SceneInteractionTarget(botID: "nova", name: "Nova", state: .working, frame: frame)
        view.updateTargets([working])
        view.updateTargets([working])
        XCTAssertNil(view.highlightedBotID)
        XCTAssertEqual(changes.count, 2)
        XCTAssertEqual(changes.first!, "nova")
        XCTAssertNil(changes.last!)
    }
}
