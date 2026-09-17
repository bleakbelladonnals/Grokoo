import Combine
import Foundation

@MainActor
final class SettingsStore: ObservableObject {
    struct MergeResult: Equatable {
        let wasInitialSetup: Bool
        let configurations: [PetConfiguration]
    }

    private struct LegacyConfiguration: Decodable {
        let botId: BotID
        let isVisible: Bool
        let mbti: MBTIType?
        let workstationRegion: WorkstationRegion
        let workstationOrder: Int
    }

    private struct LegacySnapshot: Decodable {
        let schemaVersion: Int
        let bots: [LegacyConfiguration]
    }

    static let maximumVisibleBots = 6
    static let defaultStorageKey = "grokling.settings.v1"

    @Published private(set) var configurations: [PetConfiguration]
    private let defaults: UserDefaults
    private let storageKey: String
    private(set) var hasPersistedConfiguration: Bool

    init(defaults: UserDefaults = .standard, storageKey: String = SettingsStore.defaultStorageKey) {
        self.defaults = defaults
        self.storageKey = storageKey
        if let data = defaults.data(forKey: storageKey),
           let snapshot = try? JSONDecoder().decode(SettingsSnapshot.self, from: data),
           snapshot.schemaVersion == SettingsSnapshot.currentSchemaVersion {
            configurations = Self.normalized(snapshot.bots)
            hasPersistedConfiguration = true
        } else if let data = defaults.data(forKey: storageKey),
                  let legacy = try? JSONDecoder().decode(LegacySnapshot.self, from: data),
                  legacy.schemaVersion == 1 {
            configurations = Self.migrate(legacy.bots)
            hasPersistedConfiguration = true
            persist()
        } else {
            configurations = []
            hasPersistedConfiguration = false
        }
    }

    @discardableResult
    func merge(botIDs: [BotID]) -> MergeResult {
        let roster = Self.unique(botIDs)
        let initial = !hasPersistedConfiguration
        let existing = Dictionary(uniqueKeysWithValues: configurations.map { ($0.botId, $0) })
        var nextOrder = (configurations.map(\.globalOrder).max() ?? -1) + 1
        let merged = roster.enumerated().map { index, id in
            if let current = existing[id] { return current }
            defer { nextOrder += 1 }
            return PetConfiguration(
                botId: id,
                isVisible: initial && index < Self.maximumVisibleBots,
                mbti: nil,
                globalOrder: initial ? index : nextOrder
            )
        }
        let normalized = Self.normalized(merged)
        if configurations != normalized || initial { configurations = normalized; persist() }
        return MergeResult(wasInitialSetup: initial, configurations: configurations)
    }

    func configuration(for botId: BotID) -> PetConfiguration? { configurations.first { $0.botId == botId } }

    @discardableResult
    func setVisibility(_ visible: Bool, for botId: BotID) -> Bool {
        guard let index = configurations.firstIndex(where: { $0.botId == botId }) else { return false }
        if visible, !configurations[index].isVisible,
           configurations.filter(\.isVisible).count >= Self.maximumVisibleBots { return false }
        configurations[index].isVisible = visible
        persist()
        return true
    }

    func setMBTI(_ mbti: MBTIType?, for botId: BotID) { update(botId) { $0.mbti = mbti } }

    func move(botId: BotID, to destination: Int) {
        var ordered = configurations.sorted(by: Self.order)
        guard let source = ordered.firstIndex(where: { $0.botId == botId }), !ordered.isEmpty else { return }
        let target = min(max(destination, 0), ordered.count - 1)
        guard source != target else { return }
        let value = ordered.remove(at: source)
        ordered.insert(value, at: target)
        for index in ordered.indices { ordered[index].globalOrder = index }
        configurations = ordered
        persist()
    }

    func move(botId: BotID, by delta: Int) {
        let ordered = configurations.sorted(by: Self.order)
        guard let source = ordered.firstIndex(where: { $0.botId == botId }) else { return }
        move(botId: botId, to: source + delta)
    }

    func reset() {
        defaults.removeObject(forKey: storageKey)
        configurations = []
        hasPersistedConfiguration = false
    }

    private func update(_ id: BotID, mutation: (inout PetConfiguration) -> Void) {
        guard let index = configurations.firstIndex(where: { $0.botId == id }) else { return }
        mutation(&configurations[index])
        configurations = Self.normalized(configurations)
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(SettingsSnapshot(bots: configurations)) else { return }
        defaults.set(data, forKey: storageKey)
        hasPersistedConfiguration = true
    }

    private static func migrate(_ rows: [LegacyConfiguration]) -> [PetConfiguration] {
        let rank: [WorkstationRegion: Int] = [.left: 0, .center: 1, .right: 2]
        return rows.sorted {
            let l = rank[$0.workstationRegion] ?? 1
            let r = rank[$1.workstationRegion] ?? 1
            if l != r { return l < r }
            if $0.workstationOrder != $1.workstationOrder { return $0.workstationOrder < $1.workstationOrder }
            return $0.botId < $1.botId
        }.enumerated().map { index, row in
            PetConfiguration(botId: row.botId, isVisible: row.isVisible, mbti: row.mbti, globalOrder: index)
        }
    }

    private static func normalized(_ rows: [PetConfiguration]) -> [PetConfiguration] {
        var visible = 0
        return rows.sorted(by: order).enumerated().map { index, row in
            var value = row
            value.globalOrder = index
            if value.isVisible { visible += 1; value.isVisible = visible <= maximumVisibleBots }
            return value
        }
    }

    private static func order(_ lhs: PetConfiguration, _ rhs: PetConfiguration) -> Bool {
        lhs.globalOrder == rhs.globalOrder ? lhs.botId < rhs.botId : lhs.globalOrder < rhs.globalOrder
    }

    private static func unique(_ values: [BotID]) -> [BotID] {
        var seen = Set<BotID>()
        return values.filter { seen.insert($0).inserted }
    }
}
