import Foundation

@MainActor
final class LiveGatewayRuntime: GatewayRuntimeServicing {
    private let coordinator: GatewayCoordinator
    private var callbacks: GatewayRuntimeCallbacks?
    private var updateTask: Task<Void, Never>?
    private var latestRoster: RosterSnapshot = .empty
    private var hasResolvedInitialConnection = false

    init(coordinator: GatewayCoordinator = GatewayCoordinator()) {
        self.coordinator = coordinator
    }

    func start(callbacks: GatewayRuntimeCallbacks) {
        guard updateTask == nil else { return }
        self.callbacks = callbacks
        updateTask = Task { [weak self, coordinator] in
            let updates = await coordinator.updates()
            await coordinator.start()
            for await update in updates {
                guard !Task.isCancelled else { return }
                self?.consume(update)
            }
        }
    }

    func retry() {
        Task { [coordinator] in await coordinator.refresh() }
    }

    func suspend() {
        Task { [coordinator] in await coordinator.suspend() }
    }

    func resume() {
        Task { [coordinator] in await coordinator.resume() }
    }

    func shutdown() {
        updateTask?.cancel()
        updateTask = nil
        callbacks = nil
        Task { [coordinator] in await coordinator.stop() }
    }

    private func consume(_ update: GatewayUpdate) {
        switch update {
        case .roster(let roster):
            latestRoster = roster
            callbacks?.didUpdateSnapshot(roster)
            let identities = roster.orderedBots.map(\.identity)
            if !hasResolvedInitialConnection, !identities.isEmpty {
                hasResolvedInitialConnection = true
                callbacks?.didResolveInitialRoster(identities)
            }

        case .connection(let state):
            consumeConnection(state)

        case .event:
            // GatewayCoordinator publishes the atomically updated roster
            // immediately after each event; rendering consumes that snapshot.
            break
        }
    }

    private func consumeConnection(_ state: GatewayConnectionState) {
        switch state {
        case .idle:
            break
        case .connecting:
            callbacks?.didUpdateConnection(.connecting)
        case .connected:
            callbacks?.didUpdateConnection(.connected)
            guard !hasResolvedInitialConnection else { return }
            let identities = latestRoster.orderedBots.map(\.identity)
            if !identities.isEmpty {
                hasResolvedInitialConnection = true
                callbacks?.didResolveInitialRoster(identities)
            }
        case .offline(let reason):
            let state: SettingsConnectionState
            switch reason {
            case .noBots: state = .noBots
            case .keychainDenied: state = .keychainDenied
            case .timeout: state = .timedOut
            case .descriptorMissing, .unauthorized, .network, .invalidData, .suspended: state = .offline
            }
            callbacks?.didUpdateConnection(state)
            guard !hasResolvedInitialConnection else { return }
            hasResolvedInitialConnection = true
            switch reason {
            case .noBots:
                callbacks?.didResolveInitialRoster([])
            case .keychainDenied:
                callbacks?.didFailInitialConnection(.keychainDenied)
            case .timeout:
                callbacks?.didFailInitialConnection(.timedOut)
            case .descriptorMissing, .unauthorized, .network, .invalidData, .suspended:
                callbacks?.didFailInitialConnection(.offline)
            }
        }
    }
}

@MainActor
enum AppAssembly {
    static func makeDefault() -> AppCoordinator {
        let environment = ProcessInfo.processInfo.environment
        #if DEBUG
        let fixtureProfile = (environment["GROKOO_EXPERIENCE_FIXTURE"] ?? environment["GROKLING_EXPERIENCE_FIXTURE"] ?? environment["GROKLING_ACCEPTANCE_FIXTURE"])
            .flatMap(AcceptanceFixtureGatewayRuntime.Profile.init(rawValue:))
        #else
        let fixtureProfile: AcceptanceFixtureGatewayRuntime.Profile? = nil
        #endif
        let settingsStore: SettingsStore
        let runtimeDefaults: UserDefaults
        if let fixtureProfile {
            let suiteName = "local.grokling.acceptance.\(fixtureProfile.rawValue)"
            let defaults = UserDefaults(suiteName: suiteName) ?? .standard
            defaults.removePersistentDomain(forName: suiteName)
            runtimeDefaults = defaults
            settingsStore = SettingsStore(defaults: defaults)
            settingsStore.merge(botIDs: AcceptanceFixtureGatewayRuntime.identities.map(\.id))
            let mbti: [MBTIType?] = [.entp, .infp, .isfj, .istp, nil, .intj]
            for (index, identity) in AcceptanceFixtureGatewayRuntime.identities.enumerated() {
                settingsStore.setMBTI(mbti[index], for: identity.id)
                settingsStore.move(botId: identity.id, to: index)
            }
        } else {
            runtimeDefaults = .standard
            settingsStore = SettingsStore()
        }
        let settingsViewModel = SettingsViewModel(store: settingsStore)
        let settingsWindowController = SettingsWindowController(viewModel: settingsViewModel)
        let experienceFixture = fixtureProfile.map { AcceptanceFixtureGatewayRuntime(profile: $0).fixture }
        let petScene = PetSceneController(experienceFixture: experienceFixture)
        let gateway: GatewayRuntimeServicing = fixtureProfile
            .map(AcceptanceFixtureGatewayRuntime.init(profile:))
            ?? LiveGatewayRuntime()
        let lifecycle = SystemLifecycleObserver()
        let screenObserver = MainScreenObserver()
        let notifications = MacOSNotificationService()

        return AppCoordinator(
            settingsStore: settingsStore,
            settingsWindowController: settingsWindowController,
            petScene: petScene,
            gateway: gateway,
            lifecycleObserver: lifecycle,
            screenObserver: screenObserver,
            completionStore: CompletionLedgerStore(defaults: runtimeDefaults),
            notificationReceiptStore: NotificationReceiptStore(defaults: runtimeDefaults),
            notificationHandler: { event in Task { await notifications.deliver(event) } },
            notificationService: notifications,
            dockService: DockController()
        )
    }
}
