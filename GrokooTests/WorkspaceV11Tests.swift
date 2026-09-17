import AppKit
import XCTest
@testable import Grokoo

final class WorkspaceV11Tests: XCTestCase {
    func testSevenStatePriorityAndStructuredOnlySignals() {
        var reducer = PresenceReducer()
        let now = ContinuousClock.now
        XCTAssertEqual(reducer.reduce(botId: "b", runtime: BotRuntime(isRunning: true), gatewayAvailable: true, now: now), .working)
        XCTAssertEqual(reducer.reduce(botId: "b", runtime: BotRuntime(isRunning: true, isComposing: true), gatewayAvailable: true, now: now), .thinking)
        XCTAssertEqual(reducer.reduce(botId: "b", runtime: BotRuntime(isRunning: true, isComposing: true, awaitingUserResponse: .present), gatewayAvailable: true, now: now), .waiting)
        XCTAssertEqual(reducer.reduce(botId: "b", runtime: BotRuntime(isRunning: true, isComposing: true, awaitingUserResponse: .present, blockedEvent: StructuredEventRef("block-1")), gatewayAvailable: true, now: now), .blocked)
        XCTAssertEqual(reducer.reduce(botId: "b", runtime: BotRuntime(isRunning: true), gatewayAvailable: false, now: now), .offline)
        XCTAssertEqual(PresenceState.allCases, [.idle, .working, .thinking, .waiting, .blocked, .done, .offline])
    }

    func testInitialRunningSnapshotWithOldRevisionDoesNotCreateCompletion() {
        var reducer = PresenceReducer()
        XCTAssertEqual(reducer.reduce(botId: "b", runtime: BotRuntime(isRunning: true, messageRevision: "old", taskRevision: "t"), gatewayAvailable: true), .working)
        XCTAssertEqual(reducer.reduce(botId: "b", runtime: BotRuntime(messageRevision: "old"), gatewayAvailable: true), .idle)
        XCTAssertNil(reducer.completionLedger.pending(for: "b"))
    }

    func testFixtureBlockedUsesStructuredEventAndDeduplicates() {
        var reducer = PresenceReducer()
        let runtime = BotRuntime(isRunning: true, blockedEvent: StructuredEventRef("fixture-block"), fixtureState: .blocked)
        XCTAssertEqual(reducer.reduce(botId: "b", runtime: runtime, gatewayAvailable: true), .blocked)
        XCTAssertEqual(reducer.lastTransition?.newBlockedEventId, "fixture-block")
        _ = reducer.reduce(botId: "b", runtime: runtime, gatewayAvailable: true)
        XCTAssertNil(reducer.lastTransition?.newBlockedEventId)
    }

    func testDonePersistsAcrossReducerRestartAcknowledgesAndIsSupersededByNewTask() {
        var first = PresenceReducer()
        let now = ContinuousClock.now
        XCTAssertEqual(first.reduce(botId: "b", runtime: BotRuntime(isRunning: true, taskRevision: "task-1"), gatewayAvailable: true, now: now), .working)
        XCTAssertEqual(first.reduce(botId: "b", runtime: BotRuntime(messageRevision: "result-1"), gatewayAvailable: true, now: now), .done)
        let saved = first.completionLedger

        var restored = PresenceReducer(completionLedger: saved)
        XCTAssertEqual(restored.reduce(botId: "b", runtime: BotRuntime(messageRevision: "result-1"), gatewayAvailable: true, now: now, isReplay: true), .done)
        XCTAssertNil(restored.lastTransition?.newDoneEventId)
        XCTAssertEqual(restored.reduce(botId: "b", runtime: BotRuntime(isRunning: true, taskRevision: "task-2"), gatewayAvailable: true, now: now), .working)
        XCTAssertEqual(restored.completionLedger.records.last?.status, .superseded)

        var acknowledged = PresenceReducer(completionLedger: saved)
        acknowledged.acknowledgeDone(botId: "b")
        XCTAssertEqual(acknowledged.reduce(botId: "b", runtime: BotRuntime(messageRevision: "result-1"), gatewayAvailable: true, now: now), .idle)
    }

