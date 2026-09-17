import AppKit
import XCTest
@testable import Grokoo

final class RenderingMotionTests: XCTestCase {
    func testOfficialShapeNullDefaultsToBlobAndAllEightShapesHave64Points() {
        XCTAssertEqual(OfficialShape(gatewayValue: nil), .blob)
        XCTAssertEqual(OfficialShape.allCases.count, 8)
        let engine = BloubShapeEngine()
        for shape in OfficialShape.allCases {
            let silhouette = engine.silhouette(for: shape)
            XCTAssertEqual(silhouette.radii.count, 64, shape.rawValue)
            XCTAssertTrue(silhouette.radii.allSatisfy { $0 > 0 && $0 < 1.5 }, shape.rawValue)
            XCTAssertFalse(engine.path(for: shape, in: CGRect(x: 0, y: 0, width: 32, height: 32)).isEmpty)
        }
    }

    func testOfficialPaletteMatchesGrokBotValuesExactly() {
        let expected = [
            "black": "#000000", "brown": "#936439", "red": "#FF263C",
            "orange": "#FF6700", "yellow": "#FF9800", "green": "#00C972",
            "cyan": "#00BCA6", "blue": "#1084FE", "violet": "#9159FE",
            "magenta": "#FF309B", "gray": "#777777"
        ]
        XCTAssertEqual(OfficialColor.allCases.count, 11)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: OfficialColor.allCases.map { ($0.rawValue, $0.hex) }), expected)
        XCTAssertEqual(OfficialColor(gatewayValue: "#1084fe"), .blue)
    }

    @MainActor
    func testEyeFitsRemainInsideBodyForEveryShape() {
        let body = CGRect(x: 0, y: 0, width: 32, height: 32)
        for shape in OfficialShape.allCases {
            let fit = FaceLayer.eyeFit(for: shape, bodyBounds: body)
            let centers = [body.midX - fit.spacing / 2 + fit.centerOffset.x, body.midX + fit.spacing / 2 + fit.centerOffset.x]
            for x in centers {
                let eye = CGRect(x: x - fit.eyeSize.width / 2, y: body.midY + fit.centerOffset.y - fit.eyeSize.height / 2, width: fit.eyeSize.width, height: fit.eyeSize.height)
                XCTAssertTrue(body.contains(eye), "\(shape.rawValue) eye overflow: \(eye)")
            }
        }
    }

    @MainActor
    func testAllEightByFourDecorationAnchorsAreDefinedAndBounded() {
        for shape in OfficialShape.allCases {
            for decoration in DecorationID.allCases {
                let anchor = DecorationLayer.anchor(for: decoration, shape: shape)
                XCTAssertTrue((0...1).contains(anchor.point.x), "\(shape)-\(decoration) x")
                XCTAssertTrue((0...1).contains(anchor.point.y), "\(shape)-\(decoration) y")
            }
        }
    }

    @MainActor
    func testAllDecorationsStayInsideTheThirtySixPointPetBounds() {
        for shape in OfficialShape.allCases {
            for decoration in DecorationID.allCases {
                let pet = PetLayer(identity: BotIdentity(
                    id: "\(shape.rawValue)-\(decoration.rawValue)",
                    name: "visual",
                    shape: shape,
                    color: .blue
                ))
                pet.setMBTIDecoration(decoration.rawValue)
                let converted = pet.mbtiDecorationLayer.convert(
                    pet.mbtiDecorationLayer.bounds,
                    to: pet
                ).insetBy(dx: -0.65, dy: -0.65)
                XCTAssertTrue(
                    pet.bounds.insetBy(dx: -0.25, dy: -0.25).contains(converted),
                    "\(shape.rawValue)-\(decoration.rawValue) overflow: \(converted)"
                )
            }
        }
    }

    func testEdgeGeometryUsesVisibleFrameAndSafeAreaFixture() {
        let geometry = EdgeGeometry(
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 80, y: 50, width: 1432, height: 900),
            safeAreaInsets: EdgeInsets(top: 38, left: 0, bottom: 0, right: 0),
            petExtent: 36
        )
        XCTAssertEqual(geometry.leftX, 98)
        XCTAssertEqual(geometry.rightX, 1494)
        XCTAssertEqual(geometry.floorY, 50)
        XCTAssertEqual(geometry.ceilingY, 908)
        XCTAssertEqual(geometry.point(surface: .floor, normalizedPosition: 0).x, geometry.leftX)
        XCTAssertEqual(geometry.point(surface: .ceiling, normalizedPosition: 1).x, geometry.rightX)
    }

    func testEdgeStateMachineCoversBottomAndTopCorners() {
        var machine = EdgeStateMachine()
        XCTAssertEqual(machine.transition(toward: .leftWall)?.action, .turnBottomCorner)
        machine.advance(to: 1)
        XCTAssertEqual(machine.transition(toward: .ceiling)?.action, .turnTopCorner)
        XCTAssertEqual(machine.transition(toward: .rightWall)?.action, .turnTopCorner)
        machine.advance(to: 0)
        XCTAssertEqual(machine.transition(toward: .floor)?.action, .turnBottomCorner)
    }

    func testEdgeOccupancyEnforcesMinimumDistanceAndAllowsReuseAfterRelease() {
        var occupancy = EdgeOccupancy()
        XCTAssertTrue(occupancy.reserve(botId: "one", center: 0.5, minimumDistance: 52, edgeLength: 1000))
        XCTAssertFalse(occupancy.reserve(botId: "two", center: 0.53, minimumDistance: 52, edgeLength: 1000))
        XCTAssertTrue(occupancy.reserve(botId: "two", center: 0.62, minimumDistance: 52, edgeLength: 1000))
        occupancy.release(botId: "one")
        XCTAssertTrue(occupancy.reserve(botId: "three", center: 0.5, minimumDistance: 52, edgeLength: 1000))
    }

    func testPhysicalEdgeOccupancyRejectsTheSameCornerAcrossAdjacentSurfaces() {
        let geometry = EdgeGeometry(
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 50, width: 1512, height: 900),
            petExtent: 36
        )
        var occupancy = EdgePointOccupancy()
        let floorRight = geometry.point(surface: .floor, normalizedPosition: 1)
        let wallBottom = geometry.point(surface: .rightWall, normalizedPosition: 0)
        XCTAssertTrue(occupancy.reserve(botId: "floor", point: floorRight, minimumDistance: 40))
        XCTAssertFalse(occupancy.reserve(botId: "wall", point: wallBottom, minimumDistance: 40))
        occupancy.release(botId: "floor")
        XCTAssertTrue(occupancy.reserve(botId: "wall", point: wallBottom, minimumDistance: 40))
    }

    func testPhysicalEdgeOccupancyRejectsCrossingAndNearTravelSegments() {
        var occupancy = EdgePointOccupancy()
        XCTAssertTrue(occupancy.reserve(
            botId: "horizontal",
            from: CGPoint(x: 0, y: 0),
            to: CGPoint(x: 100, y: 0),
            minimumDistance: 40
        ))
        XCTAssertFalse(occupancy.reserve(
            botId: "crossing",
            from: CGPoint(x: 50, y: -100),
            to: CGPoint(x: 50, y: 100),
            minimumDistance: 40
        ))
        XCTAssertFalse(occupancy.reserve(
            botId: "parallel-near",
            from: CGPoint(x: 0, y: 30),
            to: CGPoint(x: 100, y: 30),
            minimumDistance: 40
        ))
        XCTAssertTrue(occupancy.reserve(
            botId: "parallel-clear",
            from: CGPoint(x: 0, y: 40),
            to: CGPoint(x: 100, y: 40),
            minimumDistance: 40
        ))
    }

    func testPhysicalEdgeOccupancyLetsAnOutsidePetEscapeACrowdedStationRow() {
        var towardRight = EdgePointOccupancy()
        towardRight.register(botId: "left-neighbour", point: CGPoint(x: 100, y: 50))
        towardRight.register(botId: "outside", point: CGPoint(x: 142, y: 50))
        XCTAssertTrue(towardRight.reserve(
            botId: "outside",
            from: CGPoint(x: 142, y: 50),
            to: CGPoint(x: 400, y: 50),
            minimumDistance: 60
        ))

        var towardLeft = EdgePointOccupancy()
        towardLeft.register(botId: "outside", point: CGPoint(x: 100, y: 50))
        towardLeft.register(botId: "right-neighbour", point: CGPoint(x: 142, y: 50))
        XCTAssertTrue(towardLeft.reserve(
            botId: "outside",
            from: CGPoint(x: 100, y: 50),
            to: CGPoint(x: 0, y: 50),
            minimumDistance: 60
        ))

        var approaching = EdgePointOccupancy()
        approaching.register(botId: "left", point: CGPoint(x: 100, y: 50))
        approaching.register(botId: "right", point: CGPoint(x: 142, y: 50))
        XCTAssertFalse(approaching.reserve(
            botId: "left",
            from: CGPoint(x: 100, y: 50),
            to: CGPoint(x: 400, y: 50),
            minimumDistance: 60
        ))
        XCTAssertFalse(approaching.reserve(
            botId: "right",
            from: CGPoint(x: 142, y: 50),
            to: CGPoint(x: 150, y: 50),
            minimumDistance: 60
        ))
    }

    @MainActor
    func testIdleRouteRecoversAfterBoundedReservationFailures() {
        XCTAssertFalse(IdleMotionController.shouldRecoverRoute(after: 3))
        XCTAssertTrue(IdleMotionController.shouldRecoverRoute(after: 4))
        XCTAssertTrue(IdleMotionController.shouldRecoverRoute(after: 20))
    }

    @MainActor
    func testClimbAnimationsRotateTowardTheScreenInterior() {
        let coordinator = AnimationCoordinator()
        let left = PetLayer(identity: BotIdentity(id: "left", name: "Left", shape: .blob, color: .blue))
        let right = PetLayer(identity: BotIdentity(id: "right", name: "Right", shape: .blob, color: .green))
        coordinator.play(.climbLeft, on: left, destination: .zero, duration: 1)
        coordinator.play(.climbRight, on: right, destination: .zero, duration: 1)
        XCTAssertLessThan(left.affineTransform().b, -0.99)
        XCTAssertGreaterThan(right.affineTransform().b, 0.99)
        coordinator.cancelAll(pets: [left, right])
    }

    func testWorkstationSlotsTwoThroughSixNeverOverlap() {
        let layout = WorkstationLayout()
        let visible = CGRect(x: 0, y: 50, width: 900, height: 700)
        for count in 2...6 {
            for region in WorkstationRegion.allCases {
                let slots = layout.slots(visibleFrame: visible, region: region, orderedBotIds: (0..<count).map { "bot-\($0)" })
                XCTAssertEqual(slots.count, count)
                XCTAssertTrue(slots.allSatisfy { $0.baseFrame.size == CGSize(width: 36, height: 8) })
                for left in slots.indices {
                    for right in slots.indices where left < right {
                        XCTAssertFalse(slots[left].petFrame.intersects(slots[right].petFrame))
                    }
                }
            }
        }
    }

    func testLeftAndRightWorkstationsKeepCornerTransitionsClear() {
        let visible = CGRect(x: 0, y: 50, width: 1512, height: 900)
        let layout = WorkstationLayout()
        let left = layout.slots(visibleFrame: visible, region: .left, orderedBotIds: ["one", "two"])
        let right = layout.slots(visibleFrame: visible, region: .right, orderedBotIds: ["three", "four"])
        XCTAssertGreaterThanOrEqual(left.map(\.petFrame.minX).min() ?? 0, visible.minX + 64)
        XCTAssertLessThanOrEqual(right.map(\.petFrame.maxX).max() ?? visible.maxX, visible.maxX - 64)
    }

    func testGroupStationSupportsOneThroughSixAndAvoidsPermanentBase() {
        let layout = GroupStationLayout()
        let visible = CGRect(x: 0, y: 30, width: 900, height: 700)
        let occupied = CGRect(x: 350, y: 31, width: 200, height: 8)
        for count in 1...6 {
            let placement = layout.placement(visibleFrame: visible, orderedMemberIds: (0..<count).map { "bot-\($0)" }, avoiding: [occupied])
            XCTAssertEqual(placement?.memberFrames.count, count)
            XCTAssertEqual(placement?.baseFrame.width, CGFloat(count) * 42)
            XCTAssertFalse(placement?.baseFrame.intersects(occupied) ?? true)
        }
    }

    func testAnimationManifestMapsAllSeventeenActions() throws {
        let manifest = try AnimationManifestLoader.loadBundled()
        XCTAssertEqual(PetAction.allCases.count, 17)
        XCTAssertTrue(manifest.hasCompleteMVPMapping)
        for action in PetAction.allCases {
            XCTAssertNotNil(manifest[action], action.rawValue)
        }
    }

    func testMBTILoaderProvidesNeutralAndSixteenClampedPresets() throws {
        let catalog = try MBTIPresetLoader.loadBundled()
        XCTAssertEqual(catalog.presets.count, 16)
        XCTAssertEqual(catalog.neutral, BehaviorPreset(moveWeight: 1, exploreWeight: 1, socialWeight: 1, restWeight: 1, speedMultiplier: 1, dwellMultiplier: 1, socialDistance: 52, decorationId: nil))
        for preset in catalog.presets.values {
            XCTAssertTrue((0.7...1.4).contains(preset.moveWeight))
            XCTAssertTrue((0.7...1.4).contains(preset.exploreWeight))
            XCTAssertTrue((0.7...1.4).contains(preset.socialWeight))
            XCTAssertTrue((0.7...1.4).contains(preset.restWeight))
            XCTAssertTrue((0.85...1.15).contains(preset.speedMultiplier))
            XCTAssertTrue((0.8...1.25).contains(preset.dwellMultiplier))
            XCTAssertTrue((40...68).contains(preset.socialDistance))
        }
        XCTAssertEqual(catalog.preset(for: .entp).decorationId, "bent-brow")
        XCTAssertEqual(catalog.preset(for: .infp).decorationId, "butterfly")
        XCTAssertEqual(catalog.preset(for: .isfj).decorationId, "nurse-cap")
        XCTAssertEqual(catalog.preset(for: .istp).decorationId, "tiny-drill")
        XCTAssertNil(catalog.preset(for: .intj).decorationId)
    }

    func testSeededBehaviorSamplingIsRepeatableAndPresenceOverridesPersonality() throws {
        let catalog = try MBTIPresetLoader.loadBundled()
        var first = BehaviorSampler(seed: 42)
        var second = BehaviorSampler(seed: 42)
        let firstSequence = (0..<100).map { _ in first.sample(presence: .idle, surface: .floor, preset: catalog.preset(for: .infp)).action }
        let secondSequence = (0..<100).map { _ in second.sample(presence: .idle, surface: .floor, preset: catalog.preset(for: .infp)).action }
        XCTAssertEqual(firstSequence, secondSequence)
        XCTAssertEqual(first.sample(presence: .working, surface: .station, preset: catalog.preset(for: .entp)).action, .workAtStation)
        XCTAssertEqual(first.sample(presence: .waiting, surface: .floor, preset: catalog.preset(for: .entp)).action, .waitAtStation)
        XCTAssertEqual(first.sample(presence: .offline, surface: .floor, preset: catalog.preset(for: .entp)).action, .offlineSleep)
    }

    func testAllSixteenTypesAndNeutralMatchTenThousandSampleSeededDistributions() throws {
        let catalog = try MBTIPresetLoader.loadBundled()
        let types: [MBTIType?] = [nil] + MBTIType.allCases.map(Optional.some)
        let candidates = [
            BehaviorCandidate(action: .idleBreathe, baseWeight: 1),
            BehaviorCandidate(action: .blink, baseWeight: 1),
            BehaviorCandidate(action: .floorMove, baseWeight: 1),
            BehaviorCandidate(action: .turnBottomCorner, baseWeight: 1)
        ]
        for (index, type) in types.enumerated() {
            let preset = catalog.preset(for: type)
            let weights: [PetAction: Double] = [
                .idleBreathe: preset.restWeight,
                .blink: preset.restWeight,
                .floorMove: preset.moveWeight * 0.8 + preset.socialWeight * 0.2,
                .turnBottomCorner: preset.exploreWeight
            ]
            let total = weights.values.reduce(0, +)
            var sampler = BehaviorSampler(seed: UInt64(10_000 + index))
            var counts: [PetAction: Int] = [:]
            for _ in 0..<10_000 {
                let action = sampler.sample(
                    presence: .idle,
                    surface: .floor,
                    preset: preset,
                    candidates: candidates
                ).action
                counts[action, default: 0] += 1
            }
            for candidate in candidates {
                let observed = Double(counts[candidate.action, default: 0]) / 10_000
                let expected = (weights[candidate.action] ?? 0) / total
                XCTAssertEqual(observed, expected, accuracy: 0.025, "\(type?.rawValue ?? "neutral") \(candidate.action.rawValue)")
            }
        }
    }

    @MainActor
    func testMBTISocialDistanceDrivesIdleRouteReservationSpacing() throws {
        let catalog = try MBTIPresetLoader.loadBundled()
        var distantSampler = BehaviorSampler(seed: 7)
        var closeSampler = BehaviorSampler(seed: 7)
        let candidates = [BehaviorCandidate(action: .floorMove, baseWeight: 1)]
        let distant = distantSampler.sample(
            presence: .idle,
            surface: .floor,
            preset: catalog.preset(for: .istj),
            candidates: candidates
        )
        let close = closeSampler.sample(
            presence: .idle,
            surface: .floor,
            preset: catalog.preset(for: .estp),
            candidates: candidates
        )

        XCTAssertEqual(IdleMotionController.reservationDistance(for: distant), 60)
        XCTAssertEqual(IdleMotionController.reservationDistance(for: close), 44)
    }

    @MainActor
    func testRuntimeMBTIUpdateChangesNextIdlePresetWithoutInterruptingWorking() throws {
        let catalog = try MBTIPresetLoader.loadBundled()
        let identity = BotIdentity(id: "runtime-mbti", name: "Runtime", shape: .blob, color: .blue)
        let pet = PetLayer(identity: identity)
        let motion = IdleMotionController(coordinator: AnimationCoordinator())
        let geometry = EdgeGeometry(screenFrame: CGRect(x: 0, y: 0, width: 800, height: 600), visibleFrame: CGRect(x: 0, y: 50, width: 800, height: 550))
        motion.start(pet: pet, geometry: geometry, preset: catalog.neutral)
        motion.start(pet: pet, geometry: geometry, preset: catalog.preset(for: .istj))
        XCTAssertEqual(motion.currentPreset(for: identity.id), catalog.preset(for: .istj))
        motion.stopAll(pets: [pet])

        let scene = PetSceneController(frame: geometry.screenFrame, visibleFrame: geometry.visibleFrame, allowsEdgeMotion: false)
        let neutral = PetConfiguration(botId: identity.id, isVisible: true, mbti: nil, globalOrder: 0)
        scene.synchronize(identities: [identity], configurations: [neutral])
        scene.showAll()
        scene.updatePresence(.working, botId: identity.id, revision: 9)
        let scenePet = try XCTUnwrap(scene.petLayer(for: identity.id))
        XCTAssertNotNil(scenePet.animation(forKey: "workspace.opacity"))
        let entp = PetConfiguration(botId: identity.id, isVisible: true, mbti: .entp, globalOrder: 0)
        scene.synchronize(identities: [identity], configurations: [entp])
        XCTAssertNotNil(scenePet.animation(forKey: "workspace.opacity"))
        XCTAssertNil(scenePet.mbtiDecorationLayer.decorationID, "1.1 accessory art remains behind the approval gate")
        scene.shutdown()
    }

    func testGroupSocialDistanceChangesSpacingAndKeepsSixMembersDisjoint() {
        let visible = CGRect(x: 0, y: 50, width: 1000, height: 700)
        let ids = (0..<6).map { "bot-\($0)" }
        let close = GroupStationLayout().placement(visibleFrame: visible, orderedMemberIds: ids, socialDistancesByBot: Dictionary(uniqueKeysWithValues: ids.map { ($0, CGFloat(44)) }))!
        let distant = GroupStationLayout().placement(visibleFrame: visible, orderedMemberIds: ids, socialDistancesByBot: Dictionary(uniqueKeysWithValues: ids.map { ($0, CGFloat(60)) }))!
        XCTAssertGreaterThan(distant.baseFrame.width, close.baseFrame.width)
        for placement in [close, distant] {
            let frames = ids.compactMap { placement.memberFrames[$0] }
            for left in frames.indices {
                for right in frames.indices where left < right {
                    XCTAssertFalse(frames[left].intersects(frames[right]))
                }
            }
        }
    }

    @MainActor
    func testSafeAreaFixtureFlowsThroughObserverGeometryAndSceneEdgeBounds() {
        let rawFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let rawVisible = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let insets = EdgeInsets(top: 38, left: 80, bottom: 50, right: 0)
        let geometry = MainScreenObserver.geometry(frame: rawFrame, visibleFrame: rawVisible, safeAreaInsets: insets)
        XCTAssertEqual(geometry.visibleFrame, CGRect(x: 80, y: 50, width: 1432, height: 894))
        XCTAssertEqual(geometry.safeAreaInsets, insets)
        let scene = PetSceneController(frame: geometry.frame, visibleFrame: geometry.visibleFrame, safeAreaInsets: geometry.safeAreaInsets, allowsEdgeMotion: false)
        XCTAssertEqual(scene.currentEdgeGeometry.leftX, 98)
        XCTAssertEqual(scene.currentEdgeGeometry.floorY, 50)
        XCTAssertEqual(scene.currentEdgeGeometry.ceilingY, 908)
        scene.shutdown()
    }

    @MainActor
    func testGroupBaseRequiresAnActualVisibleAssignment() {
        let scene = PetSceneController(frame: CGRect(x: 0, y: 0, width: 800, height: 600), visibleFrame: CGRect(x: 0, y: 50, width: 800, height: 550), allowsEdgeMotion: false)
        let identity = BotIdentity(id: "visible", name: "Visible", shape: .blob, color: .blue)
        scene.synchronize(identities: [identity])
        scene.showAll()
        let session = ActiveGroupSession(groupId: "empty", memberIds: ["missing"], groupRunning: true, memberRunning: ["missing"])
        scene.updateGroupActivity(GroupActivitySnapshot(sessions: ["empty": session], assignments: [:]), presenceByBot: [:], revision: 1)
        XCTAssertTrue(scene.groupStationLayers.isEmpty)
        scene.shutdown()
    }

    @MainActor
    func testHideCancelsWorkstationAndGroupLayerAnimations() throws {
        let scene = PetSceneController(frame: CGRect(x: 0, y: 0, width: 800, height: 600), visibleFrame: CGRect(x: 0, y: 50, width: 800, height: 550), allowsEdgeMotion: false)
        let identity = BotIdentity(id: "animated", name: "Animated", shape: .blob, color: .blue)
        scene.synchronize(identities: [identity])
        scene.showAll()
        scene.updatePresence(.working, botId: identity.id, revision: 1)
        let pet = try XCTUnwrap(scene.petLayer(for: identity.id))
        XCTAssertNotNil(pet.animation(forKey: "workspace.opacity"))
        let assignment = GroupMemberAssignment(botId: identity.id, groupId: "fixture", mode: .working)
        let session = ActiveGroupSession(groupId: "fixture", memberIds: [identity.id], groupRunning: true, memberRunning: [identity.id])
        scene.updateGroupActivity(
            GroupActivitySnapshot(sessions: ["fixture": session], assignments: [identity.id: assignment]),
            presenceByBot: [identity.id: .working],
            revision: 2
        )
        scene.hideAll()
        XCTAssertNil(pet.animationKeys())
        scene.shutdown()
    }

    @MainActor
    func testIdleAndWorkAnimationsIncludeContractLiveliness() {
        let pet = PetLayer(identity: BotIdentity(id: "lively", name: "Lively", shape: .blob, color: .blue))
        let coordinator = AnimationCoordinator()
        coordinator.play(.idleBreathe, on: pet, duration: 3, phase: 0)
        let breathe = pet.bodyShapeLayer.animation(forKey: "breathe") as? CAAnimationGroup
        let keyPaths = Set((breathe?.animations ?? []).compactMap { ($0 as? CAPropertyAnimation)?.keyPath })
        XCTAssertEqual(keyPaths, Set(["transform.scale.x", "transform.scale.y"]))
        XCTAssertNotNil(pet.faceLayer.animation(forKey: "idleGaze"))
        XCTAssertNotNil(pet.faceLayer.animation(forKey: "idleBlink"))
        coordinator.play(.workInGroup, on: pet, duration: 2, phase: 0.25)
        XCTAssertNotNil(pet.faceLayer.animation(forKey: "workBlink"))
        XCTAssertNotEqual(pet.faceLayer.gazeOffset.x, 0)
        coordinator.cancelAll(pets: [pet])
    }

    @MainActor
    func testSceneUsesOneClickThroughPanelAndCapsPetsAtSix() {
        let scene = PetSceneController(frame: CGRect(x: 0, y: 0, width: 800, height: 600), visibleFrame: CGRect(x: 0, y: 50, width: 800, height: 550))
        let identities = (0..<8).map { index in
            BotIdentity(id: "bot-\(index)", name: "Bot \(index)", shape: OfficialShape.allCases[index % 8], color: OfficialColor.allCases[index % 11])
        }
        scene.synchronize(identities: identities)
        XCTAssertFalse(scene.panel.ignoresMouseEvents)
        XCTAssertFalse(scene.panel.isOpaque)
        XCTAssertEqual(scene.petLayers.count, 6)
        XCTAssertTrue(scene.petLayers.values.allSatisfy { $0.superlayer === scene.sceneLayer })
        scene.shutdown()
    }

    @MainActor
    func testSameBotIdentityUpdatesOfficialShapeAndColorInPlace() {
        let scene = PetSceneController(
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            visibleFrame: CGRect(x: 0, y: 50, width: 800, height: 550)
        )
        scene.synchronize(identities: [BotIdentity(id: "stable", name: "Bot", shape: .blob, color: .blue)])
        let originalLayer = scene.petLayer(for: "stable")

        scene.synchronize(identities: [BotIdentity(id: "stable", name: "Bot", shape: .wedge, color: .magenta)])

        XCTAssertTrue(scene.petLayer(for: "stable") === originalLayer)
        XCTAssertEqual(originalLayer?.shape, .wedge)
        XCTAssertEqual(originalLayer?.color, .magenta)
        scene.shutdown()
    }

    @MainActor
    func testHideAllCancelsVisibleLayerAnimations() {
        let scene = PetSceneController(
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            visibleFrame: CGRect(x: 0, y: 50, width: 800, height: 550)
        )
        let identity = BotIdentity(id: "bot", name: "Bot", shape: .blob, color: .blue)
        scene.synchronize(identities: [identity])
        let pet = scene.petLayer(for: identity.id)!
        pet.add(CABasicAnimation(keyPath: "opacity"), forKey: "fixture-animation")

        scene.hideAll()

        XCTAssertNil(pet.animationKeys())
        XCTAssertFalse(scene.isVisible)
        scene.shutdown()
    }

    @MainActor
    func testHiddenSceneRejectsNewPresenceAnimationsAndRestoresSameRevisionOnShow() throws {
        let scene = PetSceneController(
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            visibleFrame: CGRect(x: 0, y: 50, width: 800, height: 550),
            allowsEdgeMotion: false
        )
        let identity = BotIdentity(id: "hidden", name: "Hidden", shape: .blob, color: .blue)
        scene.synchronize(identities: [identity])
        scene.showAll()
        scene.updatePresence(.idle, botId: identity.id, revision: 1)
        let pet = scene.petLayer(for: identity.id)!
        XCTAssertNil(pet.bodyShapeLayer.animation(forKey: "breathe"))

        scene.hideAll()
        scene.updatePresence(.working, botId: identity.id, revision: 2)

        XCTAssertNil(pet.animationKeys())
        XCTAssertNil(pet.bodyShapeLayer.animationKeys())
        XCTAssertNil(pet.mbtiDecorationLayer.animationKeys())

        scene.showAll()

        XCTAssertNotNil(pet.animation(forKey: "workspace.opacity"))
        scene.shutdown()
    }

    @MainActor
    func testHiddenSceneRejectsGroupAnimationsAndRestoresLatestGroupOnShow() throws {
        let scene = PetSceneController(
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            visibleFrame: CGRect(x: 0, y: 50, width: 800, height: 550)
        )
        let identity = BotIdentity(id: "member", name: "Member", shape: .cloud, color: .cyan)
        scene.synchronize(identities: [identity])
        scene.showAll()
        scene.hideAll()
        let assignment = GroupMemberAssignment(botId: identity.id, groupId: "group", mode: .working)
        let session = ActiveGroupSession(
            groupId: "group",
            memberIds: [identity.id],
            groupRunning: true,
            memberRunning: [identity.id]
        )
        let snapshot = GroupActivitySnapshot(
            sessions: ["group": session],
            assignments: [identity.id: assignment]
        )
        let pet = scene.petLayer(for: identity.id)!

        scene.updateGroupActivity(snapshot, presenceByBot: [identity.id: .working], revision: 7)
        XCTAssertNil(pet.animationKeys())
        XCTAssertNil(pet.bodyShapeLayer.animationKeys())

        scene.showAll()

        XCTAssertNotNil(pet.animation(forKey: "workspace.opacity"))
        scene.shutdown()
    }

    @MainActor
    func testStableIdleFixtureBreathesWithoutStartingEdgeTravel() throws {
        let scene = PetSceneController(
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            visibleFrame: CGRect(x: 0, y: 50, width: 800, height: 550),
            allowsEdgeMotion: false
        )
        let identity = BotIdentity(id: "stable-idle", name: "Stable", shape: .blob, color: .blue)
        scene.synchronize(identities: [identity])
        scene.showAll()
        scene.updatePresence(.idle, botId: identity.id, revision: 1)
        let pet = scene.petLayer(for: identity.id)!

        XCTAssertTrue(scene.fogLayer.isHidden)
        XCTAssertNil(pet.animation(forKey: "edgeTranslation"))
        scene.shutdown()
    }

    @MainActor
    func testMBTIDecorationUsesTheSameLightweightBreathingCycle() {
        let pet = PetLayer(identity: BotIdentity(id: "decorated", name: "Decorated", shape: .cloud, color: .cyan))
        pet.setMBTIDecoration(DecorationID.butterfly.rawValue)
        let coordinator = AnimationCoordinator()

        coordinator.play(.idleBreathe, on: pet, duration: 3, phase: 0.5)

        XCTAssertNotNil(pet.bodyShapeLayer.animation(forKey: "breathe"))
        XCTAssertNotNil(pet.mbtiDecorationLayer.animation(forKey: "decorationBreathe"))
        coordinator.cancelAll(pets: [pet])
        XCTAssertNil(pet.mbtiDecorationLayer.animationKeys())
    }

    @MainActor
    func testCustomLayersSupportCoreAnimationPresentationCopies() {
        let identity = BotIdentity(id: "copy", name: "Copy", shape: .teardrop, color: .magenta)
        let pet = PetLayer(identity: identity)
        pet.setMBTIDecoration(DecorationID.tinyDrill.rawValue)
        let petCopy = PetLayer(layer: pet)
        let faceCopy = FaceLayer(layer: pet.faceLayer)
        let decorationCopy = DecorationLayer(layer: pet.mbtiDecorationLayer)
        let stationCopy = WorkstationLayer(layer: WorkstationLayer())
        let groupCopy = GroupStationLayer(layer: GroupStationLayer())

        XCTAssertEqual(petCopy.botId, identity.id)
        XCTAssertEqual(petCopy.shape, identity.shape)
        XCTAssertEqual(faceCopy.shape, identity.shape)
        XCTAssertEqual(decorationCopy.decorationID, .tinyDrill)
        XCTAssertNotNil(stationCopy)
        XCTAssertNotNil(groupCopy)
    }
}
