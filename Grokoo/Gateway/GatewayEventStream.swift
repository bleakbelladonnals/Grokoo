import Foundation

/// Incremental SSE frame parser. It understands `event:` and multi-line `data:`
/// fields, ignores comments/retry/id fields, and never exposes a raw payload.
struct SSEFrameParser: Sendable {
    private var lineBuffer = Data()
    private var eventName: String?
    private var dataLines: [String] = []

    mutating func append(_ chunk: Data) -> [GatewayEvent] {
        var events: [GatewayEvent] = []
        for byte in chunk {
            if byte == 0x0A {
                var lineData = lineBuffer
                if lineData.last == 0x0D { lineData.removeLast() }
                lineBuffer.removeAll(keepingCapacity: true)
                guard let line = String(data: lineData, encoding: .utf8) else { continue }
                if let event = consume(line: line) { events.append(event) }
            } else {
                lineBuffer.append(byte)
            }
        }
        return events
    }

    mutating func finish() -> [GatewayEvent] {
        var events: [GatewayEvent] = []
        if !lineBuffer.isEmpty, let line = String(data: lineBuffer, encoding: .utf8) {
            if let event = consume(line: line) { events.append(event) }
        }
        lineBuffer.removeAll()
        if let event = dispatch() { events.append(event) }
        return events
    }

    private mutating func consume(line: String) -> GatewayEvent? {
        if line.isEmpty { return dispatch() }
        if line.hasPrefix(":") { return nil }
        let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let field = String(parts[0])
        var value = parts.count == 2 ? String(parts[1]) : ""
        if value.first == " " { value.removeFirst() }
        switch field {
        case "event": eventName = value
        case "data": dataLines.append(value)
        default: break
        }
        return nil
    }

    private mutating func dispatch() -> GatewayEvent? {
        defer {
            eventName = nil
            dataLines.removeAll(keepingCapacity: true)
        }
        guard !dataLines.isEmpty else { return nil }
        let data = Data(dataLines.joined(separator: "\n").utf8)
        return GatewayEventDecoder.decode(eventName: eventName, data: data)
    }
}

enum GatewayEventDecoder {
    static func decode(eventName: String?, data: Data) -> GatewayEvent? {
        guard let root = try? JSONSerialization.jsonObject(with: data),
              let object = root as? [String: Any] else { return nil }
        let type = eventName.flatMap(nonEmpty)
            ?? (object["type"] as? String).flatMap(nonEmpty)
            ?? (object["event"] as? String).flatMap(nonEmpty)
        let payload = nestedRecord(in: object) ?? object

        if type == "agent-removed" || type == "agentRemoved" {
            guard let id = string(payload["id"]) ?? string(payload["agentId"]) else { return nil }
            return .agentRemoved(id: id)
        }

        if type == "message-metadata" || type == "transcript" || type == "message" {
            let agent = payload["agent"] as? [String: Any]
            guard let id = string(payload["agentId"])
                    ?? string(payload["botId"])
                    ?? string(agent?["id"]),
                  let revision = GatewayAgentDecoder.revision(in: payload)
                    ?? agent.flatMap(GatewayAgentDecoder.revision(in:)) else { return nil }
            return .messageMetadata(botId: id, revision: revision)
        }

        guard type == nil || type == "agent-upserted" || type == "agentUpserted" || type == "roster-correction" else {
            return nil
        }
        let agentValue = payload["agent"] ?? payload
        guard var record = GatewayAgentDecoder.decodeRecord(agentValue, isPatch: true) else { return nil }
        if record.messageRevision == nil { record.messageRevision = GatewayAgentDecoder.revision(in: payload) }
        return .agentUpserted(record)
    }

    private static func nestedRecord(in root: [String: Any]) -> [String: Any]? {
        for key in ["data", "payload", "value", "result"] {
            if let nested = root[key] as? [String: Any] { return nested }
        }
        return nil
    }

    private static func string(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }

    private static func nonEmpty(_ value: String) -> String? { value.isEmpty ? nil : value }
}

final class GatewayEventStream: GatewayEventStreaming, @unchecked Sendable {
    private let session: URLSession
    private let logger: any GatewayLogging

    init(session: URLSession = .shared, logger: any GatewayLogging = GatewayLogger()) {
        self.session = session
        self.logger = logger
    }

    func events(session desktopSession: DesktopSession) -> AsyncThrowingStream<GatewayEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [session, logger] in
                do {
                    var request = try GatewayHTTPClient.request(session: desktopSession, path: "events")
                    request.httpMethod = "GET"
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.timeoutInterval = 60
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let response = response as? HTTPURLResponse else {
                        throw GatewayFailure.invalidResponse(operation: "events")
                    }
                    guard response.statusCode != 401 else {
                        throw GatewayFailure.unauthorized(operation: "events")
                    }
                    guard (200..<300).contains(response.statusCode) else {
                        throw GatewayFailure.httpStatus(operation: "events", status: response.statusCode)
                    }
                    continuation.yield(.connected)
                    var parser = SSEFrameParser()
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        for event in parser.append(Data([byte])) { continuation.yield(event) }
                    }
                    for event in parser.finish() { continuation.yield(event) }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch let failure as GatewayFailure {
                    continuation.finish(throwing: failure)
                } catch {
                    logger.log(.error, "Gateway events transport failure")
                    continuation.finish(throwing: GatewayFailure.transport(operation: "events"))
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}