    func testCompletionLedgerStoreRoundTripContainsNoContentFields() throws {
        let suite = "CompletionLedgerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CompletionLedgerStore(defaults: defaults, key: "ledger")
        var ledger = CompletionLedger()
        XCTAssertTrue(ledger.register(botId: "b", eventId: "anonymous-1", at: Date(timeIntervalSince1970: 10)))
        store.save(ledger)
        XCTAssertEqual(store.load(), ledger)
        let data = try XCTUnwrap(defaults.data(forKey: "ledger"))
        let text = String(decoding: data, as: UTF8.self)
        for forbidden in ["prompt", "body", "fileName", "url", "groupTopic", "errorDetail"] {
            XCTAssertFalse(text.localizedCaseInsensitiveContains(forbidden))
        }
    }

    func testAggregateAndOfflineUnavailableSemantics() {
        let states: [BotID: PresenceState] = [
            "w": .working, "t": .thinking, "wait": .waiting,
            "block": .blocked, "done": .done, "idle": .idle,
        ]
        XCTAssertEqual(
            PresenceAggregate.make(states: states, gatewayAvailable: true),
            PresenceAggregate(activeBotCount: 4, attentionPresent: true, waitingCount: 1, blockedCount: 1, pendingDoneCount: 1)
        )
        XCTAssertEqual(
            PresenceAggregate.make(states: states, gatewayAvailable: false),
            PresenceAggregate(activeBotCount: nil, attentionPresent: true, waitingCount: 0, blockedCount: 0, pendingDoneCount: 1)
        )
    }

    func testNotificationsDeduplicateMergeAndExposeOnlySafePayload() {
        let start = Date(timeIntervalSince1970: 100)
        var queue = NotificationEventQueue()
        XCTAssertNil(queue.ingestBlocked(eventId: "block-1", botId: "a", botName: "Atlas", at: start, isReplay: true))
        let blocked = queue.ingestBlocked(eventId: "block-1", botId: "a", botName: "Atlas", at: start)
        XCTAssertEqual(blocked, .blocked(eventId: "block-1", payload: .init(title: "Atlas 需要你", body: "打开 Grok Bot 查看并继续处理。", destination: .bot("a"))))
        XCTAssertNil(queue.ingestBlocked(eventId: "block-1", botId: "a", botName: "Atlas", at: start))

        queue.ingestDone(eventId: "done-1", botId: "a", botName: "Atlas", at: start)
        queue.ingestDone(eventId: "done-2", botId: "b", botName: "Nova", at: start.addingTimeInterval(2))
        XCTAssertNil(queue.flushDone(at: start.addingTimeInterval(2.9)))
        guard case .done(let ids, let payload) = queue.flushDone(at: start.addingTimeInterval(3)) else {
            return XCTFail("Expected merged Done")
        }
        XCTAssertEqual(ids, ["done-1", "done-2"])
        XCTAssertEqual(payload.title, "2 个任务已完成")
        let encoded = String(decoding: try! JSONEncoder().encode(payload), as: UTF8.self)
        for secret in ["Prompt text", "secret.txt", "https://", "detailed error"] { XCTAssertFalse(encoded.contains(secret)) }
    }

    func testLiveGatewayReportsBlockedCapabilityGap() {
        XCTAssertEqual(GatewayPresenceAdapter.liveCapabilities.blocked, .unavailable)
        let record = GatewayAgentRecord(
            id: "b", name: "Bot", isGroup: false, memberIds: [], avatarShape: nil, avatarColor: nil,
            isRunning: true, isComposingMessage: true, hasAwaitingUserResponse: false, messageRevision: "r"
        )
        let runtime = GatewayPresenceAdapter.runtime(from: record)
        XCTAssertTrue(runtime.isThinking)
        XCTAssertNil(runtime.blockedEvent)
    }

