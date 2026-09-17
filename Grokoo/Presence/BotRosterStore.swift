import Foundation

actor BotRosterStore {
    private var snapshot: RosterSnapshot = .empty

    func current() -> RosterSnapshot { snapshot }

    @discardableResult
    func replace(with records: [GatewayAgentRecord]) -> RosterSnapshot {
        snapshot = Self.normalize(records)
        return snapshot
    }

    @discardableResult
    func apply(_ event: GatewayEvent) -> RosterSnapshot {
        switch event {
        case .agentUpserted(let record):
            let isKnownGroup = snapshot.groups[record.id] != nil && snapshot.bots[record.id] == nil
            if record.isGroup || isKnownGroup {
                let existing = snapshot.groups[record.id]
                let suppliedMembers = record.memberIds.isEmpty ? existing?.memberIds ?? [] : record.memberIds
                let validMembers = Self.normalizedMembers(suppliedMembers, bots: snapshot.bots)
                let runtimeFields = record.providedRuntimeFields
                let suppliedCompleteRuntime = runtimeFields.contains(.isRunning)
                    && runtimeFields.contains(.isComposingMessage)
                let suppliedActiveRuntime = (runtimeFields.contains(.isRunning) && record.isRunning)
                    || (runtimeFields.contains(.isComposingMessage) && record.isComposingMessage)
                let groupIsRunning = suppliedActiveRuntime
                    || (!suppliedCompleteRuntime && existing?.isRunning == true)
                snapshot.groups[record.id] = GroupRuntime(
                    id: record.id,
                    memberIds: validMembers,
                    isRunning: groupIsRunning
                )
                snapshot.bots.removeValue(forKey: record.id)
                snapshot.botOrder.removeAll { $0 == record.id }
            } else {
                let previous = snapshot.bots[record.id]
                let identity = BotIdentity(
                    id: record.id,
                    name: record.name == record.id ? previous?.identity.name ?? record.name : record.name,
                    shape: record.avatarShape == nil ? previous?.identity.shape ?? .blob : OfficialShape(gatewayValue: record.avatarShape),
                    color: record.avatarColor == nil ? previous?.identity.color ?? .black : OfficialColor(gatewayValue: record.avatarColor)
                )
                var runtime = GatewayPresenceAdapter.runtime(from: record)
                if !record.providedRuntimeFields.contains(.isRunning) { runtime.isRunning = previous?.runtime.isRunning ?? false }
                if !record.providedRuntimeFields.contains(.isComposingMessage) { runtime.isThinking = previous?.runtime.isThinking ?? false }
                if !record.providedRuntimeFields.contains(.awaitingUserResponse) {
                    runtime.awaitingUserResponse = previous?.runtime.awaitingUserResponse
                    runtime.waitingEvent = previous?.runtime.waitingEvent
                }
                runtime.messageRevision = record.messageRevision ?? previous?.runtime.messageRevision
                snapshot.bots[record.id] = BotPresence(identity: identity, runtime: runtime)
                if previous == nil { snapshot.botOrder.append(record.id) }
                snapshot.groups.removeValue(forKey: record.id)
            }
            pruneMissingGroupMembers()
        case .messageMetadata(let botId, let revision):
            snapshot.bots[botId]?.runtime.messageRevision = revision
        case .agentRemoved(let id):
            snapshot.bots.removeValue(forKey: id)
            snapshot.botOrder.removeAll { $0 == id }
            snapshot.groups.removeValue(forKey: id)
            pruneMissingGroupMembers()
        case .connected:
            break
        }
        return snapshot
    }

    static func normalize(_ records: [GatewayAgentRecord]) -> RosterSnapshot {
        var bots: [BotID: BotPresence] = [:]
        var botOrder: [BotID] = []
        for record in records where !record.isGroup {
            let identity = BotIdentity(
                id: record.id,
                name: record.name,
                shape: OfficialShape(gatewayValue: record.avatarShape),
                color: OfficialColor(gatewayValue: record.avatarColor)
            )
            let runtime = GatewayPresenceAdapter.runtime(from: record)
            if bots[record.id] == nil { botOrder.append(record.id) }
            bots[record.id] = BotPresence(identity: identity, runtime: runtime)
        }

        var groups: [GroupID: GroupRuntime] = [:]
        for record in records where record.isGroup {
            groups[record.id] = GroupRuntime(
                id: record.id,
                memberIds: normalizedMembers(record.memberIds, bots: bots),
                isRunning: record.isRunning || record.isComposingMessage
            )
        }
        return RosterSnapshot(bots: bots, groups: groups, botOrder: botOrder)
    }

    private func pruneMissingGroupMembers() {
        // Copy both collections before mutating the snapshot. Reading through
        // `snapshot` while a dictionary value is being modified violates
        // Swift's exclusive-access rule and can trap at runtime.
        let bots = snapshot.bots
        let groupIds = Array(snapshot.groups.keys)
        for id in groupIds {
            guard var group = snapshot.groups[id] else { continue }
            group.memberIds = Self.normalizedMembers(group.memberIds, bots: bots)
            snapshot.groups[id] = group
        }
    }

    private static func normalizedMembers(_ ids: [BotID], bots: [BotID: BotPresence]) -> [BotID] {
        var seen = Set<BotID>()
        return ids.filter { bots[$0] != nil && seen.insert($0).inserted }
    }
}

extension BotPresence {
    var name: String { identity.name }
    var shape: OfficialShape { identity.shape }
    var color: OfficialColor { identity.color }
}
