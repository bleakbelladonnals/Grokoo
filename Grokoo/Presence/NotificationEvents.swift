import Foundation

enum NotificationDestination: Codable, Equatable, Sendable {
    case bot(BotID)
    case task(String)
    case mainWindow
}

struct SafeNotificationPayload: Codable, Equatable, Sendable {
    let title: String
    let body: String
    let destination: NotificationDestination
}

enum PresenceNotification: Equatable, Sendable {
    case blocked(eventId: String, payload: SafeNotificationPayload)
    case done(eventIds: [String], payload: SafeNotificationPayload)
}

struct NotificationReceipt: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case blocked, done }
    let eventId: String
    let kind: Kind
    let sentAt: Date
    // Older receipts did not carry a Bot ID. Keep those as global tombstones,
    // while all new receipts distinguish identical revisions on different Bots.
    var botId: BotID? = nil
}

final class NotificationReceiptStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard, key: String = "grokling.notification-receipts.v1") {
        self.defaults = defaults
        self.key = key
    }

    func load() -> [NotificationReceipt] {
        lock.withLock {
            guard let data = defaults.data(forKey: key) else { return [] }
            return (try? JSONDecoder().decode([NotificationReceipt].self, from: data)) ?? []
        }
    }

    func save(_ receipts: [NotificationReceipt]) {
        lock.withLock {
            guard let data = try? JSONEncoder().encode(receipts) else { return }
            defaults.set(data, forKey: key)
        }
    }
}

struct NotificationEventQueue: Sendable {
    private struct PendingDone: Sendable {
        let eventId: String
        let botId: BotID
        let botName: String
        let destination: NotificationDestination
    }

    let doneWindow: TimeInterval
    private var receipts: [NotificationReceipt]
    private var pendingDone: [PendingDone] = []
    private var doneDeadline: Date?

    init(doneWindow: TimeInterval = 3, receipts: [NotificationReceipt] = []) {
        self.doneWindow = doneWindow
        self.receipts = receipts
    }

    mutating func ingestBlocked(
        eventId: String,
        botId: BotID,
        botName: String,
        destination: NotificationDestination? = nil,
        at date: Date = Date(),
        isReplay: Bool = false
    ) -> PresenceNotification? {
        guard !isReplay, !hasReceipt(eventId, kind: .blocked, botId: botId) else { return nil }
        receipts.append(NotificationReceipt(eventId: eventId, kind: .blocked, sentAt: date, botId: botId))
        return .blocked(
            eventId: eventId,
            payload: SafeNotificationPayload(
                title: "\(botName) 需要你",
                body: "打开 Grok Bot 查看并继续处理。",
                destination: destination ?? .bot(botId)
            )
        )
    }

    mutating func ingestDone(
        eventId: String,
        botId: BotID,
        botName: String,
        destination: NotificationDestination? = nil,
        at date: Date = Date(),
        isReplay: Bool = false
    ) {
        guard !isReplay, !hasReceipt(eventId, kind: .done, botId: botId),
              !pendingDone.contains(where: { $0.eventId == eventId && $0.botId == botId }) else { return }
        pendingDone.append(PendingDone(
            eventId: eventId,
            botId: botId,
            botName: botName,
            destination: destination ?? .bot(botId)
        ))
        if doneDeadline == nil { doneDeadline = date.addingTimeInterval(doneWindow) }
    }

    mutating func flushDone(at date: Date = Date()) -> PresenceNotification? {
        guard let deadline = doneDeadline, date >= deadline, !pendingDone.isEmpty else { return nil }
        let batch = pendingDone
        pendingDone.removeAll(keepingCapacity: true)
        doneDeadline = nil
        receipts.append(contentsOf: batch.map {
            NotificationReceipt(eventId: $0.eventId, kind: .done, sentAt: date, botId: $0.botId)
        })
        if batch.count == 1, let item = batch.first {
            return .done(
                eventIds: [item.eventId],
                payload: SafeNotificationPayload(
                    title: "\(item.botName) 已完成任务",
                    body: "点按返回 Grok Bot 查看结果。",
                    destination: item.destination
                )
            )
        }
        let names = batch.prefix(3).map(\.botName).joined(separator: "、")
        return .done(
            eventIds: batch.map(\.eventId),
            payload: SafeNotificationPayload(
                title: "\(batch.count) 个任务已完成",
                body: names.isEmpty ? "点按查看。" : "\(names)。点按查看。",
                destination: .mainWindow
            )
        )
    }

    var allReceipts: [NotificationReceipt] { receipts }
    var nextDoneDeadline: Date? { doneDeadline }

    /// Acknowledgement or a new task can make a completion obsolete before the
    /// three-second window closes. Consume it without sending a stale banner.
    mutating func discardDone(botId: BotID, at date: Date = Date()) {
        let discarded = pendingDone.filter { $0.botId == botId }
        receipts.append(contentsOf: discarded.map {
            NotificationReceipt(eventId: $0.eventId, kind: .done, sentAt: date, botId: $0.botId)
        })
        pendingDone.removeAll { $0.botId == botId }
        if pendingDone.isEmpty { doneDeadline = nil }
    }

    private func hasReceipt(_ id: String, kind: NotificationReceipt.Kind, botId: BotID) -> Bool {
        receipts.contains { $0.eventId == id && $0.kind == kind && ($0.botId == nil || $0.botId == botId) }
    }
}
