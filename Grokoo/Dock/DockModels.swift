import Foundation

enum DockItemKind: String, Codable, Sendable { case bot, group }

enum DockPresentationState: String, Codable, CaseIterable, Sendable {
    case idle, working, thinking, waiting, blocked, done, offline

    var title: String {
        switch self {
        case .idle: "空闲"
        case .working: "工作中"
        case .thinking: "思考中"
        case .waiting: "等待回复"
        case .blocked: "需要处理"
        case .done: "已完成"
        case .offline: "离线"
        }
    }

    var frameInterval: TimeInterval {
        switch self {
        case .working, .blocked: 0.5
        case .thinking: 0.65
        case .waiting, .done: 0.75
        case .idle: 1
        case .offline: 1.5
        }
    }
}

struct DockMemberAppearance: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let shape: OfficialShape
    let color: OfficialColor
}

/// A content-free projection owned by the host. Helpers never connect to Gateway
/// or infer group state from a member's unrelated conversation.
struct DockItemSnapshot: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let kind: DockItemKind
    let displayName: String
    let shape: OfficialShape
    let color: OfficialColor
    var members: [DockMemberAppearance] = []
    let state: DockPresentationState
    var revision: UInt64
    let routeURL: URL?
    let fallbackURL: URL?
    var applicationBundleIdentifier: String = "com.anysphere.sand"

    func hasSamePresentation(as other: Self) -> Bool {
        var normalized = other
        normalized.revision = revision
        return self == normalized
    }
}

struct DockHelperConfiguration: Codable, Equatable, Sendable {
    let item: DockItemSnapshot
    let parentPID: Int32
    let reducedMotion: Bool
    let suspended: Bool
    let commandNotificationName: String
}

@MainActor
protocol DockServicing: AnyObject {
    var onDisableItem: ((String) -> Void)? { get set }
    var onAcknowledgeItem: ((String) -> Void)? { get set }
    func synchronize(items: [DockItemSnapshot], reducedMotion: Bool)
    func suspend()
    func resume()
    func shutdown()
}
