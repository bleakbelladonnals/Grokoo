import AppKit
import Combine
import Foundation

@MainActor
final class AppCoordinator {
    private struct SceneSynchronizationSignature: Equatable {
        let identities: [BotIdentity]
        let configurations: [PetConfiguration]
    }

    private struct GroupRenderSignature: Equatable {
        let snapshot: GroupActivitySnapshot
        let memberPresence: [BotID: PresenceState]
    }

    let settingsStore: SettingsStore
    let settingsWindowController: SettingsWindowController

    private let petScene: PetSceneServicing
    private let gateway: GatewayRuntimeServicing
    private let lifecycleObserver: SystemLifecycleObserving
    private let screenObserver: MainScreenObserving
    private let initialConnectionTimeout: Duration
    private var timeoutTask: Task<Void, Never>?
    private var menuBarController: MenuBarController?
    #if DEBUG
    private lazy var motionExperienceWindow = MotionExperienceWindowController()
    #endif
    private var settingsCancellable: AnyCancellable?
    private var dockSettingsCancellable: AnyCancellable?
    private let dockService: (any DockServicing)?
    private var dockAccessibilityObserver: NSObjectProtocol?
    private var dockRevision: UInt64 = 0
    private var currentIdentities: [BotIdentity] = []
    private var currentRoster: RosterSnapshot = .empty
    private let completionStore: CompletionLedgerStore
    private var presenceReducer: PresenceReducer
    private let notificationReceiptStore: NotificationReceiptStore
    private var notificationQueue: NotificationEventQueue
    private let notificationHandler: (PresenceNotification) -> Void
    private let notificationService: MacOSNotificationService?
    private var doneNotificationTask: Task<Void, Never>?
    private var groupActivityTracker = GroupActivityTracker()
    private var presenceByBot: [BotID: PresenceState] = [:]
    private var synchronizedSceneSignature: SceneSynchronizationSignature?
    private var renderedGroupSignature: GroupRenderSignature?
    private var sceneRevision: UInt64 = 0
    private var gatewayAvailable = false
    private var didResolveInitialConnection = false
    private var isShutdown = false
    private var arePetsGloballyVisible = true
    private var isSystemSleeping = false
    private var deferredMainScreenGeometry: MainScreenGeometry?
    private var isMergingRoster = false
    private(set) var currentAggregate = PresenceAggregate.make(states: [:], gatewayAvailable: false)

    init(
        settingsStore: SettingsStore,
        settingsWindowController: SettingsWindowController,
        petScene: PetSceneServicing,
        gateway: GatewayRuntimeServicing,
        lifecycleObserver: SystemLifecycleObserving,
        screenObserver: MainScreenObserving,
        initialConnectionTimeout: Duration = .seconds(10),
        completionStore: CompletionLedgerStore = CompletionLedgerStore(),
        notificationReceiptStore: NotificationReceiptStore = NotificationReceiptStore(),
        notificationHandler: @escaping (PresenceNotification) -> Void = { _ in },
        notificationService: MacOSNotificationService? = nil,
        dockService: (any DockServicing)? = nil
    ) {
        self.settingsStore = settingsStore
        self.settingsWindowController = settingsWindowController
        self.petScene = petScene
        self.gateway = gateway
        self.lifecycleObserver = lifecycleObserver
        self.screenObserver = screenObserver
        self.initialConnectionTimeout = initialConnectionTimeout
        self.completionStore = completionStore
        presenceReducer = PresenceReducer(completionLedger: completionStore.load())
        self.notificationReceiptStore = notificationReceiptStore
        notificationQueue = NotificationEventQueue(receipts: notificationReceiptStore.load())
        self.notificationHandler = notificationHandler
        self.notificationService = notificationService
        self.dockService = dockService
        settingsCancellable = settingsStore.$configurations.sink { [weak self] configurations in
            guard let self, !self.isMergingRoster else { return }
            self.synchronizeScene(configurations: configurations)
        }
        dockSettingsCancellable = settingsStore.$dockEnabledIDs.dropFirst().sink { [weak self] enabledIDs in
            // Published values arrive before the property's storage is updated.
            self?.renderCurrentPresence(dockEnabledIDs: enabledIDs)
        }
    }

