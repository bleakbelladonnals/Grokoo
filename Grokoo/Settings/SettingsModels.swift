import Foundation

struct PetConfiguration: Codable, Equatable, Identifiable, Sendable {
    let botId: BotID
    var isVisible: Bool
    var mbti: MBTIType?
    var globalOrder: Int

    var id: BotID { botId }

    init(botId: BotID, isVisible: Bool, mbti: MBTIType?, globalOrder: Int) {
        self.botId = botId
        self.isVisible = isVisible
        self.mbti = mbti
        self.globalOrder = globalOrder
    }

}

struct SettingsSnapshot: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2
    let schemaVersion: Int
    var bots: [PetConfiguration]

    init(schemaVersion: Int = SettingsSnapshot.currentSchemaVersion, bots: [PetConfiguration]) {
        self.schemaVersion = schemaVersion
        self.bots = bots
    }
}

struct SettingsBot: Identifiable, Equatable, Sendable {
    let id: BotID
    let name: String
}

enum SettingsConnectionState: Equatable, Sendable {
    case connecting, connected, timedOut, keychainDenied, noBots, offline

    var title: String {
        switch self {
        case .connecting: "正在同步 Bot…"
        case .connected: "已连接 Grok Bot"
        case .timedOut: "连接超时"
        case .keychainDenied: "无法读取本机会话"
        case .noBots: "还没有可显示的 Bot"
        case .offline: "Grok Bot 当前离线"
        }
    }

    var guidance: String? {
        switch self {
        case .connecting: "已有配置保持可用。"
        case .connected: nil
        case .timedOut: "未能在限定时间内取得 Bot 列表，可以稍后重试。"
        case .keychainDenied: "允许访问 Grok Bot 的本机会话后即可重试。"
        case .noBots: "请先在 Grok Bot 中创建普通 Bot，然后重试。"
        case .offline: "桌宠会保持离线状态，连接恢复后自动同步。"
        }
    }

    var canRetry: Bool { ![.connecting, .connected].contains(self) }
}

enum InitialConnectionFailure: Equatable, Sendable {
    case timedOut, keychainDenied, noBots, offline
    var settingsState: SettingsConnectionState {
        switch self {
        case .timedOut: .timedOut
        case .keychainDenied: .keychainDenied
        case .noBots: .noBots
        case .offline: .offline
        }
    }
}
