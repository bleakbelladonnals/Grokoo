import AppKit
import XCTest
@testable import Grokoo

final class RuntimeIntegrationTests: XCTestCase {
    @MainActor
    func testGatewaySnapshotDrivesConfiguredScenePresenceAndGroupPriority() throws {
        let suiteName = "GrokooIntegration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(defaults: defaults, storageKey: SettingsStore.defaultStorageKey)
        let scene = RuntimeSceneSpy()
        let gateway = ControllableGatewayRuntime()
        let settings = SettingsWindowController(viewModel: SettingsViewModel(store: store))
        let coordinator = AppCoordinator(
            settingsStore: store,
            settingsWindowController: settings,
            petScene: scene,
            gateway: gateway,
            lifecycleObserver: RuntimeLifecycleSpy(),
            screenObserver: RuntimeScreenSpy()
        )
        coordinator.start()

        let bot1 = BotIdentity(id: "bot-1", name: "Sandy", shape: .blob, color: .blue)
        let bot2 = BotIdentity(id: "bot-2", name: "Ada", shape: .pebble, color: .green)
        gateway.emitSnapshot(RosterSnapshot(
            bots: [
                bot1.id: BotPresence(identity: bot1, runtime: BotRuntime(awaitingUserResponse: .present)),
                bot2.id: BotPresence(identity: bot2, runtime: BotRuntime(isRunning: true))
            ],
            groups: ["group-1": GroupRuntime(id: "group-1", memberIds: [bot1.id, bot2.id], isRunning: true)],
            botOrder: [bot1.id, bot2.id]
        ))
        gateway.resolveInitial([bot1, bot2])
        store.setMBTI(.entp, for: bot1.id)
        store.move(botId: bot1.id, to: 1)
        gateway.emitConnection(.connected)

        XCTAssertEqual(Set(scene.identities.map(\.id)), Set([bot1.id, bot2.id]))
        let configured = try XCTUnwrap(scene.configurations.first { $0.botId == bot1.id })
        XCTAssertEqual(configured.mbti, .entp)
        XCTAssertEqual(configured.globalOrder, 1)
        XCTAssertEqual(scene.states[bot1.id], .waiting)
        XCTAssertEqual(scene.states[bot2.id], .working)
        XCTAssertEqual(scene.latestGroup?.assignments[bot1.id]?.groupId, "group-1")
        XCTAssertEqual(scene.groupPresence[bot1.id], .waiting)

        gateway.emitConnection(.offline)
        XCTAssertEqual(scene.states[bot1.id], .offline)
        XCTAssertEqual(scene.states[bot2.id], .offline)
        XCTAssertEqual(scene.latestGroup, .empty)

        coordinator.shutdown()
        XCTAssertEqual(gateway.shutdownCount, 1)
        XCTAssertEqual(scene.shutdownCount, 1)
    }

    @MainActor
    func testRemovedAndReaddedBotDoesNotInheritCompletionSession() throws {
        let suiteName = "GrokooIntegration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(defaults: defaults, storageKey: SettingsStore.defaultStorageKey)
        let scene = RuntimeSceneSpy()
        let gateway = ControllableGatewayRuntime()
        let coordinator = AppCoordinator(
            settingsStore: store,
            settingsWindowController: SettingsWindowController(viewModel: SettingsViewModel(store: store)),
            petScene: scene,
            gateway: gateway,
            lifecycleObserver: RuntimeLifecycleSpy(),
            screenObserver: RuntimeScreenSpy()
        )
        coordinator.start()
        let identity = BotIdentity(id: "stable-id", name: "Bot", shape: .cloud, color: .cyan)
        gateway.emitSnapshot(roster(identity: identity, runtime: BotRuntime(isRunning: true)))
        gateway.resolveInitial([identity])
        gateway.emitConnection(.connected)
        XCTAssertEqual(scene.states[identity.id], .working)

        gateway.emitSnapshot(.empty)
        gateway.emitSnapshot(roster(identity: identity, runtime: BotRuntime(messageRevision: "rev-old")))
        XCTAssertTrue(store.setVisibility(true, for: identity.id))

        XCTAssertEqual(scene.states[identity.id], .idle)
        coordinator.shutdown()
    }

