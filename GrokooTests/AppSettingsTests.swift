import AppKit
import XCTest
@testable import Grokoo

final class AppSettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "GrokooTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    @MainActor
    func testFirstMergeSelectsAtMostFirstSixOrdinaryBots() {
        let store = makeStore()
        let botIDs = (1...7).map { "bot-\($0)" }

        let result = store.merge(botIDs: botIDs)

        XCTAssertTrue(result.wasInitialSetup)
        XCTAssertEqual(result.configurations.filter(\.isVisible).map(\.botId), Array(botIDs.prefix(6)))
        XCTAssertFalse(result.configurations[6].isVisible)
        XCTAssertTrue(store.hasPersistedConfiguration)
    }

    @MainActor
    func testMenuBarUsesTemplateIconAndRequiredActions() {
        let menu = MenuBarController(
            onShowAll: {},
            onHideAll: {},
            onOpenSettings: {},
            onQuit: {}
        )

        XCTAssertTrue(menu.usesTemplateIcon)
        XCTAssertEqual(menu.menuItemTitles, ["当前没有运行中的 Bot", "等待 0 · 受阻 0 · 待收起 0", "显示全部", "隐藏全部", "设置…", "退出 Grokoo"])
        menu.shutdown()
    }

    @MainActor
    func testExistingSettingsSurviveRosterReorderingAndNewBotStartsHidden() {
        let store = makeStore()
        store.merge(botIDs: ["one", "two"])
        store.setVisibility(false, for: "one")
        store.setMBTI(.entp, for: "two")

        let result = store.merge(botIDs: ["two", "three", "one"])

        XCTAssertFalse(result.wasInitialSetup)
        XCTAssertEqual(store.configuration(for: "two")?.mbti, .entp)
        XCTAssertEqual(store.configuration(for: "two")?.globalOrder, 1)
        XCTAssertFalse(store.configuration(for: "one")?.isVisible ?? true)
        XCTAssertFalse(store.configuration(for: "three")?.isVisible ?? true)
    }

    @MainActor
    func testDeletedBotIsRemovedWithoutChangingOtherBotConfiguration() {
        let store = makeStore()
        store.merge(botIDs: ["one", "two", "three"])
        store.setMBTI(.infp, for: "two")

        store.merge(botIDs: ["two", "three"])

        XCTAssertNil(store.configuration(for: "one"))
        XCTAssertEqual(store.configuration(for: "two")?.mbti, .infp)
        XCTAssertEqual(store.configuration(for: "two")?.globalOrder, 0)
        XCTAssertNotNil(store.configuration(for: "three"))
    }

    @MainActor
    func testSeventhBotCannotBecomeVisibleUntilAnotherBotIsHidden() {
        let store = makeStore()
        store.merge(botIDs: (1...7).map { "bot-\($0)" })

        XCTAssertFalse(store.setVisibility(true, for: "bot-7"))
        XCTAssertTrue(store.setVisibility(false, for: "bot-2"))
        XCTAssertTrue(store.setVisibility(true, for: "bot-7"))
        XCTAssertEqual(store.configurations.filter(\.isVisible).count, 6)
    }

    @MainActor
    func testGlobalMoveUsesStableSingleListOrder() {
        let store = makeStore()
        let viewModel = SettingsViewModel(store: store)
        store.merge(botIDs: ["one", "two", "three"])

        viewModel.move(botId: "three", delta: -1)
        XCTAssertEqual(store.configurations.sorted { $0.globalOrder < $1.globalOrder }.map(\.botId), ["one", "three", "two"])
    }

    @MainActor
    func testPersistenceContainsOnlySchemaAndAllowedBotFields() throws {
        let store = makeStore()
        store.merge(botIDs: ["one"])
        store.setMBTI(.istp, for: "one")

        let data = try XCTUnwrap(defaults.data(forKey: SettingsStore.defaultStorageKey))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["schemaVersion", "bots"])
        let bots = try XCTUnwrap(object["bots"] as? [[String: Any]])
        XCTAssertEqual(
            Set(try XCTUnwrap(bots.first).keys),
            ["botId", "isVisible", "mbti", "globalOrder"]
        )

        let restored = makeStore()
        XCTAssertEqual(restored.configurations, store.configurations)
    }

    @MainActor
    func testInjectableLifecycleAndScreenCallbacksReachRuntimeServices() {
        let store = makeStore()
        let viewModel = SettingsViewModel(store: store)
        let settings = SettingsWindowController(viewModel: viewModel)
        let petScene = PetSceneSpy()
        let gateway = GatewayRuntimeSpy()
        let lifecycle = LifecycleObserverSpy()
        let screens = ScreenObserverSpy()
        let coordinator = AppCoordinator(
            settingsStore: store,
            settingsWindowController: settings,
            petScene: petScene,
            gateway: gateway,
            lifecycleObserver: lifecycle,
            screenObserver: screens
        )
        let geometry = MainScreenGeometry(
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 50, width: 1512, height: 900)
        )

        coordinator.injectLifecycleWillSleep()
        coordinator.injectMainScreen(geometry)
        coordinator.injectLifecycleDidWake()

        XCTAssertEqual(gateway.suspendCount, 1)
        XCTAssertEqual(gateway.resumeCount, 1)
        XCTAssertEqual(petScene.hideCount, 1)
        XCTAssertEqual(petScene.showCount, 1)
        XCTAssertEqual(petScene.geometries.last, geometry)
        coordinator.shutdown()
    }

    @MainActor
    func testGlobalVisibilityChoiceSurvivesInjectedSleepWake() {
        let store = makeStore()
        let settings = SettingsWindowController(viewModel: SettingsViewModel(store: store))
        let petScene = PetSceneSpy()
        let coordinator = AppCoordinator(
            settingsStore: store,
            settingsWindowController: settings,
            petScene: petScene,
            gateway: GatewayRuntimeSpy(),
            lifecycleObserver: LifecycleObserverSpy(),
            screenObserver: ScreenObserverSpy()
        )

        coordinator.hideAll()
        coordinator.injectLifecycleWillSleep()
        coordinator.injectLifecycleDidWake()

        XCTAssertEqual(petScene.showCount, 0)
        XCTAssertEqual(petScene.hideCount, 2)
        coordinator.shutdown()
    }

    @MainActor
    func testHiddenChoiceSurvivesDelayedInitialRosterResolution() {
        let store = makeStore()
        let petScene = PetSceneSpy()
        let coordinator = AppCoordinator(
            settingsStore: store,
            settingsWindowController: SettingsWindowController(viewModel: SettingsViewModel(store: store)),
            petScene: petScene,
            gateway: GatewayRuntimeSpy(),
            lifecycleObserver: LifecycleObserverSpy(),
            screenObserver: ScreenObserverSpy()
        )

        coordinator.hideAll()
        coordinator.resolveInitialRoster([
            BotIdentity(id: "bot", name: "Bot", shape: .blob, color: .blue)
        ])

        XCTAssertEqual(petScene.hideCount, 1)
        XCTAssertEqual(petScene.showCount, 0)
        coordinator.shutdown()
    }

    @MainActor
    func testSleepingDefersDelayedRosterAndConnectionRenderingUntilWake() {
        let store = makeStore()
        let petScene = PetSceneSpy()
        let gateway = GatewayRuntimeSpy()
        let coordinator = AppCoordinator(
            settingsStore: store,
            settingsWindowController: SettingsWindowController(viewModel: SettingsViewModel(store: store)),
            petScene: petScene,
            gateway: gateway,
            lifecycleObserver: LifecycleObserverSpy(),
            screenObserver: ScreenObserverSpy()
        )
        let identity = BotIdentity(id: "delayed", name: "Delayed", shape: .blob, color: .blue)
        let roster = RosterSnapshot(
            bots: [identity.id: BotPresence(identity: identity, runtime: BotRuntime(isRunning: true))],
            groups: [:],
            botOrder: [identity.id]
        )
        let synchronizationCountBeforeSleep = petScene.synchronizedConfigurations.count

        coordinator.injectLifecycleWillSleep()
        coordinator.updateSnapshot(roster)
        coordinator.updateConnectionState(.connected)
        coordinator.resolveInitialRoster([identity])

        XCTAssertEqual(petScene.showCount, 0)
        XCTAssertTrue(petScene.presences.isEmpty)
        XCTAssertEqual(petScene.synchronizedConfigurations.count, synchronizationCountBeforeSleep)

        coordinator.injectLifecycleDidWake()

        XCTAssertEqual(gateway.resumeCount, 1)
        XCTAssertEqual(petScene.showCount, 1)
        XCTAssertEqual(petScene.presences.last?.botId, identity.id)
        XCTAssertEqual(petScene.presences.last?.state, .working)
        XCTAssertEqual(petScene.synchronizedConfigurations.count, synchronizationCountBeforeSleep + 1)
        coordinator.shutdown()
    }

    @MainActor
    func testConnectionChangesRemainVisibleAfterInitialResolution() {
        let store = makeStore()
        let viewModel = SettingsViewModel(store: store)
        let coordinator = AppCoordinator(
            settingsStore: store,
            settingsWindowController: SettingsWindowController(viewModel: viewModel),
            petScene: PetSceneSpy(),
            gateway: GatewayRuntimeSpy(),
            lifecycleObserver: LifecycleObserverSpy(),
            screenObserver: ScreenObserverSpy()
        )

        coordinator.updateConnectionState(.connected)
        coordinator.updateConnectionState(.offline)

        XCTAssertEqual(viewModel.connectionState, .offline)
        coordinator.shutdown()
    }

    @MainActor
    func testPersistedConfigurationIsPassedIntoSceneSynchronization() {
        let store = makeStore()
        store.merge(botIDs: ["bot"])
        store.setMBTI(.entp, for: "bot")
        let petScene = PetSceneSpy()
        let coordinator = AppCoordinator(
            settingsStore: store,
            settingsWindowController: SettingsWindowController(viewModel: SettingsViewModel(store: store)),
            petScene: petScene,
            gateway: GatewayRuntimeSpy(),
            lifecycleObserver: LifecycleObserverSpy(),
            screenObserver: ScreenObserverSpy()
        )
        let identity = BotIdentity(id: "bot", name: "Bot", shape: .blob, color: .blue)

        coordinator.resolveInitialRoster([identity])

        let configuration = petScene.synchronizedConfigurations.last?.first
        XCTAssertEqual(configuration?.botId, "bot")
        XCTAssertEqual(configuration?.mbti, .entp)
        XCTAssertEqual(configuration?.globalOrder, 0)
        coordinator.shutdown()
    }

    @MainActor
    func testOfflineConnectionClearsStaleGroupAndOverridesWorkingPresence() {
        let store = makeStore()
        store.merge(botIDs: ["bot"])
        let petScene = PetSceneSpy()
        let coordinator = AppCoordinator(
            settingsStore: store,
            settingsWindowController: SettingsWindowController(viewModel: SettingsViewModel(store: store)),
            petScene: petScene,
            gateway: GatewayRuntimeSpy(),
            lifecycleObserver: LifecycleObserverSpy(),
            screenObserver: ScreenObserverSpy()
        )
        let identity = BotIdentity(id: "bot", name: "Bot", shape: .blob, color: .blue)
        let roster = RosterSnapshot(
            bots: ["bot": BotPresence(identity: identity, runtime: BotRuntime(isRunning: true))],
            groups: ["group": GroupRuntime(id: "group", memberIds: ["bot"], isRunning: true)],
            botOrder: ["bot"]
        )

        coordinator.updateSnapshot(roster)
        coordinator.updateConnectionState(.connected)
        XCTAssertEqual(petScene.groupSnapshots.last?.assignments["bot"]?.mode, .working)

        coordinator.updateConnectionState(.offline)
        XCTAssertEqual(petScene.groupSnapshots.last, .empty)
        XCTAssertEqual(petScene.presences.last?.state, .offline)
        coordinator.shutdown()
    }

    @MainActor
    func testEveryFirstLaunchResolutionOpensSettingsAndPersistedLaunchDoesNot() {
        let identity = BotIdentity(id: "bot", name: "Bot", shape: .blob, color: .blue)
        let success = makeCoordinator(storageKey: "first.success")
        success.coordinator.resolveInitialRoster([identity])
        XCTAssertEqual(success.window.presentationCount, 1)
        XCTAssertEqual(success.window.viewModel.connectionState, .connected)
        success.coordinator.shutdown()

        let timeout = makeCoordinator(storageKey: "first.timeout")
        timeout.coordinator.resolveInitialFailure(.timedOut)
        XCTAssertEqual(timeout.window.presentationCount, 1)
        XCTAssertEqual(timeout.window.viewModel.connectionState, .timedOut)
        timeout.coordinator.shutdown()

        let denied = makeCoordinator(storageKey: "first.denied")
        denied.coordinator.resolveInitialFailure(.keychainDenied)
        XCTAssertEqual(denied.window.presentationCount, 1)
        XCTAssertEqual(denied.window.viewModel.connectionState, .keychainDenied)
        denied.coordinator.shutdown()

        let noBots = makeCoordinator(storageKey: "first.empty")
        noBots.coordinator.resolveInitialRoster([])
        XCTAssertEqual(noBots.window.presentationCount, 1)
        XCTAssertEqual(noBots.window.viewModel.connectionState, .noBots)
        noBots.coordinator.shutdown()

        let persisted = makeCoordinator(storageKey: "later.persisted", persistedBotId: identity.id)
        persisted.coordinator.resolveInitialRoster([identity])
        XCTAssertEqual(persisted.window.presentationCount, 0)
        persisted.coordinator.shutdown()
    }

    @MainActor
    private func makeStore() -> SettingsStore {
        SettingsStore(defaults: defaults, storageKey: SettingsStore.defaultStorageKey)
    }

    @MainActor
    private func makeCoordinator(
        storageKey: String,
        persistedBotId: BotID? = nil
    ) -> (coordinator: AppCoordinator, window: SettingsWindowController) {
        let store = SettingsStore(defaults: defaults, storageKey: storageKey)
        if let persistedBotId {
            store.merge(botIDs: [persistedBotId])
        }
        let window = SettingsWindowController(viewModel: SettingsViewModel(store: store))
        return (
            AppCoordinator(
                settingsStore: store,
                settingsWindowController: window,
                petScene: PetSceneSpy(),
                gateway: GatewayRuntimeSpy(),
                lifecycleObserver: LifecycleObserverSpy(),
                screenObserver: ScreenObserverSpy()
            ),
            window
        )
    }
}

