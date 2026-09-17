import Foundation

typealias BotID = String
typealias GroupID = String

enum AwaitingMarker: Equatable, Sendable { case present }

struct StructuredEventRef: Codable, Equatable, Hashable, Sendable {
    let id: String

    init?(_ value: String?) {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        id = value
    }
}

struct BotIdentity: Equatable, Sendable, Identifiable {
    let id: BotID
    var name: String
    var shape: OfficialShape
    var color: OfficialColor
}

/// Content-free projection of the structured Gateway fields used by state logic.
struct BotRuntime: Equatable, Sendable {
    var isRunning: Bool
    var isThinking: Bool
    var awaitingUserResponse: AwaitingMarker?
    var waitingEvent: StructuredEventRef?
    var blockedEvent: StructuredEventRef?
    var messageRevision: String?
    var taskRevision: String?
    var fixtureState: PresenceState?

    init(
        isRunning: Bool = false,
        isComposing: Bool = false,
        awaitingUserResponse: AwaitingMarker? = nil,
        messageRevision: String? = nil,
        waitingEvent: StructuredEventRef? = nil,
        blockedEvent: StructuredEventRef? = nil,
        taskRevision: String? = nil,
        fixtureState: PresenceState? = nil
    ) {
        self.isRunning = isRunning
        isThinking = isComposing
        self.awaitingUserResponse = awaitingUserResponse
        self.messageRevision = messageRevision
        self.waitingEvent = waitingEvent
        self.blockedEvent = blockedEvent
        self.taskRevision = taskRevision
        self.fixtureState = fixtureState
    }

    var isComposing: Bool {
        get { isThinking }
        set { isThinking = newValue }
    }

    var hasActiveTask: Bool { isRunning || isThinking || awaitingUserResponse != nil || blockedEvent != nil }
}

struct GroupRuntime: Equatable, Sendable, Identifiable {
    let id: GroupID
    var memberIds: [BotID]
    var isRunning: Bool
}

enum PresenceState: String, Codable, CaseIterable, Equatable, Sendable {
    case idle
    case working
    case thinking
    case waiting
    case blocked
    case done
    case offline

    var priority: Int {
        switch self {
        case .idle: 0
        case .done: 1
        case .working: 2
        case .thinking: 3
        case .waiting: 4
        case .blocked: 5
        case .offline: 6
        }
    }

    var isActive: Bool { [.working, .thinking, .waiting, .blocked].contains(self) }
    var needsAttention: Bool { [.waiting, .blocked, .done].contains(self) }
}

struct BotPresence: Equatable, Sendable, Identifiable {
    var identity: BotIdentity
    var runtime: BotRuntime
    var id: BotID { identity.id }
}

struct RosterSnapshot: Equatable, Sendable {
    var bots: [BotID: BotPresence]
    var groups: [GroupID: GroupRuntime]
    var botOrder: [BotID]

    init(bots: [BotID: BotPresence], groups: [GroupID: GroupRuntime], botOrder: [BotID]? = nil) {
        self.bots = bots
        self.groups = groups
        var seen = Set<BotID>()
        let preferred = (botOrder ?? []).filter { bots[$0] != nil && seen.insert($0).inserted }
        self.botOrder = preferred + bots.keys.filter { !seen.contains($0) }.sorted()
    }

    static let empty = RosterSnapshot(bots: [:], groups: [:], botOrder: [])
    var orderedBots: [BotPresence] { botOrder.compactMap { bots[$0] } }
}

struct PresenceAggregate: Equatable, Sendable {
    let activeBotCount: Int?
    let attentionPresent: Bool
    let waitingCount: Int
    let blockedCount: Int
    let pendingDoneCount: Int

    static func make(states: [BotID: PresenceState], gatewayAvailable: Bool, pendingDoneBotIDs: Set<BotID>? = nil) -> PresenceAggregate {
        let values = Array(states.values)
        let done = pendingDoneBotIDs?.count ?? values.count { $0 == .done }
        guard gatewayAvailable else {
            return PresenceAggregate(
                activeBotCount: nil,
                attentionPresent: done > 0,
                waitingCount: 0,
                blockedCount: 0,
                pendingDoneCount: done
            )
        }
        let waiting = values.count { $0 == .waiting }
        let blocked = values.count { $0 == .blocked }
        return PresenceAggregate(
            activeBotCount: values.count(where: \PresenceState.isActive),
            attentionPresent: waiting + blocked + done > 0,
            waitingCount: waiting,
            blockedCount: blocked,
            pendingDoneCount: done
        )
    }
}