    @MainActor
    func testRapidGatewaySnapshotsCommitInOrderWithoutDeferredQueue() {
        let suiteName = "GrokooIntegration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let scene = RuntimeSceneSpy()
        let gateway = ControllableGatewayRuntime()
        let coordinator = AppCoordinator(
            settingsStore: SettingsStore(defaults: defaults, storageKey: SettingsStore.defaultStorageKey),
            settingsWindowController: SettingsWindowController(
                viewModel: SettingsViewModel(store: SettingsStore(defaults: defaults, storageKey: "rapid-view"))
            ),
            petScene: scene,
            gateway: gateway,
            lifecycleObserver: RuntimeLifecycleSpy(),
            screenObserver: RuntimeScreenSpy()
        )
        coordinator.start()
        let identity = BotIdentity(id: "rapid", name: "Rapid", shape: .blob, color: .blue)
        gateway.resolveInitial([identity])
        gateway.emitConnection(.connected)

        var totalMilliseconds = 0.0
        var maximumMilliseconds = 0.0
        for index in 0..<1_000 {
            let started = ContinuousClock.now
            gateway.emitSnapshot(roster(
                identity: identity,
                runtime: BotRuntime(isRunning: index.isMultiple(of: 2))
            ))
            let duration = started.duration(to: .now)
            let components = duration.components
            let milliseconds = Double(components.seconds) * 1_000
                + Double(components.attoseconds) / 1_000_000_000_000_000
            totalMilliseconds += milliseconds
            maximumMilliseconds = max(maximumMilliseconds, milliseconds)
        }

        XCTAssertEqual(scene.states[identity.id], .idle)
        XCTAssertEqual(scene.presenceUpdateCount, 1_000)
        XCTAssertLessThan(maximumMilliseconds, 16.67)
        print(String(
            format: "GROKOO_METRIC normalized_snapshot average_ms=%.4f maximum_ms=%.4f count=1000",
            totalMilliseconds / 1_000,
            maximumMilliseconds
        ))
        coordinator.shutdown()
    }

    @MainActor
    func testUnchangedSnapshotAndUnrelatedBotUpdateDoNotReplayStablePetOrGroup() {
        let suiteName = "GrokooIntegration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(defaults: defaults, storageKey: SettingsStore.defaultStorageKey)
        let scene = RuntimeSceneSpy()
        let gateway = ControllableGatewayRuntime()
        let coordinator = AppCoordinator(
            settingsStore: store,
            settingsWindowController: SettingsWindowController(viewModel: SettingsViewModel(store: store)),
            petScene: scene,
            gateway: gateway,
            lifecycleObserver: RuntimeLifecycleSpy(),
            screenObserver: RuntimeScreenSpy()
        )
        coordinator.start()
        let first = BotIdentity(id: "first", name: "First", shape: .blob, color: .blue)
        let second = BotIdentity(id: "second", name: "Second", shape: .pebble, color: .green)
        let unrelated = BotIdentity(id: "unrelated", name: "Unrelated", shape: .cloud, color: .cyan)
        let initial = RosterSnapshot(
            bots: [
                first.id: BotPresence(identity: first, runtime: BotRuntime()),
                second.id: BotPresence(identity: second, runtime: BotRuntime()),
                unrelated.id: BotPresence(identity: unrelated, runtime: BotRuntime())
            ],
            groups: [
                "group": GroupRuntime(id: "group", memberIds: [first.id, second.id], isRunning: true)
            ],
            botOrder: [first.id, second.id, unrelated.id]
        )
        gateway.emitSnapshot(initial)
        gateway.resolveInitial(initial.orderedBots.map(\.identity))
        gateway.emitConnection(.connected)
        let initialPresenceCounts = scene.presenceUpdateCounts
        let initialGroupCount = scene.groupUpdateCount

        gateway.emitSnapshot(initial)

        XCTAssertEqual(scene.presenceUpdateCounts, initialPresenceCounts)
        XCTAssertEqual(scene.groupUpdateCount, initialGroupCount)

        var unrelatedChanged = initial
        unrelatedChanged.bots[unrelated.id]?.runtime.isRunning = true
        gateway.emitSnapshot(unrelatedChanged)

        XCTAssertEqual(scene.presenceUpdateCounts[first.id], initialPresenceCounts[first.id])
        XCTAssertEqual(scene.presenceUpdateCounts[second.id], initialPresenceCounts[second.id])
        XCTAssertEqual(
            scene.presenceUpdateCounts[unrelated.id],
            (initialPresenceCounts[unrelated.id] ?? 0) + 1
        )
        XCTAssertEqual(scene.groupUpdateCount, initialGroupCount)

        var memberChanged = unrelatedChanged
        memberChanged.bots[first.id]?.runtime.isRunning = true
        gateway.emitSnapshot(memberChanged)

        XCTAssertEqual(scene.presenceUpdateCounts[first.id], (initialPresenceCounts[first.id] ?? 0) + 1)
        XCTAssertEqual(scene.presenceUpdateCounts[second.id], initialPresenceCounts[second.id])
        XCTAssertEqual(scene.groupUpdateCount, initialGroupCount + 1)
        coordinator.shutdown()
    }

