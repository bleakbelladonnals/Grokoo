import Foundation

struct ActiveGroupSession: Equatable, Sendable, Identifiable {
    let groupId: GroupID
    var memberIds: Set<BotID>
    var groupRunning: Bool
    var memberRunning: Set<BotID>

    var id: GroupID { groupId }
}

enum GroupMemberMode: Equatable, Sendable {
    case working
    case resting
}

struct GroupMemberAssignment: Equatable, Sendable {
    let botId: BotID
    let groupId: GroupID
    let mode: GroupMemberMode
}

struct GroupActivitySnapshot: Equatable, Sendable {
    var sessions: [GroupID: ActiveGroupSession]
    var assignments: [BotID: GroupMemberAssignment]

    static let empty = GroupActivitySnapshot(sessions: [:], assignments: [:])
}

/// Maintains the group/member stop barrier and computes all assignments in one
/// pass so overlapping groups never expose an intermediate duplicate pet.
struct GroupActivityTracker: Sendable {
    private struct TrackedSession: Sendable {
        var publicSession: ActiveGroupSession
        let startSequence: UInt64
    }

    private var tracked: [GroupID: TrackedSession] = [:]
    private var nextSequence: UInt64 = 0

    mutating func update(roster: RosterSnapshot, visibleBotIds: Set<BotID>) -> GroupActivitySnapshot {
        let visible = visibleBotIds.intersection(roster.bots.keys)

        // Update existing sessions first, preserving their original ordering.
        for groupId in Array(tracked.keys) {
            guard let group = roster.groups[groupId] else {
                guard let prior = tracked[groupId]?.publicSession else { continue }
                let members = prior.memberIds.intersection(visible)
                let runningMembers = Set(members.filter { roster.bots[$0]?.runtime.hasActiveTask == true })
                tracked[groupId]?.publicSession.memberIds = members
                tracked[groupId]?.publicSession.groupRunning = false
                tracked[groupId]?.publicSession.memberRunning = runningMembers
                if runningMembers.isEmpty {
                    tracked.removeValue(forKey: groupId)
                }
                continue
            }
            let members = Set(group.memberIds).intersection(visible)
            let runningMembers = Set(members.filter { roster.bots[$0]?.runtime.hasActiveTask == true })
            tracked[groupId]?.publicSession.memberIds = members
            tracked[groupId]?.publicSession.groupRunning = group.isRunning
            tracked[groupId]?.publicSession.memberRunning = runningMembers
            if !group.isRunning && runningMembers.isEmpty {
                tracked.removeValue(forKey: groupId)
            }
        }

        // A group only acquires a shared station if it is running and has at
        // least one currently visible ordinary member.
        let enteringGroups = roster.groups.values
            .filter { $0.isRunning && tracked[$0.id] == nil }
            .sorted { $0.id < $1.id }
        for group in enteringGroups {
            let members = Set(group.memberIds).intersection(visible)
            guard !members.isEmpty else { continue }
            nextSequence &+= 1
            let runningMembers = Set(members.filter { roster.bots[$0]?.runtime.hasActiveTask == true })
            tracked[group.id] = TrackedSession(
                publicSession: ActiveGroupSession(
                    groupId: group.id,
                    memberIds: members,
                    groupRunning: true,
                    memberRunning: runningMembers
                ),
                startSequence: nextSequence
            )
        }

        let ordered = tracked.values.sorted {
            if $0.startSequence == $1.startSequence {
                return $0.publicSession.groupId < $1.publicSession.groupId
            }
            return $0.startSequence < $1.startSequence
        }
        var assignments: [BotID: GroupMemberAssignment] = [:]
        for trackedSession in ordered {
            let session = trackedSession.publicSession
            for botId in session.memberIds.sorted() where assignments[botId] == nil {
                assignments[botId] = GroupMemberAssignment(
                    botId: botId,
                    groupId: session.groupId,
                    mode: session.memberRunning.contains(botId) ? .working : .resting
                )
            }
        }
        return GroupActivitySnapshot(
            sessions: tracked.mapValues(\.publicSession),
            assignments: assignments
        )
    }

    mutating func reset() {
        tracked.removeAll(keepingCapacity: false)
        nextSequence = 0
    }
}
