import Foundation

enum GatewayCapabilityAvailability: String, Codable, Equatable, Sendable {
    case available
    case unavailable
}

struct GatewayStateCapabilities: Codable, Equatable, Sendable {
    let thinking: GatewayCapabilityAvailability
    let waiting: GatewayCapabilityAvailability
    let blocked: GatewayCapabilityAvailability
    let completionRevision: GatewayCapabilityAvailability
    let evidence: String

    /// Verified against Grok Bot Desktop 0.47.0 and 0.51.0 listAgents/SSE.
    /// No attributable blocked event + stable unblock revision was observed.
    static let verifiedLive = GatewayStateCapabilities(
        thinking: .available,
        waiting: .available,
        blocked: .unavailable,
        completionRevision: .available,
        evidence: "listAgents/SSE exposes isComposingMessage, awaitingUserResponse and message revision; no structured blocked signal"
    )

    static let experienceFixture = GatewayStateCapabilities(
        thinking: .available,
        waiting: .available,
        blocked: .available,
        completionRevision: .available,
        evidence: "fixture-only"
    )
}

enum GatewayPresenceAdapter {
    static let liveCapabilities = GatewayStateCapabilities.verifiedLive

    static func runtime(from record: GatewayAgentRecord) -> BotRuntime {
        let waitID = record.hasAwaitingUserResponse
            ? StructuredEventRef("waiting:\(record.id):\(record.messageRevision ?? "current")")
            : nil
        return BotRuntime(
            isRunning: record.isRunning,
            isComposing: record.isComposingMessage,
            awaitingUserResponse: record.hasAwaitingUserResponse ? .present : nil,
            messageRevision: record.messageRevision,
            waitingEvent: waitID,
            blockedEvent: nil,
            taskRevision: nil
        )
    }
}
