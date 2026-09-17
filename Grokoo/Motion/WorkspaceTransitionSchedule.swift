import Foundation

/// Reserves stable starts so repeated layout updates do not restart a waiting batch.
struct WorkspaceTransitionSchedule {
    static let enteringDuration: TimeInterval = 0.68
    static let leavingDuration: TimeInterval = 0.58
    static let batchInterval: TimeInterval = 0.18
    static let batchSize = 2
    private(set) var reservations: [BotID: TimeInterval] = [:]

    mutating func reserve(botID: BotID, now: TimeInterval) -> TimeInterval {
        if let existing = reservations[botID] { return existing }
        var start = now
        if let latest = reservations.values.max(), latest >= now - Self.batchInterval {
            let count = reservations.values.filter { abs($0 - latest) < 0.001 }.count
            start = count < Self.batchSize ? latest : latest + Self.batchInterval
        }
        reservations[botID] = start
        return start
    }

    mutating func release(botID: BotID) { reservations.removeValue(forKey: botID) }
    mutating func removeAll() { reservations.removeAll() }
}