@MainActor
private final class PetSceneSpy: PetSceneServicing {
    private(set) var showCount = 0
    private(set) var hideCount = 0
    private(set) var shutdownCount = 0
    private(set) var geometries: [MainScreenGeometry] = []
    private(set) var synchronizedConfigurations: [[PetConfiguration]] = []
    private(set) var presences: [(botId: BotID, state: PresenceState)] = []
    private(set) var groupSnapshots: [GroupActivitySnapshot] = []

    func synchronize(identities: [BotIdentity]) {}
    func synchronize(identities: [BotIdentity], configurations: [PetConfiguration]) {
        synchronizedConfigurations.append(configurations)
    }
    func updatePresence(_ state: PresenceState, botId: BotID, revision: UInt64) {
        presences.append((botId, state))
    }
    func updateGroupActivity(
        _ snapshot: GroupActivitySnapshot,
        presenceByBot: [BotID: PresenceState],
        revision: UInt64
    ) {
        groupSnapshots.append(snapshot)
    }
    func showAll() { showCount += 1 }
    func hideAll() { hideCount += 1 }
    func updateMainScreen(frame: CGRect, visibleFrame: CGRect) {
        geometries.append(MainScreenGeometry(frame: frame, visibleFrame: visibleFrame))
    }
    func shutdown() { shutdownCount += 1 }
}

@MainActor
private final class GatewayRuntimeSpy: GatewayRuntimeServicing {
    private(set) var startCount = 0
    private(set) var retryCount = 0
    private(set) var suspendCount = 0
    private(set) var resumeCount = 0
    private(set) var shutdownCount = 0

    func start(callbacks: GatewayRuntimeCallbacks) { startCount += 1 }
    func retry() { retryCount += 1 }
    func suspend() { suspendCount += 1 }
    func resume() { resumeCount += 1 }
    func shutdown() { shutdownCount += 1 }
}

@MainActor
private final class LifecycleObserverSpy: SystemLifecycleObserving {
    var onWillSleep: (() -> Void)?
    var onDidWake: (() -> Void)?
    func start() {}
    func stop() {}
}

@MainActor
private final class ScreenObserverSpy: MainScreenObserving {
    var onChange: ((MainScreenGeometry) -> Void)?
    var current: MainScreenGeometry?
    func start() {}
    func stop() {}
}