    func testWorkspaceLayoutsAndFogGeometry() {
        let engine = WorkspaceLayoutEngine()
        let topology = ScreenTopology(
            screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            safeFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            dockEdge: .bottom,
            dockReferenceFrame: CGRect(x: 400, y: 0, width: 640, height: 70),
            scale: 2,
            mainScreenID: "main"
        )
        let scenarios: [[WorkspaceMember]] = [
            (0..<1).map { .init(botId: "s\($0)", membership: .solo) },
            (0..<6).map { .init(botId: "s\($0)", membership: .solo) },
            (0..<6).map { .init(botId: "g\($0)", membership: .group("one")) },
            (0..<2).map { .init(botId: "a\($0)", membership: .group("a")) } + (0..<4).map { .init(botId: "b\($0)", membership: .group("b")) },
            [.init(botId: "solo", membership: .solo)] + (0..<3).map { .init(botId: "m\($0)", membership: .group("m")) },
        ]
        for members in scenarios {
            let placement = engine.placement(members: members, topology: topology)
            XCTAssertEqual(placement.surfaceFrame.height, 18)
            XCTAssertTrue((88...320).contains(placement.surfaceFrame.width))
            XCTAssertEqual(placement.surfaceFrame.minY, 84)
            XCTAssertEqual(placement.petFrames.count, members.count)
            let frames = Array(placement.petFrames.values)
            for left in frames.indices {
                for right in frames.indices where left < right { XCTAssertFalse(frames[left].intersects(frames[right])) }
            }
        }
    }

    func testSideDockAnchorAndAutohideReferenceAreStable() {
        let resolver = WorkspaceAnchorResolver()
        let size = CGSize(width: 200, height: 18)
        for edge in [DockEdge.left, .right] {
            let topology = ScreenTopology(
                screenFrame: CGRect(x: 0, y: 0, width: 1200, height: 800),
                safeFrame: CGRect(x: 0, y: 10, width: 1200, height: 790),
                dockEdge: edge,
                dockReferenceFrame: nil,
                scale: 2,
                mainScreenID: "main"
            )
            XCTAssertEqual(resolver.surfaceOrigin(topology: topology, surfaceSize: size), CGPoint(x: 500, y: 24))
        }
    }

    @MainActor
    func testSettingsV1MigrationUsesOneStableGlobalOrderAndHiddenBotsDoNotJump() throws {
        let suite = "SettingsMigration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy: [String: Any] = [
            "schemaVersion": 1,
            "bots": [
                ["botId":"r", "isVisible":true, "mbti":NSNull(), "workstationRegion":"right", "workstationOrder":0],
                ["botId":"l", "isVisible":true, "mbti":NSNull(), "workstationRegion":"left", "workstationOrder":0],
                ["botId":"c", "isVisible":true, "mbti":NSNull(), "workstationRegion":"center", "workstationOrder":0],
            ]
        ]
        defaults.set(try JSONSerialization.data(withJSONObject: legacy), forKey: SettingsStore.defaultStorageKey)
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.configurations.map(\.botId), ["l", "c", "r"])
        XCTAssertEqual(store.configurations.map(\.globalOrder), [0, 1, 2])
        XCTAssertTrue(store.setVisibility(false, for: "c"))
        XCTAssertEqual(store.configurations.map(\.botId), ["l", "c", "r"])
    }

    func testAssetSlotsCoverEightBySixteenWithoutLoadingCandidateAssets() {
        XCTAssertEqual(AccessoryID.allCases.count, 16)
        XCTAssertEqual(BodyAnchorCatalog.anchors.count, 8)
        XCTAssertEqual(AccessoryID.allCases.flatMap { accessory in OfficialShape.allCases.map { _ in accessory.assetCatalogKey } }.count, 128)
        XCTAssertTrue(AssetContract.isSupportedBodySize(32))
        XCTAssertTrue(AssetContract.isSupportedBodySize(42))
        XCTAssertEqual(MotionProfileMap.reserved.count, 7)
    }

    @MainActor
    func testInvisibleSceneAreaDoesNotHitTest() {
        let view = InteractiveSceneView(frame: CGRect(x: 0, y: 0, width: 500, height: 300))
        view.interactiveRegions = [CGRect(x: 100, y: 100, width: 42, height: 42)]
        XCTAssertNil(view.hitTest(CGPoint(x: 20, y: 20)))
        XCTAssertTrue(view.hitTest(CGPoint(x: 110, y: 110)) === view)
        view.isHidden = true
        XCTAssertNil(view.hitTest(CGPoint(x: 110, y: 110)))
    }
}