    @MainActor
    func testFixtureDoneActionsPersistAndDoNotReappearOnRefresh() throws {
        let suite = "DoneInteraction.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        let scene = RuntimeSceneSpy()
        let gateway = AcceptanceFixtureGatewayRuntime(profile: .init(rawValue: "done-2")!)
        let ledger = CompletionLedgerStore(defaults: defaults)
        let coordinator = AppCoordinator(
            settingsStore: store,
            settingsWindowController: SettingsWindowController(viewModel: SettingsViewModel(store: store)),
            petScene: scene, gateway: gateway,
            lifecycleObserver: RuntimeLifecycleSpy(), screenObserver: RuntimeScreenSpy(),
            completionStore: ledger,
            notificationReceiptStore: NotificationReceiptStore(defaults: defaults)
        )
        coordinator.start()
        defer { coordinator.shutdown() }
        XCTAssertEqual(coordinator.currentAggregate.pendingDoneCount, 2)
        coordinator.acknowledgeDone(botId: "fixture-1")
        gateway.retry()
        XCTAssertEqual(scene.states["fixture-1"], .idle)
        XCTAssertEqual(coordinator.currentAggregate.pendingDoneCount, 1)
        coordinator.acknowledgeAllDone()
        gateway.retry()
        XCTAssertEqual(coordinator.currentAggregate.pendingDoneCount, 0)
        XCTAssertEqual(ledger.load().records.map(\.status), [.acknowledged, .acknowledged])
    }

