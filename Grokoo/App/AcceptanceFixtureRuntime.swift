import Foundation

struct ExperienceFixture: Codable, Equatable, Sendable {
    let id: String
    let visibleBotCount: Int
    let states: [PresenceState]
    let groups: [[Int]]
    let dockEdge: DockEdge
    let wallpaper: WorkspaceWallpaperKind
    let reducedTransparency: Bool
    let reducedMotion: Bool
}

enum ExperienceFixtureCatalog {
    static func loadBundled() -> [ExperienceFixture] {
        guard let url = Bundle.main.url(forResource: "experience-fixtures", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return builtIns }
        return (try? JSONDecoder().decode([ExperienceFixture].self, from: data)) ?? builtIns
    }

    static let builtIns: [ExperienceFixture] = [
        .init(id: "idle", visibleBotCount: 6, states: [.idle], groups: [], dockEdge: .bottom, wallpaper: .complex, reducedTransparency: false, reducedMotion: false),
        .init(id: "solo-6", visibleBotCount: 6, states: [.working], groups: [], dockEdge: .bottom, wallpaper: .complex, reducedTransparency: false, reducedMotion: false),
        .init(id: "group-6", visibleBotCount: 6, states: [.working], groups: [[0,1,2,3,4,5]], dockEdge: .bottom, wallpaper: .dark, reducedTransparency: false, reducedMotion: false),
        .init(id: "dual-2+4", visibleBotCount: 6, states: [.working], groups: [[0,1],[2,3,4,5]], dockEdge: .bottom, wallpaper: .light, reducedTransparency: false, reducedMotion: false),
        .init(id: "mixed-1+3", visibleBotCount: 4, states: [.working], groups: [[1,2,3]], dockEdge: .bottom, wallpaper: .complex, reducedTransparency: false, reducedMotion: false),
        .init(id: "seven-states", visibleBotCount: 6, states: [.working,.thinking,.waiting,.blocked,.done,.offline], groups: [], dockEdge: .bottom, wallpaper: .complex, reducedTransparency: false, reducedMotion: false),
    ]
}

@MainActor
final class AcceptanceFixtureGatewayRuntime: GatewayRuntimeServicing {
    struct Profile: RawRepresentable, Equatable, Sendable {
        let rawValue: String
        init?(rawValue: String) {
            guard !rawValue.isEmpty else { return nil }
            self.rawValue = rawValue
        }
        static let idle = Profile(rawValue: "idle")!
        static let active = Profile(rawValue: "solo-6")!
        static let working = Profile(rawValue: "solo-6")!
        static let group = Profile(rawValue: "group-4")!
        static let offline = Profile(rawValue: "state-offline")!
    }

    static let identities: [BotIdentity] = [
        BotIdentity(id: "fixture-1", name: "Sandy", shape: .blob, color: .blue),
        BotIdentity(id: "fixture-2", name: "Ada", shape: .pebble, color: .green),
        BotIdentity(id: "fixture-3", name: "Lin", shape: .squircle, color: .orange),
        BotIdentity(id: "fixture-4", name: "Mina", shape: .tablet, color: .magenta),
        BotIdentity(id: "fixture-5", name: "Nova", shape: .wedge, color: .yellow),
        BotIdentity(id: "fixture-6", name: "Kai", shape: .hex, color: .violet)
    ]

    private(set) var profile: Profile
    private var generation = 0
    private var callbacks: GatewayRuntimeCallbacks?

    init(profile: Profile) { self.profile = profile }
    func select(_ id: String) {
        guard let next = Profile(rawValue: id) else { return }
        profile = next
        generation += 1
        publish()
    }
    func start(callbacks: GatewayRuntimeCallbacks) { self.callbacks = callbacks; publish() }
    func retry() { publish() }
    func suspend() { callbacks?.didUpdateConnection(.offline) }
    func resume() { publish() }
    func shutdown() { callbacks = nil }

    var fixture: ExperienceFixture {
        let catalog = ExperienceFixtureCatalog.loadBundled()
        if let exact = catalog.first(where: { $0.id == profile.rawValue }) { return exact }
        return Self.derivedFixture(id: profile.rawValue)
    }

    private func publish() {
        guard let callbacks else { return }
        callbacks.didUpdateConnection(.connecting)
        callbacks.didUpdateSnapshot(Self.snapshot(fixture: fixture, generation: generation))
        callbacks.didResolveInitialRoster(Array(Self.identities.prefix(fixture.visibleBotCount)))
        callbacks.didUpdateConnection(fixture.states.first == .offline ? .offline : .connected)
    }

    static func snapshot(profile: Profile) -> RosterSnapshot { snapshot(fixture: derivedFixture(id: profile.rawValue)) }

    static func snapshot(fixture: ExperienceFixture, generation: Int = 0) -> RosterSnapshot {
        let identities = Array(Self.identities.prefix(min(6, fixture.visibleBotCount)))
        var bots: [BotID: BotPresence] = [:]
        for (index, identity) in identities.enumerated() {
            let state = fixture.states[index % max(1, fixture.states.count)]
            let runtime: BotRuntime
            switch state {
            case .idle, .offline, .done:
                runtime = BotRuntime(messageRevision: state == .done ? "done-\(generation)-\(index)" : nil, fixtureState: state)
            case .working:
                runtime = BotRuntime(isRunning: true, taskRevision: "task-\(generation)-\(index)", fixtureState: state)
            case .thinking:
                runtime = BotRuntime(isRunning: true, isComposing: true, taskRevision: "task-\(generation)-\(index)", fixtureState: state)
            case .waiting:
                runtime = BotRuntime(isRunning: true, awaitingUserResponse: .present, waitingEvent: StructuredEventRef("wait-\(generation)-\(index)"), taskRevision: "task-\(generation)-\(index)", fixtureState: state)
            case .blocked:
                runtime = BotRuntime(isRunning: true, blockedEvent: StructuredEventRef("blocked-\(generation)-\(index)"), taskRevision: "task-\(generation)-\(index)", fixtureState: state)
            }
            bots[identity.id] = BotPresence(identity: identity, runtime: runtime)
        }
        var groups: [GroupID: GroupRuntime] = [:]
        for (index, indices) in fixture.groups.enumerated() {
            let ids = indices.compactMap { identities.indices.contains($0) ? identities[$0].id : nil }
            groups["fixture-group-\(index)"] = GroupRuntime(id: "fixture-group-\(index)", memberIds: ids, isRunning: true)
        }
        return RosterSnapshot(bots: bots, groups: groups, botOrder: identities.map(\.id))
    }

    private static func derivedFixture(id: String) -> ExperienceFixture {
        if id.hasPrefix("solo-"), let count = Int(id.dropFirst(5)) {
            return .init(id: id, visibleBotCount: count, states: [.working], groups: [], dockEdge: .bottom, wallpaper: .complex, reducedTransparency: false, reducedMotion: false)
        }
        if id.hasPrefix("group-"), let count = Int(id.dropFirst(6)) {
            return .init(id: id, visibleBotCount: count, states: [.working], groups: [Array(0..<count)], dockEdge: .bottom, wallpaper: .complex, reducedTransparency: false, reducedMotion: false)
        }
        if id.hasPrefix("state-"), let state = PresenceState(rawValue: String(id.dropFirst(6))) {
            return .init(id: id, visibleBotCount: 1, states: [state], groups: [], dockEdge: .bottom, wallpaper: .complex, reducedTransparency: false, reducedMotion: state == .done)
        }
        return ExperienceFixtureCatalog.builtIns[0]
    }
}
