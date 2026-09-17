import Foundation

struct GatewayHTTPResponse: Sendable {
    let data: Data
    let statusCode: Int
}

protocol GatewayHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> GatewayHTTPResponse
}

final class URLSessionGatewayTransport: GatewayHTTPTransport, @unchecked Sendable {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func data(for request: URLRequest) async throws -> GatewayHTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GatewayFailure.invalidResponse(operation: request.url?.lastPathComponent ?? "request")
        }
        return GatewayHTTPResponse(data: data, statusCode: http.statusCode)
    }
}

actor GatewayHTTPClient: GatewayRosterFetching {
    private struct InFlightRequest {
        let id: UUID
        let task: Task<[GatewayAgentRecord], Error>
    }

    private let transport: any GatewayHTTPTransport
    private let timeout: Duration
    private let logger: any GatewayLogging
    private var listAgentsInFlight: InFlightRequest?

    init(
        transport: any GatewayHTTPTransport = URLSessionGatewayTransport(),
        timeout: Duration = .seconds(20),
        logger: any GatewayLogging = GatewayLogger()
    ) {
        self.transport = transport
        self.timeout = timeout
        self.logger = logger
    }

    func listAgents(session: DesktopSession) async throws -> [GatewayAgentRecord] {
        if let inFlight = listAgentsInFlight {
            return try await inFlight.task.value
        }
        let requestID = UUID()
        let task = Task { [transport, timeout, logger] in
            try await Self.fetchAgents(session: session, transport: transport, timeout: timeout, logger: logger)
        }
        listAgentsInFlight = InFlightRequest(id: requestID, task: task)
        defer {
            if listAgentsInFlight?.id == requestID {
                listAgentsInFlight = nil
            }
        }
        return try await task.value
    }

    func cancelPendingRequests() async {
        listAgentsInFlight?.task.cancel()
        listAgentsInFlight = nil
    }

    private static func fetchAgents(
        session: DesktopSession,
        transport: any GatewayHTTPTransport,
        timeout: Duration,
        logger: any GatewayLogging
    ) async throws -> [GatewayAgentRecord] {
        let operation = "listAgents"
        var request = try request(session: session, path: "api/listAgents")
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let finalRequest = request
        let activeTransport = transport
        let response: GatewayHTTPResponse
        do {
            response = try await withHardTimeout(timeout, operationName: operation) {
                try await activeTransport.data(for: finalRequest)
            }
        } catch is CancellationError {
            throw GatewayFailure.cancelled
        } catch let failure as GatewayFailure {
            throw failure
        } catch {
            logger.log(.error, "Gateway \(operation) transport failure")
            throw GatewayFailure.transport(operation: operation)
        }

        switch response.statusCode {
        case 200..<300:
            do {
                return try GatewayAgentDecoder.decodeList(response.data)
            } catch let failure as GatewayFailure {
                throw failure
            } catch {
                throw GatewayFailure.invalidResponse(operation: operation)
            }
        case 401:
            throw GatewayFailure.unauthorized(operation: operation)
        default:
            // Response bodies may echo credentials or content and are intentionally ignored.
            throw GatewayFailure.httpStatus(operation: operation, status: response.statusCode)
        }
    }

    static func request(session: DesktopSession, path: String) throws -> URLRequest {
        let url = session.gatewayURL.appending(path: path)
        guard url.scheme != nil else { throw GatewayFailure.invalidURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Bearer \(session.bearerToken)", forHTTPHeaderField: "Authorization")
        for (name, value) in session.routeHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }
}

private func withHardTimeout<Value: Sendable>(
    _ timeout: Duration,
    operationName: String,
    operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    try await withThrowingTaskGroup(of: Value.self) { group in
        group.addTask(operation: operation)
        group.addTask {
            try await Task.sleep(for: timeout)
            throw GatewayFailure.timeout(operation: operationName)
        }
        guard let first = try await group.next() else {
            throw GatewayFailure.cancelled
        }
        group.cancelAll()
        return first
    }
}

enum GatewayAgentDecoder {
    static func decodeList(_ data: Data) throws -> [GatewayAgentRecord] {
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw GatewayFailure.invalidResponse(operation: "listAgents")
        }
        guard let rows = unwrapRows(value) else {
            throw GatewayFailure.invalidResponse(operation: "listAgents")
        }
        return rows.compactMap { decodeRecord($0, isPatch: false) }
    }

    static func decodeRecord(_ value: Any, isPatch: Bool = false) -> GatewayAgentRecord? {
        guard let row = value as? [String: Any],
              let id = string(row["id"]) ?? string(row["agentId"]) else {
            return nil
        }
        let memberIds = stringArray(row["memberIds"] ?? row["memberAgentIds"])
        let explicitGroup = bool(row["isGroup"])
        let awaiting = hasMeaningfulValue(row["awaitingUserResponse"])
        let providedRuntimeFields: Set<GatewayAgentRecord.RuntimeField> = isPatch
            ? Set([
                row.keys.contains("isRunning") ? .isRunning : nil,
                row.keys.contains("isComposingMessage") ? .isComposingMessage : nil,
                row.keys.contains("awaitingUserResponse") ? .awaitingUserResponse : nil,
            ].compactMap { $0 })
            : [.isRunning, .isComposingMessage, .awaitingUserResponse]
        return GatewayAgentRecord(
            id: id,
            name: string(row["name"]) ?? id,
            isGroup: explicitGroup ?? !memberIds.isEmpty,
            memberIds: memberIds,
            avatarShape: string(row["avatarShape"]),
            avatarColor: string(row["avatarColor"]),
            isRunning: bool(row["isRunning"]) ?? false,
            isComposingMessage: bool(row["isComposingMessage"]) ?? false,
            hasAwaitingUserResponse: awaiting,
            messageRevision: revision(in: row),
            providedRuntimeFields: providedRuntimeFields
        )
    }

    static func revision(in row: [String: Any]) -> String? {
        string(row["messageRevision"])
            ?? string(row["revision"])
            ?? string(row["entryId"])
            ?? string(row["messageId"])
    }

    private static func unwrapRows(_ value: Any) -> [Any]? {
        if let rows = value as? [Any] { return rows }
        guard let object = value as? [String: Any] else { return nil }
        for key in ["agents", "result", "data"] {
            if let rows = object[key] as? [Any] { return rows }
        }
        if let value = object["value"] as? [String: Any], let rows = value["rows"] as? [Any] {
            return rows
        }
        if let result = object["result"] as? [String: Any] {
            for key in ["agents", "rows"] where result[key] is [Any] {
                return result[key] as? [Any]
            }
        }
        return nil
    }

    private static func string(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        return value
    }

    private static func stringArray(_ value: Any?) -> [String] {
        guard let values = value as? [Any] else { return [] }
        var seen = Set<String>()
        return values.compactMap { value in
            guard let string = string(value), seen.insert(string).inserted else { return nil }
            return string
        }
    }

    private static func bool(_ value: Any?) -> Bool? {
        value as? Bool
    }

    private static func hasMeaningfulValue(_ value: Any?) -> Bool {
        switch value {
        case nil, is NSNull:
            false
        case let string as String:
            !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case let array as [Any]:
            !array.isEmpty
        case let object as [String: Any]:
            !object.isEmpty
        case let bool as Bool:
            bool
        default:
            true
        }
    }
}