    func start() {
        guard menuBarController == nil, !isShutdown else { return }

        dockService?.onDisableItem = { [weak self] id in self?.settingsStore.setDockEnabled(false, for: id) }
        (dockService as? DockController)?.onError = { [weak self] message in
            self?.settingsWindowController.viewModel.dockErrorMessage = message
        }
        dockService?.onAcknowledgeItem = { [weak self] id in
            self?.acknowledgeDone(botId: Self.presenceID(forDockID: id))
        }
        dockAccessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.renderCurrentPresence() }
        }

        notificationService?.onAuthorizationChange = { [weak self] status in
            self?.settingsWindowController.viewModel.updateNotificationPermission(status)
        }
        settingsWindowController.viewModel.onRequestNotificationPermission = { [weak self] in
            Task { await self?.notificationService?.requestAuthorization() }
        }
        settingsWindowController.viewModel.onOpenNotificationSettings = { [weak self] in
            self?.notificationService?.openNotificationSettings()
        }
        notificationService?.start()

        menuBarController = MenuBarController(
            onShowAll: { [weak self] in self?.showAll() },
            onHideAll: { [weak self] in self?.hideAll() },
            onOpenSettings: { [weak self] in self?.openSettings() },
            onQuit: { [weak self] in self?.quit() },
            onFocusWorkspace: { [weak self] in self?.focusWorkspace() },
            onAcknowledgeDone: { [weak self] id in self?.acknowledgeDone(botId: id) },
            onAcknowledgeAllDone: { [weak self] in self?.acknowledgeAllDone() },
            onOpenMotionExperience: { [weak self] in self?.openMotionExperience() }
        )
        petScene.configureCompletionActions(
            onAcknowledge: { [weak self] id in self?.acknowledgeDone(botId: id) },
            onAcknowledgeAll: { [weak self] in self?.acknowledgeAllDone() }
        )
        #if DEBUG
        if let fixture = gateway as? AcceptanceFixtureGatewayRuntime {
            menuBarController?.enableExperienceChecks(selectedFixtureID: fixture.profile.rawValue) { [weak self] id in
                self?.selectExperienceFixture(id)
            }
        }
        #endif

        screenObserver.onChange = { [weak self] geometry in self?.handleMainScreenChange(geometry) }
        screenObserver.start()

        lifecycleObserver.onWillSleep = { [weak self] in self?.handleWillSleep() }
        lifecycleObserver.onDidWake = { [weak self] in self?.handleDidWake() }
        lifecycleObserver.start()

        settingsWindowController.viewModel.onRetry = { [weak self] in self?.retryConnection() }
        settingsWindowController.viewModel.update(bots: [], connectionState: .connecting)

        gateway.start(callbacks: GatewayRuntimeCallbacks(
            didResolveInitialRoster: { [weak self] bots in self?.resolveInitialRoster(bots) },
            didFailInitialConnection: { [weak self] failure in self?.resolveInitialFailure(failure) },
            didUpdateRoster: { [weak self] bots in self?.updateRoster(bots) },
            didUpdateSnapshot: { [weak self] roster in self?.updateSnapshot(roster) },
            didUpdateConnection: { [weak self] state in self?.updateConnectionState(state) }
        ))
        scheduleInitialTimeout()
    }

    func showAll() {
        arePetsGloballyVisible = true
        guard !isSystemSleeping else { return }
        presenceByBot.removeAll()
        renderedGroupSignature = nil
        petScene.showAll()
        renderCurrentPresence()
    }

    func focusWorkspace() {
        showAll()
        petScene.focusPendingCompletions()
    }

    func selectExperienceFixture(_ id: String) {
        guard let fixture = gateway as? AcceptanceFixtureGatewayRuntime else { return }
        // Each explicit check starts a fresh isolated scenario. Live stores are never touched.
        presenceReducer = PresenceReducer()
        currentRoster = .empty
        doneNotificationTask?.cancel()
        doneNotificationTask = nil
        notificationQueue = NotificationEventQueue()
        let profile = AcceptanceFixtureGatewayRuntime.Profile(rawValue: id)!
        petScene.updateExperienceFixture(AcceptanceFixtureGatewayRuntime(profile: profile).fixture)
        fixture.select(id)
    }

    func hideAll() {
        arePetsGloballyVisible = false
        petScene.hideAll()
    }

    func acknowledgeDone(botId: BotID) {
        presenceReducer.acknowledgeDone(botId: botId)
        notificationQueue.discardDone(botId: botId)
        completionStore.save(presenceReducer.completionLedger)
        renderCurrentPresence()
    }

    func acknowledgeAllDone() {
        let visibleIDs = Set(settingsStore.configurations.filter(\.isVisible).map(\.botId))
        for botId in visibleIDs where presenceReducer.completionLedger.pending(for: botId) != nil {
            presenceReducer.acknowledgeDone(botId: botId)
            notificationQueue.discardDone(botId: botId)
        }
        completionStore.save(presenceReducer.completionLedger)
        renderCurrentPresence()
    }
    func openSettings() { settingsWindowController.open() }
    func showMenuForAcceptance() { menuBarController?.showForAcceptance() }
    func openMotionExperience() {
        #if DEBUG
        motionExperienceWindow.open()
        #endif
    }

    func retryConnection() {
        settingsWindowController.viewModel.update(
            bots: settingsWindowController.viewModel.bots,
            connectionState: .connecting
        )
        gateway.retry()
    }

    func resolveInitialRoster(_ identities: [BotIdentity]) {
        guard !didResolveInitialConnection else {
            updateRoster(identities)
            return
        }

        didResolveInitialConnection = true
        timeoutTask?.cancel()
        timeoutTask = nil
        currentIdentities = identities
        let bots = identities.map { SettingsBot(id: $0.id, name: $0.name) }
        let wasFirstLaunch = !settingsStore.hasPersistedConfiguration
        let merged = mergeSettings(botIDs: bots.map(\.id))
        let state: SettingsConnectionState = bots.isEmpty ? .noBots : .connected
        settingsWindowController.viewModel.update(bots: bots, connectionState: state)

        if wasFirstLaunch {
            settingsWindowController.open()
        }
        synchronizeScene(configurations: merged.configurations)
        if arePetsGloballyVisible, !isSystemSleeping {
            petScene.showAll()
        }
    }

    func resolveInitialFailure(_ failure: InitialConnectionFailure) {
        guard !didResolveInitialConnection else { return }
        didResolveInitialConnection = true
        timeoutTask?.cancel()
        timeoutTask = nil
        settingsWindowController.viewModel.update(bots: [], connectionState: failure.settingsState)

        if !settingsStore.hasPersistedConfiguration {
            settingsWindowController.open()
        }
    }

    func updateRoster(_ identities: [BotIdentity]) {
        currentIdentities = identities
        let bots = identities.map { SettingsBot(id: $0.id, name: $0.name) }
        let merged = mergeSettings(botIDs: bots.map(\.id))
        settingsWindowController.viewModel.update(
            bots: bots,
            connectionState: bots.isEmpty ? .noBots : .connected
        )
        synchronizeScene(configurations: merged.configurations)
    }

    func updateConnectionState(_ state: SettingsConnectionState) {
        gatewayAvailable = state == .connected
        settingsWindowController.viewModel.update(
            bots: settingsWindowController.viewModel.bots,
            connectionState: state
        )
        renderCurrentPresence()
    }

    func updateSnapshot(_ roster: RosterSnapshot) {
        let removedIDs = Set(currentRoster.bots.keys).subtracting(roster.bots.keys)
        for botId in removedIDs {
            presenceReducer.remove(botId: botId)
            presenceByBot.removeValue(forKey: botId)
        }
        for groupID in Set(currentRoster.groups.keys).subtracting(roster.groups.keys) {
            let id = Self.presenceID(forDockID: "group:" + groupID)
            presenceReducer.remove(botId: id)
            presenceByBot.removeValue(forKey: id)
        }
        currentRoster = roster
        settingsWindowController.viewModel.updateDockItems(
            roster.orderedBots.map { SettingsDockItem(id: "bot:" + $0.id, name: $0.name, isGroup: false) }
            + roster.groups.values.sorted { $0.id < $1.id }.map {
                SettingsDockItem(id: "group:" + $0.id, name: $0.name, isGroup: true)
            }
        )
        if didResolveInitialConnection {
            updateRoster(roster.orderedBots.map(\.identity))
        }
    }

    func injectLifecycleWillSleep() { handleWillSleep() }
    func injectLifecycleDidWake() { handleDidWake() }
    func injectMainScreen(_ geometry: MainScreenGeometry) { handleMainScreenChange(geometry) }

    func quit() {
        shutdown()
        NSApp.terminate(nil)
    }

    func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        timeoutTask?.cancel()
        timeoutTask = nil
        doneNotificationTask?.cancel()
        doneNotificationTask = nil
        screenObserver.stop()
        lifecycleObserver.stop()
        settingsWindowController.viewModel.onRetry = nil
        settingsWindowController.viewModel.onRequestNotificationPermission = nil
        settingsWindowController.viewModel.onOpenNotificationSettings = nil
        notificationService?.stop()
        settingsCancellable?.cancel()
        settingsCancellable = nil
        dockSettingsCancellable?.cancel()
        dockSettingsCancellable = nil
        if let dockAccessibilityObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(dockAccessibilityObserver)
        }
        dockAccessibilityObserver = nil
        dockService?.onDisableItem = nil
        (dockService as? DockController)?.onError = nil
        dockService?.onAcknowledgeItem = nil
        dockService?.shutdown()
        completionStore.save(presenceReducer.completionLedger)
        presenceReducer.resetRuntime()
        groupActivityTracker.reset()
        presenceByBot.removeAll()
        synchronizedSceneSignature = nil
        renderedGroupSignature = nil
        settingsWindowController.shutdown()
        #if DEBUG
        motionExperienceWindow.shutdown()
        #endif
        gateway.shutdown()
        petScene.shutdown()
        menuBarController?.shutdown()
        menuBarController = nil
    }

    private func scheduleInitialTimeout() {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self, initialConnectionTimeout] in
            try? await Task.sleep(for: initialConnectionTimeout)
            guard !Task.isCancelled else { return }
            self?.resolveInitialFailure(.timedOut)
        }
    }

    private func mergeSettings(botIDs: [BotID]) -> SettingsStore.MergeResult {
        isMergingRoster = true
        defer { isMergingRoster = false }
        return settingsStore.merge(botIDs: botIDs)
    }

    private func handleWillSleep() {
        guard !isSystemSleeping else { return }
        isSystemSleeping = true
        dockService?.suspend()
        petScene.hideAll()
        gateway.suspend()
    }

    private func handleDidWake() {
        guard isSystemSleeping else { return }
        isSystemSleeping = false
        gateway.resume()
        if let geometry = screenObserver.current ?? deferredMainScreenGeometry {
            petScene.updateMainScreen(frame: geometry.frame, visibleFrame: geometry.visibleFrame, safeAreaInsets: geometry.safeAreaInsets)
        }
        deferredMainScreenGeometry = nil
        synchronizeScene()
        dockService?.resume()
        if arePetsGloballyVisible {
            petScene.showAll()
        }
    }

    private func handleMainScreenChange(_ geometry: MainScreenGeometry) {
        guard !isSystemSleeping else {
            deferredMainScreenGeometry = geometry
            return
        }
        petScene.updateMainScreen(frame: geometry.frame, visibleFrame: geometry.visibleFrame, safeAreaInsets: geometry.safeAreaInsets)
    }

    private func synchronizeScene(configurations suppliedConfigurations: [PetConfiguration]? = nil) {
        guard !isSystemSleeping else { return }
        let identityByID = Dictionary(uniqueKeysWithValues: currentIdentities.map { ($0.id, $0) })
        let configurations = (suppliedConfigurations ?? settingsStore.configurations)
            .filter(\.isVisible)
            .sorted {
                if $0.globalOrder != $1.globalOrder {
                    return $0.globalOrder < $1.globalOrder
                }
                return $0.botId < $1.botId
            }
        let identities = configurations.compactMap { identityByID[$0.botId] }
        let signature = SceneSynchronizationSignature(
            identities: identities,
            configurations: configurations
        )
        if synchronizedSceneSignature != signature {
            let previousIDs = Set(synchronizedSceneSignature?.identities.map(\.id) ?? [])
            for identity in identities where !previousIDs.contains(identity.id) {
                presenceByBot.removeValue(forKey: identity.id)
            }
            petScene.synchronize(identities: identities, configurations: configurations)
            synchronizedSceneSignature = signature
            // A workstation/configuration change can move an otherwise unchanged
            // shared station, so only the group render is invalidated here.
            renderedGroupSignature = nil
        }
        renderCurrentPresence(visibleIDs: Set(configurations.map(\.botId)), configurations: configurations)
    }

    private func renderCurrentPresence(visibleIDs suppliedVisibleIDs: Set<BotID>? = nil, configurations suppliedConfigurations: [PetConfiguration]? = nil, dockEnabledIDs suppliedDockIDs: Set<String>? = nil) {
        guard !isShutdown, !isSystemSleeping else { return }
        let configurations = suppliedConfigurations ?? settingsStore.configurations
        let visibleIDs = suppliedVisibleIDs
            ?? Set(configurations.filter(\.isVisible).map(\.botId))
        let dockIDs = suppliedDockIDs ?? settingsStore.dockEnabledIDs
        let dockBotIDs = Set(currentRoster.bots.keys.filter { dockIDs.contains("bot:" + $0) })
        let observedBotIDs = visibleIDs.union(dockBotIDs)
        let dockGroups = currentRoster.groups.values.filter { dockIDs.contains("group:" + $0.id) }
        let observedIDs = observedBotIDs.union(dockGroups.map { Self.presenceID(forDockID: "group:" + $0.id) })
        let noLongerVisible = Set(presenceByBot.keys).subtracting(observedIDs)
        for botId in noLongerVisible {
            presenceByBot.removeValue(forKey: botId)
        }
        var currentStates: [BotID: PresenceState] = [:]

        for botId in observedBotIDs.sorted() {
            guard let bot = currentRoster.bots[botId] else { continue }
            let state = presenceReducer.reduce(
                botId: botId,
                runtime: bot.runtime,
                gatewayAvailable: gatewayAvailable
            )
            if state.isActive { notificationQueue.discardDone(botId: botId) }
            if visibleIDs.contains(botId) {
                consumeNotificationTransition(botId: botId, botName: bot.identity.name)
            }
            currentStates[botId] = state
            if presenceByBot[botId] != state {
                if arePetsGloballyVisible, visibleIDs.contains(botId) {
                    petScene.updatePresence(state, botId: botId, revision: nextSceneRevision())
                }
                completionStore.save(presenceReducer.completionLedger)
            }
        }
        for group in dockGroups {
            let id = Self.presenceID(forDockID: "group:" + group.id)
            currentStates[id] = presenceReducer.reduce(botId: id, runtime: group.runtime, gatewayAvailable: gatewayAvailable)
        }
        if currentStates != presenceByBot { completionStore.save(presenceReducer.completionLedger) }
        presenceByBot = currentStates
        let desktopStates = currentStates.filter { visibleIDs.contains($0.key) }
        let pendingIDs = Set(visibleIDs.filter { presenceReducer.completionLedger.pending(for: $0) != nil })
        currentAggregate = PresenceAggregate.make(states: desktopStates, gatewayAvailable: gatewayAvailable, pendingDoneBotIDs: pendingIDs)
        menuBarController?.update(aggregate: currentAggregate)
        menuBarController?.updatePendingDone(bots: configurations
            .sorted { $0.globalOrder < $1.globalOrder }
            .compactMap { configuration in
                guard pendingIDs.contains(configuration.botId), let bot = currentRoster.bots[configuration.botId] else { return nil }
                return SettingsBot(id: bot.id, name: bot.identity.name)
            })
        let groups: GroupActivitySnapshot
        if gatewayAvailable {
            groups = groupActivityTracker.update(roster: currentRoster, visibleBotIds: visibleIDs)
        } else {
            groupActivityTracker.reset()
            groups = .empty
        }
        let groupMemberPresence = Dictionary(uniqueKeysWithValues: groups.assignments.keys.compactMap {
            botId in currentStates[botId].map { (botId, $0) }
        })
        let groupSignature = GroupRenderSignature(
            snapshot: groups,
            memberPresence: groupMemberPresence
        )
        if arePetsGloballyVisible, renderedGroupSignature != groupSignature {
            petScene.updateGroupActivity(
                groups,
                presenceByBot: currentStates,
                revision: nextSceneRevision()
            )
            renderedGroupSignature = groupSignature
        }
        synchronizeDock(enabledIDs: dockIDs, states: currentStates)
    }

    private static func presenceID(forDockID id: String) -> BotID {
        if id.hasPrefix("bot:") { return String(id.dropFirst(4)) }
        return "grokoo.dock." + id
    }

    private func synchronizeDock(enabledIDs: Set<String>, states: [BotID: PresenceState]) {
        guard let dockService else { return }
        dockRevision &+= 1
        let isFixture = gateway is AcceptanceFixtureGatewayRuntime
        func route(_ id: String) -> URL {
            GrokBotNotificationRoute.url(for: isFixture ? .mainWindow : .bot(id))
        }
        var items = currentRoster.orderedBots.compactMap { bot -> DockItemSnapshot? in
            let id = "bot:" + bot.id
            guard enabledIDs.contains(id) else { return nil }
            return DockItemSnapshot(
                id: id, kind: .bot, displayName: bot.name, shape: bot.shape, color: bot.color,
                state: DockPresentationState(rawValue: (states[bot.id] ?? .offline).rawValue)!,
                revision: dockRevision, routeURL: route(bot.id), fallbackURL: GrokBotNotificationRoute.mainWindowURL
            )
        }
        for group in currentRoster.groups.values.sorted(by: { $0.id < $1.id }) {
            let id = "group:" + group.id
            guard enabledIDs.contains(id) else { continue }
            let members = group.memberIds.compactMap { memberID -> DockMemberAppearance? in
                guard let bot = currentRoster.bots[memberID] else { return nil }
                return DockMemberAppearance(id: memberID, shape: bot.shape, color: bot.color)
            }
            items.append(DockItemSnapshot(
                id: id, kind: .group, displayName: group.name,
                shape: members.first?.shape ?? .blob, color: members.first?.color ?? .blue,
                members: members,
                state: DockPresentationState(rawValue: (states[Self.presenceID(forDockID: id)] ?? .offline).rawValue)!,
                revision: dockRevision, routeURL: route(group.id), fallbackURL: GrokBotNotificationRoute.mainWindowURL
            ))
        }
        let reducesMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            || (gateway as? AcceptanceFixtureGatewayRuntime)?.fixture.reducedMotion == true
        dockService.synchronize(items: items, reducedMotion: reducesMotion)
    }

    private func nextSceneRevision() -> UInt64 {
        sceneRevision &+= 1
        return sceneRevision
    }

    private func consumeNotificationTransition(botId: BotID, botName: String) {
        guard let transition = presenceReducer.lastTransition, !transition.restored else { return }
        if let eventId = transition.newBlockedEventId,
           let event = notificationQueue.ingestBlocked(eventId: eventId, botId: botId, botName: botName, destination: gateway is AcceptanceFixtureGatewayRuntime ? .mainWindow : nil) {
            notificationHandler(event)
        }
        if let eventId = transition.newDoneEventId {
            notificationQueue.ingestDone(eventId: eventId, botId: botId, botName: botName, destination: gateway is AcceptanceFixtureGatewayRuntime ? .mainWindow : nil)
            scheduleDoneNotificationFlush()
        }
        notificationReceiptStore.save(notificationQueue.allReceipts)
    }

    private func scheduleDoneNotificationFlush() {
        guard doneNotificationTask == nil, let deadline = notificationQueue.nextDoneDeadline else { return }
        doneNotificationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self else { return }
            if let event = self.notificationQueue.flushDone() { self.notificationHandler(event) }
            self.notificationReceiptStore.save(self.notificationQueue.allReceipts)
            self.doneNotificationTask = nil
            self.scheduleDoneNotificationFlush()
        }
    }

}