    @MainActor
    func testHiddenSceneStillUpdatesCompletionNotificationAndOfflineAttention() async throws {
        let suite = "HiddenCompletion.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        let scene = RuntimeSceneSpy()
        let gateway = ControllableGatewayRuntime()
        var notifications: [PresenceNotification] = []
        let coordinator = AppCoordinator(
            settingsStore: store,
            settingsWindowController: SettingsWindowController(viewModel: SettingsViewModel(store: store)),
            petScene: scene, gateway: gateway,
            lifecycleObserver: RuntimeLifecycleSpy(), screenObserver: RuntimeScreenSpy(),
            completionStore: CompletionLedgerStore(defaults: defaults),
            notificationReceiptStore: NotificationReceiptStore(defaults: defaults),
            notificationHandler: { notifications.append($0) }
        )
        coordinator.start()
        defer { coordinator.shutdown() }
        let bot = BotIdentity(id: "hidden", name: "Hidden", shape: .blob, color: .blue)
        gateway.emitSnapshot(roster(identity: bot, runtime: BotRuntime(isRunning: true, taskRevision: "a")))
        gateway.resolveInitial([bot])
        gateway.emitConnection(.connected)
        coordinator.hideAll()
        gateway.emitSnapshot(roster(identity: bot, runtime: BotRuntime(messageRevision: "completed")))
        XCTAssertEqual(coordinator.currentAggregate.pendingDoneCount, 1)
        gateway.emitConnection(.offline)
        XCTAssertNil(coordinator.currentAggregate.activeBotCount)
        XCTAssertEqual(coordinator.currentAggregate.pendingDoneCount, 1)
        XCTAssertTrue(coordinator.currentAggregate.attentionPresent)
        try await Task.sleep(for: .milliseconds(3200))
        XCTAssertEqual(notifications.count, 1)
        coordinator.showAll()
        XCTAssertEqual(scene.states[bot.id], .offline)
        coordinator.acknowledgeAllDone()
        XCTAssertEqual(coordinator.currentAggregate.pendingDoneCount, 0)
    }

    private func roster(identity: BotIdentity, runtime: BotRuntime) -> RosterSnapshot {
        RosterSnapshot(
            bots: [identity.id: BotPresence(identity: identity, runtime: runtime)],
            groups: [:],
            botOrder: [identity.id]
        )
    }
}

@MainActor
private final class RuntimeSceneSpy: PetSceneServicing {
    var identities: [BotIdentity] = []
    var configurations: [PetConfiguration] = []
    var states: [BotID: PresenceState] = [:]
    var latestGroup: GroupActivitySnapshot?
    var groupPresence: [BotID: PresenceState] = [:]
    var shutdownCount = 0
    var presenceUpdateCount = 0
    var presenceUpdateCounts: [BotID: Int] = [:]
    var groupUpdateCount = 0

    func synchronize(identities: [BotIdentity]) { self.identities = identities }
    func synchronize(identities: [BotIdentity], configurations: [PetConfiguration]) {
        self.identities = identities
        self.configurations = configurations
    }
    func updatePresence(_ state: PresenceState, botId: BotID, revision: UInt64) {
        presenceUpdateCount += 1
        presenceUpdateCounts[botId, default: 0] += 1
        states[botId] = state
    }
    func updateGroupActivity(
        _ snapshot: GroupActivitySnapshot,
        presenceByBot: [BotID: PresenceState],
        revision: UInt64
    ) {
        groupUpdateCount += 1
        latestGroup = snapshot
        groupPresence = presenceByBot
    }
    func showAll() {}
    func hideAll() {}
    func updateMainScreen(frame: CGRect, visibleFrame: CGRect) {}
    func shutdown() { shutdownCount += 1 }
}

@MainActor
private final class ControllableGatewayRuntime: GatewayRuntimeServicing {
    private var callbacks: GatewayRuntimeCallbacks?
    var shutdownCount = 0

    func start(callbacks: GatewayRuntimeCallbacks) { self.callbacks = callbacks }
    func retry() {}
    func suspend() {}
    func resume() {}
    func shutdown() { shutdownCount += 1; callbacks = nil }

    func emitSnapshot(_ roster: RosterSnapshot) { callbacks?.didUpdateSnapshot(roster) }
    func resolveInitial(_ identities: [BotIdentity]) { callbacks?.didResolveInitialRoster(identities) }
    func emitConnection(_ state: SettingsConnectionState) { callbacks?.didUpdateConnection(state) }
}

@MainActor
private final class RuntimeLifecycleSpy: SystemLifecycleObserving {
    var onWillSleep: (() -> Void)?
    var onDidWake: (() -> Void)?
    func start() {}
    func stop() {}
}

@MainActor
private final class RuntimeScreenSpy: MainScreenObserving {
    var onChange: ((MainScreenGeometry) -> Void)?
    var current: MainScreenGeometry?
    func start() {}
    func stop() {}
}
