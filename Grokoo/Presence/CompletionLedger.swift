import Foundation

enum CompletionRecordStatus: String, Codable, Equatable, Sendable {
    case pending
    case acknowledged
    case superseded
}

struct CompletionRecord: Codable, Equatable, Identifiable, Sendable {
    enum EventType: String, Codable, Sendable { case done }
    let botId: BotID
    let eventId: String
    let eventType: EventType
    let createdAt: Date
    var resolvedAt: Date?
    var status: CompletionRecordStatus

    var id: String { "\(botId):\(eventId)" }
}

struct CompletionLedger: Codable, Equatable, Sendable {
    private(set) var records: [CompletionRecord]

    init(records: [CompletionRecord] = []) {
        var seen = Set<String>()
        self.records = records.filter { seen.insert($0.id).inserted }
    }

    func pending(for botId: BotID) -> CompletionRecord? {
        records.last { $0.botId == botId && $0.status == .pending }
    }

    func contains(botId: BotID, eventId: String) -> Bool {
        records.contains { $0.botId == botId && $0.eventId == eventId }
    }

    @discardableResult
    mutating func register(botId: BotID, eventId: String, at date: Date = Date()) -> Bool {
        guard !contains(botId: botId, eventId: eventId) else { return false }
        supersede(botId: botId, at: date)
        records.append(CompletionRecord(botId: botId, eventId: eventId, eventType: .done, createdAt: date, resolvedAt: nil, status: .pending))
        return true
    }

    mutating func acknowledge(botId: BotID, at date: Date = Date()) {
        resolve(botId: botId, as: .acknowledged, at: date)
    }

    mutating func supersede(botId: BotID, at date: Date = Date()) {
        resolve(botId: botId, as: .superseded, at: date)
    }

    private mutating func resolve(botId: BotID, as status: CompletionRecordStatus, at date: Date) {
        for index in records.indices where records[index].botId == botId && records[index].status == .pending {
            records[index].status = status
            records[index].resolvedAt = date
        }
    }
}

struct CompletionLedgerDocument: Codable, Equatable, Sendable {
    static let schemaVersion = 1
    let version: Int
    let ledger: CompletionLedger
}

final class CompletionLedgerStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard, key: String = "grokling.completion-ledger.v1") {
        self.defaults = defaults
        self.key = key
    }

    func load() -> CompletionLedger {
        lock.withLock {
            guard let data = defaults.data(forKey: key),
                  let document = try? JSONDecoder().decode(CompletionLedgerDocument.self, from: data),
                  document.version == CompletionLedgerDocument.schemaVersion else { return CompletionLedger() }
            return document.ledger
        }
    }

    func save(_ ledger: CompletionLedger) {
        lock.withLock {
            let document = CompletionLedgerDocument(version: CompletionLedgerDocument.schemaVersion, ledger: ledger)
            guard let data = try? JSONEncoder().encode(document) else { return }
            defaults.set(data, forKey: key)
        }
    }
}
