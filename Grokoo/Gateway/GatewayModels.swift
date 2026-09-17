import Foundation

struct DesktopSession: Sendable {
    let gatewayURL: URL
    let bearerToken: String
    let routeHeaders: [String: String]

    init(gatewayURL: URL, bearerToken: String, routeHeaders: [String: String] = [:]) {
        self.gatewayURL = gatewayURL
        self.bearerToken = bearerToken
        self.routeHeaders = routeHeaders
    }
}

/// Raw gateway projection. It intentionally has no prompt, message body,
/// transcript, unread, or arbitrary payload property.
struct GatewayAgentRecord: Equatable, Sendable {
    enum RuntimeField: Hashable, Sendable {
        case isRunning
        case isComposingMessage
        case awaitingUserResponse
    }

    let id: String
    var name: String
    var isGroup: Bool
    var memberIds: [String]
    var avatarShape: String?
    var avatarColor: String?
    var isRunning: Bool
    var isComposingMessage: Bool
    var hasAwaitingUserResponse: Bool
    var messageRevision: String?
    var providedRuntimeFields: Set<RuntimeField>

    init(
        id: String,
        name: String,
        isGroup: Bool,
        memberIds: [String],
        avatarShape: String?,
        avatarColor: String?,
        isRunning: Bool,
        isComposingMessage: Bool,
        hasAwaitingUserResponse: Bool,
        messageRevision: String?,
        providedRuntimeFields: Set<RuntimeField> = [.isRunning, .isComposingMessage, .awaitingUserResponse]
    ) {
        self.id = id
        self.name = name
        self.isGroup = isGroup
        self.memberIds = memberIds
        self.avatarShape = avatarShape
        self.avatarColor = avatarColor
        self.isRunning = isRunning
        self.isComposingMessage = isComposingMessage
        self.hasAwaitingUserResponse = hasAwaitingUserResponse
        self.messageRevision = messageRevision
        self.providedRuntimeFields = providedRuntimeFields
    }
}

enum GatewayEvent: Equatable, Sendable {
    case agentUpserted(GatewayAgentRecord)
    case messageMetadata(botId: BotID, revision: String)
    case agentRemoved(id: String)
    case connected
}

enum GatewayOfflineReason: String, Equatable, Sendable {
    case descriptorMissing
    case keychainDenied
    case noBots
    case timeout
    case unauthorized
    case network
    case invalidData
    case suspended
}

enum GatewayConnectionState: Equatable, Sendable {
    case idle
    case connecting
    case connected
    case offline(GatewayOfflineReason)
}

enum GatewayUpdate: Equatable, Sendable {
    case connection(GatewayConnectionState)
    case roster(RosterSnapshot)
    case event(GatewayEvent)
}

enum GatewayFailure: Error, Equatable, Sendable {
    case descriptorMissing
    case unsupportedDescriptor
    case keychainDenied
    case keychainUnavailable(status: Int32)
    case unsupportedCiphertext
    case decryptionFailed
    case invalidSession
    case invalidURL
    case unauthorized(operation: String)
    case httpStatus(operation: String, status: Int)
    case timeout(operation: String)
    case transport(operation: String)
    case invalidResponse(operation: String)
    case cancelled

    var offlineReason: GatewayOfflineReason {
        switch self {
        case .descriptorMissing: .descriptorMissing
        case .keychainDenied: .keychainDenied
        case .timeout: .timeout
        case .unauthorized: .unauthorized
        case .transport, .cancelled: .network
        case .unsupportedDescriptor, .keychainUnavailable, .unsupportedCiphertext,
             .decryptionFailed, .invalidSession, .invalidURL, .httpStatus, .invalidResponse:
            .invalidData
        }
    }
}

extension GatewayFailure: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .descriptorMissing: "Grok Bot session descriptor was not found."
        case .unsupportedDescriptor: "The Grok Bot session descriptor version is unsupported."
        case .keychainDenied: "Access to the Grok Bot desktop session was denied."
        case .keychainUnavailable: "The Grok Bot desktop session is unavailable."
        case .unsupportedCiphertext: "The Grok Bot Safe Storage format is unsupported."
        case .decryptionFailed: "The Grok Bot desktop session could not be decrypted."
        case .invalidSession: "The Grok Bot desktop session is incomplete."
        case .invalidURL: "The Grok Bot Gateway URL is invalid."
        case .unauthorized(let operation): "Gateway \(operation) was unauthorized."
        case .httpStatus(let operation, let status): "Gateway \(operation) failed with HTTP \(status)."
        case .timeout(let operation): "Gateway \(operation) timed out."
        case .transport(let operation): "Gateway \(operation) could not connect."
        case .invalidResponse(let operation): "Gateway \(operation) returned invalid data."
        case .cancelled: "Gateway operation was cancelled."
        }
    }
}

protocol DesktopSessionLoading: Sendable {
    func load() async throws -> DesktopSession
}

protocol GatewayRosterFetching: Sendable {
    func listAgents(session: DesktopSession) async throws -> [GatewayAgentRecord]
    func cancelPendingRequests() async
}

extension GatewayRosterFetching {
    func cancelPendingRequests() async {}
}

protocol GatewayEventStreaming: Sendable {
    func events(session: DesktopSession) -> AsyncThrowingStream<GatewayEvent, Error>
}
