import CoreGraphics
import Foundation

struct MainScreenGeometry: Equatable, Sendable {
    let frame: CGRect
    let visibleFrame: CGRect
    let safeAreaInsets: EdgeInsets

    init(frame: CGRect, visibleFrame: CGRect, safeAreaInsets: EdgeInsets = .zero) {
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.safeAreaInsets = safeAreaInsets
    }
}

@MainActor
protocol PetSceneServicing: AnyObject {
    func synchronize(identities: [BotIdentity])
    func synchronize(identities: [BotIdentity], configurations: [PetConfiguration])
    func updatePresence(_ state: PresenceState, botId: BotID, revision: UInt64)
    func updateGroupActivity(
        _ snapshot: GroupActivitySnapshot,
        presenceByBot: [BotID: PresenceState],
        revision: UInt64
    )
    func showAll()
    func hideAll()
    func configureCompletionActions(onAcknowledge: @escaping (BotID) -> Void, onAcknowledgeAll: @escaping () -> Void)
    func focusPendingCompletions()
    func updateExperienceFixture(_ fixture: ExperienceFixture)
    func updateMainScreen(frame: CGRect, visibleFrame: CGRect)
    func updateMainScreen(frame: CGRect, visibleFrame: CGRect, safeAreaInsets: EdgeInsets)
    func shutdown()
}

extension PetSceneServicing {
    func configureCompletionActions(onAcknowledge: @escaping (BotID) -> Void, onAcknowledgeAll: @escaping () -> Void) {}
    func focusPendingCompletions() {}
    func updateExperienceFixture(_ fixture: ExperienceFixture) {}
    func synchronize(identities: [BotIdentity], configurations: [PetConfiguration]) {
        synchronize(identities: identities)
    }

    func updatePresence(_ state: PresenceState, botId: BotID, revision: UInt64) {}

    func updateGroupActivity(
        _ snapshot: GroupActivitySnapshot,
        presenceByBot: [BotID: PresenceState],
        revision: UInt64
    ) {}

    func updateMainScreen(frame: CGRect, visibleFrame: CGRect, safeAreaInsets: EdgeInsets) {
        updateMainScreen(frame: frame, visibleFrame: visibleFrame)
    }
}

@MainActor
struct GatewayRuntimeCallbacks {
    let didResolveInitialRoster: ([BotIdentity]) -> Void
    let didFailInitialConnection: (InitialConnectionFailure) -> Void
    let didUpdateRoster: ([BotIdentity]) -> Void
    let didUpdateSnapshot: (RosterSnapshot) -> Void
    let didUpdateConnection: (SettingsConnectionState) -> Void
}

@MainActor
protocol GatewayRuntimeServicing: AnyObject {
    func start(callbacks: GatewayRuntimeCallbacks)
    func retry()
    func suspend()
    func resume()
    func shutdown()
}

@MainActor
protocol SystemLifecycleObserving: AnyObject {
    var onWillSleep: (() -> Void)? { get set }
    var onDidWake: (() -> Void)? { get set }
    func start()
    func stop()
}

@MainActor
protocol MainScreenObserving: AnyObject {
    var onChange: ((MainScreenGeometry) -> Void)? { get set }
    var current: MainScreenGeometry? { get }
    func start()
    func stop()
}
