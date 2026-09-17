import Foundation

struct PresenceTransition: Equatable, Sendable {
    let previous: PresenceState
    let current: PresenceState
    let newDoneEventId: String?
    let newBlockedEventId: String?
    let restored: Bool
}

struct PresenceReducer: Sendable {
    private struct WorkSession: Sendable {
        let baselineRevision: String?
        var observedRevision: String?
        var endedAt: ContinuousClock.Instant?
    }

    private struct BotState: Sendable {
        var runtime = BotRuntime()
        var state: PresenceState = .idle
        var session: WorkSession?
        var lastBlockedEventId: String?
    }

    let lateRevisionWindow: Duration
    private(set) var completionLedger: CompletionLedger
    private var bots: [BotID: BotState] = [:]
    private(set) var lastTransition: PresenceTransition?

    init(completionLedger: CompletionLedger = CompletionLedger(), lateRevisionWindow: Duration = .seconds(5)) {
        self.completionLedger = completionLedger
        self.lateRevisionWindow = max(.zero, lateRevisionWindow)
    }

    mutating func reduce(
        botId: BotID,
        runtime: BotRuntime,
        gatewayAvailable: Bool,
        now: ContinuousClock.Instant = .now,
        wallClock: Date = Date(),
        isReplay: Bool = false
    ) -> PresenceState {
        let hadPreviousSnapshot = bots[botId] != nil
        var bot = bots[botId] ?? BotState()
        let previous = bot.state
        var newDone: String?
        var newBlocked: String?

        let wasActive = bot.runtime.hasActiveTask
        let isActive = runtime.hasActiveTask
        let taskChanged = runtime.taskRevision != nil && runtime.taskRevision != bot.runtime.taskRevision
        if isActive && (!wasActive || taskChanged) {
            completionLedger.supersede(botId: botId, at: wallClock)
            bot.session = WorkSession(baselineRevision: hadPreviousSnapshot ? bot.runtime.messageRevision : runtime.messageRevision, observedRevision: nil, endedAt: nil)
        }
        if isActive, let revision = runtime.messageRevision,
           revision != bot.session?.baselineRevision {
            bot.session?.observedRevision = revision
        }
        if wasActive && !isActive { bot.session?.endedAt = now }
        if !isActive, runtime.messageRevision != bot.runtime.messageRevision,
           let revision = runtime.messageRevision,
           let endedAt = bot.session?.endedAt,
           endedAt.duration(to: now) <= lateRevisionWindow,
           revision != bot.session?.baselineRevision {
            bot.session?.observedRevision = revision
        }

        bot.runtime = runtime
        if let fixture = runtime.fixtureState {
            if fixture == .done {
                let id = runtime.messageRevision ?? "fixture-done:\(botId)"
                if completionLedger.register(botId: botId, eventId: id, at: wallClock), !isReplay { newDone = id }
                bot.state = completionLedger.pending(for: botId) == nil ? .idle : .done
            } else {
                bot.state = fixture
                if fixture == .blocked, let blocked = runtime.blockedEvent, bot.lastBlockedEventId != blocked.id {
                    bot.lastBlockedEventId = blocked.id
                    if !isReplay { newBlocked = blocked.id }
                }
            }
        } else if !gatewayAvailable {
            bot.state = .offline
        } else if let blocked = runtime.blockedEvent {
            bot.state = .blocked
            if bot.lastBlockedEventId != blocked.id {
                bot.lastBlockedEventId = blocked.id
                if !isReplay { newBlocked = blocked.id }
            }
        } else if runtime.waitingEvent != nil || runtime.awaitingUserResponse != nil {
            bot.state = .waiting
        } else if runtime.isThinking {
            bot.state = .thinking
        } else if runtime.isRunning {
            bot.state = .working
        } else if let session = bot.session, let revision = session.observedRevision {
            if completionLedger.register(botId: botId, eventId: revision, at: wallClock), !isReplay {
                newDone = revision
            }
            bot.session = nil
            bot.state = completionLedger.pending(for: botId) == nil ? .idle : .done
        } else if completionLedger.pending(for: botId) != nil {
            bot.state = .done
        } else {
            if let endedAt = bot.session?.endedAt, endedAt.duration(to: now) > lateRevisionWindow {
                bot.session = nil
            }
            bot.state = .idle
        }

        bots[botId] = bot
        lastTransition = PresenceTransition(
            previous: previous,
            current: bot.state,
            newDoneEventId: newDone,
            newBlockedEventId: newBlocked,
            restored: isReplay
        )
        return bot.state
    }

    mutating func acknowledgeDone(botId: BotID, at date: Date = Date()) {
        completionLedger.acknowledge(botId: botId, at: date)
        if bots[botId]?.state == .done { bots[botId]?.state = .idle }
    }

    mutating func remove(botId: BotID) { bots.removeValue(forKey: botId) }
    mutating func resetRuntime() { bots.removeAll(keepingCapacity: false) }
}
