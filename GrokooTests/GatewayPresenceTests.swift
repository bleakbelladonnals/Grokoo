import Foundation
import XCTest
@testable import Grokoo

@MainActor
final class GatewayPresenceTests: XCTestCase {
    func testGatewayRedactionRemovesCredentialsFromDiagnostics() {
        let diagnostic = "Authorization:Bearer-raw bearer session-raw token=token-raw password:pw-raw secret=secret-raw cookie=cookie-raw"
        let sanitized = GatewayRedaction.sanitize(diagnostic)

        for forbidden in ["Bearer-raw", "session-raw", "token-raw", "pw-raw", "secret-raw", "cookie-raw"] {
            XCTAssertFalse(sanitized.contains(forbidden))
        }
        XCTAssertTrue(sanitized.contains("<redacted>"))
    }

    func testDescriptorV1V2AndElectronV10Fixture() throws {
        let encrypted = "djEwym3YPLWcl/DwQL0lW3NewqBioiXajnytkvjLV9O+yymLJYz1flepOS+Ws9++bctHARGNpFLXpcxwt8+9JDNaeXiOKvfqQ3pxlD1sA1FWmFKv0l/xXFUpEH/Rfe0i9wRjVf8pscvarDVK7OM6ppURQCNr+wg7oNHBZkVYD/qecS8="
        let expected = #"{"baseUrl":"https://edge.example/v1/sand/","token":"desk-session-token","headers":{"x-anyrun-network-token":"route-secret"}}"#

        XCTAssertEqual(
            try SafeStorageDecryptor().decrypt(base64Ciphertext: encrypted, password: "keychain-test-password"),
            expected
        )
        XCTAssertEqual(
            try DesktopSessionLoader.encryptedPayload(from: Data(#"{"version":1,"encrypted":"\#(encrypted)"}"#.utf8)),
            encrypted
        )
        XCTAssertEqual(
            try DesktopSessionLoader.encryptedPayload(from: Data(#"{"version":2,"entries":{"only":{"encrypted":"\#(encrypted)"}}}"#.utf8)),
            encrypted
        )
        let session = try DesktopSessionLoader.session(fromCleartext: expected)
        XCTAssertEqual(session.gatewayURL.absoluteString, "https://edge.example/v1/sand")
        XCTAssertEqual(session.bearerToken, "desk-session-token")
        XCTAssertEqual(session.routeHeaders["x-anyrun-network-token"], "route-secret")
    }

    func testDescriptorRejectsAmbiguousV2EntriesAndUnsupportedCiphertext() {
        XCTAssertThrowsError(
            try DesktopSessionLoader.encryptedPayload(
                from: Data(#"{"version":2,"entries":{"a":"one","b":"two"}}"#.utf8)
            )
        )
        XCTAssertThrowsError(
            try SafeStorageDecryptor().decrypt(
                base64Ciphertext: Data("v11not-supported".utf8).base64EncodedString(),
                password: "irrelevant"
            )
        )
    }

    func testListAgentsCompatibleWrappersKeepOnlyMinimumFields() throws {
        let row = #"{"id":"bot-1","name":"Sandy","isGroup":false,"avatarShape":"wedge","avatarColor":"magenta","isRunning":true,"isComposingMessage":false,"awaitingUserResponse":{"kind":"approval","prompt":"must-not-escape"},"prompt":"secret body","hasUnread":true}"#
        let payloads = [
            "[\(row)]",
            "{\"agents\":[\(row)]}",
            "{\"result\":[\(row)]}",
            "{\"value\":{\"rows\":[\(row)]}}",
        ]
        for payload in payloads {
            let records = try GatewayAgentDecoder.decodeList(Data(payload.utf8))
            XCTAssertEqual(records.count, 1)
            XCTAssertEqual(records[0].id, "bot-1")
            XCTAssertEqual(records[0].avatarShape, "wedge")
            XCTAssertTrue(records[0].hasAwaitingUserResponse)
            XCTAssertFalse(String(reflecting: records[0]).contains("must-not-escape"))
            XCTAssertFalse(String(reflecting: records[0]).contains("secret body"))
        }
    }

    func testHTTPClientAppliesHardTimeout() async {
        let client = GatewayHTTPClient(
            transport: SlowTransport(),
            timeout: .milliseconds(20),
            logger: NullGatewayLogger()
        )
        let session = DesktopSession(gatewayURL: URL(string: "https://example.invalid")!, bearerToken: "not-logged")
        do {
            _ = try await client.listAgents(session: session)
            XCTFail("Expected a hard timeout")
        } catch let error as GatewayFailure {
            XCTAssertEqual(error, .timeout(operation: "listAgents"))
        } catch {
            XCTFail("Unexpected error: \(type(of: error))")
        }
    }

    func testHTTPClientCancellationHookCancelsUnderlyingTransport() async {
        let transport = CancellationObservingTransport()
        let client = GatewayHTTPClient(
            transport: transport,
            timeout: .seconds(60),
            logger: NullGatewayLogger()
        )
        let session = DesktopSession(gatewayURL: URL(string: "https://example.invalid")!, bearerToken: "not-logged")
        let request = Task { try await client.listAgents(session: session) }
        let started = await eventually { await transport.startCount() == 1 }
        XCTAssertTrue(started)

        await client.cancelPendingRequests()
        do {
            _ = try await request.value
            XCTFail("Expected cancellation")
        } catch let failure as GatewayFailure {
            XCTAssertEqual(failure, .cancelled)
        } catch {
            XCTFail("Unexpected error: \(type(of: error))")
        }
        let transportCancelled = await eventually { await transport.cancellationCount() == 1 }
        XCTAssertTrue(transportCancelled)
    }

    func testSSEParserHandlesCRLFChunksAndDropsBody() {
        let source = "event: agent-upserted\r\ndata: {\"agent\":{\"id\":\"bot-1\",\"name\":\"Sandy\",\"isRunning\":true}}\r\n\r\n"
            + "event: message-metadata\n"
            + "data: {\"agent\":{\"id\":\"bot-1\"},\"messageRevision\":\"rev-1\",\"content\":\"private body\"}\n\n"
        var parser = SSEFrameParser()
        let bytes = Data(source.utf8)
        let split = bytes.count / 3
        let events = parser.append(bytes.prefix(split))
            + parser.append(bytes[split..<(split * 2)])
            + parser.append(bytes.suffix(from: split * 2))
            + parser.finish()

        XCTAssertEqual(events.count, 2)
        guard case .agentUpserted(let record) = events[0] else { return XCTFail("Missing upsert") }
        XCTAssertEqual(record.id, "bot-1")
        XCTAssertTrue(record.isRunning)
        XCTAssertEqual(events[1], .messageMetadata(botId: "bot-1", revision: "rev-1"))
        XCTAssertFalse(String(reflecting: events).contains("private body"))
    }

    func testPartialAgentUpsertPreservesOmittedRuntimeFields() async {
        let store = BotRosterStore()
        _ = await store.replace(with: [
            GatewayAgentRecord(
                id: "bot-1",
                name: "Sandy",
                isGroup: false,
                memberIds: [],
                avatarShape: "blob",
                avatarColor: "blue",
                isRunning: true,
                isComposingMessage: false,
                hasAwaitingUserResponse: true,
                messageRevision: "rev-1"
            ),
            GatewayAgentRecord(
                id: "group-1",
                name: "Group",
                isGroup: true,
                memberIds: ["bot-1"],
                avatarShape: nil,
                avatarColor: nil,
                isRunning: true,
                isComposingMessage: false,
                hasAwaitingUserResponse: false,
                messageRevision: nil
            ),
        ])

        let appearanceData = Data(#"{"agent":{"id":"bot-1","avatarColor":"red"}}"#.utf8)
        guard let appearanceEvent = GatewayEventDecoder.decode(eventName: "agent-upserted", data: appearanceData) else {
            return XCTFail("Expected a partial appearance event")
        }
        var snapshot = await store.apply(appearanceEvent)
        XCTAssertEqual(snapshot.bots["bot-1"]?.color, .red)
        XCTAssertEqual(snapshot.bots["bot-1"]?.runtime.isRunning, true)
        XCTAssertEqual(snapshot.bots["bot-1"]?.runtime.awaitingUserResponse, .present)
        XCTAssertEqual(snapshot.bots["bot-1"]?.runtime.messageRevision, "rev-1")

        let groupData = Data(#"{"agent":{"id":"group-1","name":"Renamed"}}"#.utf8)
        guard let groupEvent = GatewayEventDecoder.decode(eventName: "agent-upserted", data: groupData) else {
            return XCTFail("Expected a partial group event")
        }
        snapshot = await store.apply(groupEvent)
        XCTAssertEqual(snapshot.groups["group-1"]?.isRunning, true)
        XCTAssertEqual(snapshot.groups["group-1"]?.memberIds, ["bot-1"])

        let stoppedData = Data(#"{"agent":{"id":"bot-1","isRunning":false,"awaitingUserResponse":null}}"#.utf8)
        guard let stoppedEvent = GatewayEventDecoder.decode(eventName: "agent-upserted", data: stoppedData) else {
            return XCTFail("Expected an explicit stopped event")
        }
        snapshot = await store.apply(stoppedEvent)
        XCTAssertEqual(snapshot.bots["bot-1"]?.runtime.isRunning, false)
        XCTAssertNil(snapshot.bots["bot-1"]?.runtime.awaitingUserResponse)
    }

    func testRosterSeparatesGroupsAndIgnoresMissingMembers() {
        let records = [
            Self.record(id: "bot-1"),
            Self.record(id: "bot-2", shape: "teardrop", color: "red"),
            Self.record(id: "group-1", isGroup: true, memberIds: ["bot-1", "missing", "bot-2", "bot-1"]),
        ]
        let roster = BotRosterStore.normalize(records)
        XCTAssertEqual(Set(roster.bots.keys), ["bot-1", "bot-2"])
        XCTAssertNil(roster.bots["group-1"])
        XCTAssertEqual(roster.groups["group-1"]?.memberIds, ["bot-1", "bot-2"])
        XCTAssertEqual(roster.bots["bot-2"]?.shape, .teardrop)
        XCTAssertEqual(roster.bots["bot-2"]?.color, .red)
    }

    func testPresencePriorityAndMessageBeforeStopCelebratesOnce() {
        var reducer = PresenceReducer()
        let start = ContinuousClock.now
        XCTAssertEqual(reducer.reduce(botId: "bot", runtime: .init(), gatewayAvailable: false, now: start), .offline)
        XCTAssertEqual(
            reducer.reduce(
                botId: "bot",
                runtime: .init(isRunning: true, awaitingUserResponse: .present),
                gatewayAvailable: true,
                now: start
            ),
            .waiting
        )
        XCTAssertEqual(
            reducer.reduce(botId: "bot", runtime: .init(isRunning: true), gatewayAvailable: true, now: start),
            .working
        )
        XCTAssertEqual(
            reducer.reduce(botId: "bot", runtime: .init(isRunning: true, messageRevision: "rev-1"), gatewayAvailable: true, now: start),
            .working
        )
        let done = reducer.reduce(
            botId: "bot",
            runtime: .init(messageRevision: "rev-1"),
            gatewayAvailable: true,
            now: start
        )
        XCTAssertEqual(done, .done)
        XCTAssertEqual(
            reducer.reduce(botId: "bot", runtime: .init(messageRevision: "rev-1"), gatewayAvailable: true, now: start.advanced(by: .seconds(40))),
            .done
        )
        reducer.acknowledgeDone(botId: "bot")
        XCTAssertEqual(reducer.reduce(botId: "bot", runtime: .init(messageRevision: "rev-1"), gatewayAvailable: true, now: start.advanced(by: .seconds(41))), .idle)
    }

    func testPresenceMessageAfterStopAndDuplicateRevision() {
        var reducer = PresenceReducer(lateRevisionWindow: .seconds(5))
        let start = ContinuousClock.now
        XCTAssertEqual(reducer.reduce(botId: "bot", runtime: .init(isRunning: true), gatewayAvailable: true, now: start), .working)
        XCTAssertEqual(reducer.reduce(botId: "bot", runtime: .init(), gatewayAvailable: true, now: start), .idle)
        let done = reducer.reduce(
            botId: "bot",
            runtime: .init(messageRevision: "rev-late"),
            gatewayAvailable: true,
            now: start.advanced(by: .seconds(1))
        )
        XCTAssertEqual(done, .done)
        XCTAssertEqual(
            reducer.reduce(
                botId: "bot",
                runtime: .init(messageRevision: "rev-late"),
                gatewayAvailable: true,
                now: start.advanced(by: .seconds(10))
            ),
            .done
        )
        reducer.acknowledgeDone(botId: "bot")
        XCTAssertEqual(
            reducer.reduce(botId: "bot", runtime: .init(messageRevision: "rev-late"), gatewayAvailable: true, now: start.advanced(by: .seconds(11))),
            .idle
        )
    }

    func testDisconnectNeverCreatesDoneAttention() {
        var reducer = PresenceReducer()
        let now = ContinuousClock.now
        XCTAssertEqual(reducer.reduce(botId: "bot", runtime: .init(isRunning: true), gatewayAvailable: true, now: now), .working)
        XCTAssertEqual(reducer.reduce(botId: "bot", runtime: .init(messageRevision: "rev"), gatewayAvailable: false, now: now), .offline)
        XCTAssertEqual(reducer.reduce(botId: "bot", runtime: .init(messageRevision: "rev"), gatewayAvailable: true, now: now), .done)
    }

    func testGroupBarrierEarlyRestAndOverlapAtomicTransfer() {
        var tracker = GroupActivityTracker()
        var roster = BotRosterStore.normalize([
            Self.record(id: "a", running: true),
            Self.record(id: "b", running: true),
            Self.record(id: "g1", isGroup: true, memberIds: ["a", "b"], running: true),
            Self.record(id: "g2", isGroup: true, memberIds: ["a"], running: true),
        ])
        var activity = tracker.update(roster: roster, visibleBotIds: ["a", "b"])
        XCTAssertEqual(activity.assignments["a"]?.groupId, "g1")
        XCTAssertEqual(activity.assignments["b"]?.mode, .working)

        roster.bots["a"]?.runtime.isRunning = false
        activity = tracker.update(roster: roster, visibleBotIds: ["a", "b"])
        XCTAssertEqual(activity.assignments["a"]?.groupId, "g1")
        XCTAssertEqual(activity.assignments["a"]?.mode, .resting)

        roster.groups["g1"]?.isRunning = false
        roster.bots["b"]?.runtime.isRunning = false
        activity = tracker.update(roster: roster, visibleBotIds: ["a", "b"])
        XCTAssertNil(activity.sessions["g1"])
        XCTAssertEqual(activity.assignments["a"]?.groupId, "g2")
    }

    func testGroupBarrierSurvivesMissingGroupRecordUntilLastMemberStops() {
        var tracker = GroupActivityTracker()
        var roster = BotRosterStore.normalize([
            Self.record(id: "a", running: true),
            Self.record(id: "g", isGroup: true, memberIds: ["a"], running: true),
        ])
        var activity = tracker.update(roster: roster, visibleBotIds: ["a"])
        XCTAssertNotNil(activity.sessions["g"])

        roster.groups.removeValue(forKey: "g")
        activity = tracker.update(roster: roster, visibleBotIds: ["a"])

        XCTAssertEqual(activity.sessions["g"]?.groupRunning, false)
        XCTAssertEqual(activity.sessions["g"]?.memberRunning, ["a"])
        XCTAssertEqual(activity.assignments["a"]?.groupId, "g")

        roster.bots["a"]?.runtime.isRunning = false
        activity = tracker.update(roster: roster, visibleBotIds: ["a"])

        XCTAssertNil(activity.sessions["g"])
        XCTAssertNil(activity.assignments["a"])
    }

    func testBackoffSequenceAnd401Reload() async {
        XCTAssertEqual(
            GatewayBackoffPolicy().delays,
            [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(15)]
        )
        let loader = CountingSessionLoader()
        let roster = UnauthorizedOnceRosterClient()
        let coordinator = GatewayCoordinator(
            sessionLoader: loader,
            rosterClient: roster,
            eventStream: HoldingEventStream(),
            retrySleeper: ImmediateRetrySleeper(),
            rosterCorrectionInterval: .seconds(3600),
            logger: NullGatewayLogger()
        )
        let stream = await coordinator.updates()
        await coordinator.start()
        for await update in stream {
            if case .roster(let snapshot) = update, snapshot.bots["bot-ok"] != nil { break }
        }
        await coordinator.stop()
        let loadCount = await loader.loadCount()
        XCTAssertGreaterThanOrEqual(loadCount, 2)
    }

    func testManualRefreshRestartsEventStreamAfterRetryBudgetIsExhausted() async {
        let loader = CountingSessionLoader()
        let roster = AlwaysAvailableRosterClient()
        let events = CountingClosingEventStream()
        let coordinator = GatewayCoordinator(
            sessionLoader: loader,
            rosterClient: roster,
            eventStream: events,
            retrySleeper: ImmediateRetrySleeper(),
            rosterCorrectionInterval: .seconds(3600),
            logger: NullGatewayLogger()
        )

        await coordinator.start()
        let exhaustedInitialBudget = await eventually { events.subscriptionCount() >= 6 }
        XCTAssertTrue(exhaustedInitialBudget)
        let subscriptionsBeforeRefresh = events.subscriptionCount()

        await coordinator.refresh()
        let resubscribed = await eventually { events.subscriptionCount() > subscriptionsBeforeRefresh }
        XCTAssertTrue(resubscribed)
        let loadCount = await loader.loadCount()
        XCTAssertGreaterThanOrEqual(loadCount, 2)

        await coordinator.stop()
    }

    func testSleepWakeCancelsOldRosterAndRejectsItsLateResult() async {
        let loader = CountingSessionLoader()
        let roster = SleepWakeRosterClient()
        let coordinator = GatewayCoordinator(
            sessionLoader: loader,
            rosterClient: roster,
            eventStream: HoldingEventStream(),
            retrySleeper: ImmediateRetrySleeper(),
            rosterCorrectionInterval: .seconds(3600),
            logger: NullGatewayLogger()
        )
        let recorder = GatewayUpdateRecorder()
        let stream = await coordinator.updates()
        let consumer = Task {
            for await update in stream { await recorder.append(update) }
        }

        await coordinator.start()
        let oldRequestStarted = await eventually { await roster.requestedTokens().contains("fixture-credential-1") }
        XCTAssertTrue(oldRequestStarted)

        await coordinator.suspend()
        let cancellationCount = await roster.cancellationCount()
        XCTAssertEqual(cancellationCount, 1)
        await coordinator.resume()

        let loadedNewSession = await eventually { await loader.loadCount() >= 2 }
        let newRequestStarted = await eventually { await roster.requestedTokens().contains("fixture-credential-2") }
        let newRosterPublished = await eventually { await recorder.contains(botId: "new-bot") }
        XCTAssertTrue(loadedNewSession)
        XCTAssertTrue(newRequestStarted)
        XCTAssertTrue(newRosterPublished)

        await roster.completeOldRequest()
        try? await Task.sleep(for: .milliseconds(40))
        let oldRosterPublished = await recorder.contains(botId: "old-bot")
        let requestedTokens = await roster.requestedTokens()
        XCTAssertFalse(oldRosterPublished)
        XCTAssertEqual(Array(requestedTokens.prefix(2)), ["fixture-credential-1", "fixture-credential-2"])

        await coordinator.stop()
        consumer.cancel()
    }

    func testStopCancelsPendingRosterRequestAndClosesUpdates() async {
        let loader = CountingSessionLoader()
        let roster = SleepWakeRosterClient()
        let coordinator = GatewayCoordinator(
            sessionLoader: loader,
            rosterClient: roster,
            eventStream: HoldingEventStream(),
            retrySleeper: ImmediateRetrySleeper(),
            rosterCorrectionInterval: .seconds(3600),
            logger: NullGatewayLogger()
        )
        await coordinator.start()
        let started = await eventually { await roster.requestedTokens().contains("fixture-credential-1") }
        XCTAssertTrue(started)

        await coordinator.stop()
        let cancellationCount = await roster.cancellationCount()
        XCTAssertEqual(cancellationCount, 1)
        await roster.completeOldRequest()
    }

    private static func record(
        id: String,
        isGroup: Bool = false,
        memberIds: [String] = [],
        shape: String? = "blob",
        color: String? = "blue",
        running: Bool = false
    ) -> GatewayAgentRecord {
        GatewayAgentRecord(
            id: id,
            name: id,
            isGroup: isGroup,
            memberIds: memberIds,
            avatarShape: shape,
            avatarColor: color,
            isRunning: running,
            isComposingMessage: false,
            hasAwaitingUserResponse: false,
            messageRevision: nil
        )
    }
}

private struct SlowTransport: GatewayHTTPTransport {
    func data(for _: URLRequest) async throws -> GatewayHTTPResponse {
        try await Task.sleep(for: .seconds(60))
        return GatewayHTTPResponse(data: Data("[]".utf8), statusCode: 200)
    }
}

private actor CancellationObservingTransport: GatewayHTTPTransport {
    private var starts = 0
    private var cancellations = 0

    func data(for _: URLRequest) async throws -> GatewayHTTPResponse {
        starts += 1
        return try await withTaskCancellationHandler {
            try await Task.sleep(for: .seconds(60))
            return GatewayHTTPResponse(data: Data("[]".utf8), statusCode: 200)
        } onCancel: {
            Task { await self.noteCancellation() }
        }
    }

    func startCount() -> Int { starts }
    func cancellationCount() -> Int { cancellations }

    private func noteCancellation() { cancellations += 1 }
}

private actor CountingSessionLoader: DesktopSessionLoading {
    private var count = 0

    func load() async throws -> DesktopSession {
        count += 1
        return DesktopSession(
            gatewayURL: URL(string: "https://example.invalid")!,
            bearerToken: "fixture-credential-\(count)"
        )
    }

    func loadCount() -> Int { count }
}

private actor UnauthorizedOnceRosterClient: GatewayRosterFetching {
    private var calls = 0
    private var cancellations = 0

    func listAgents(session _: DesktopSession) async throws -> [GatewayAgentRecord] {
        calls += 1
        if calls == 1 { throw GatewayFailure.unauthorized(operation: "listAgents") }
        return [
            GatewayAgentRecord(
                id: "bot-ok",
                name: "Ready",
                isGroup: false,
                memberIds: [],
                avatarShape: "blob",
                avatarColor: "blue",
                isRunning: false,
                isComposingMessage: false,
                hasAwaitingUserResponse: false,
                messageRevision: nil
            ),
        ]
    }

    func cancelPendingRequests() async { cancellations += 1 }
    func cancellationCount() -> Int { cancellations }
}

private struct HoldingEventStream: GatewayEventStreaming {
    func events(session _: DesktopSession) -> AsyncThrowingStream<GatewayEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.connected)
        }
    }
}

private actor AlwaysAvailableRosterClient: GatewayRosterFetching {
    func listAgents(session _: DesktopSession) async throws -> [GatewayAgentRecord] {
        [
            GatewayAgentRecord(
                id: "bot-ok",
                name: "Ready",
                isGroup: false,
                memberIds: [],
                avatarShape: "blob",
                avatarColor: "blue",
                isRunning: false,
                isComposingMessage: false,
                hasAwaitingUserResponse: false,
                messageRevision: nil
            ),
        ]
    }
}

private final class CountingClosingEventStream: GatewayEventStreaming, @unchecked Sendable {
    private let lock = NSLock()
    private var subscriptions = 0

    func events(session _: DesktopSession) -> AsyncThrowingStream<GatewayEvent, Error> {
        lock.withLock { subscriptions += 1 }
        return AsyncThrowingStream { continuation in
            continuation.yield(.connected)
            continuation.finish()
        }
    }

    func subscriptionCount() -> Int {
        lock.withLock { subscriptions }
    }
}

private struct ImmediateRetrySleeper: GatewayRetrySleeping {
    func sleep(for _: Duration) async throws { try Task.checkCancellation() }
}

private actor SleepWakeRosterClient: GatewayRosterFetching {
    private var tokens: [String] = []
    private var cancellations = 0
    private var oldContinuation: CheckedContinuation<[GatewayAgentRecord], Never>?

    func listAgents(session: DesktopSession) async throws -> [GatewayAgentRecord] {
        tokens.append(session.bearerToken)
        if session.bearerToken == "fixture-credential-1" {
            return await withCheckedContinuation { continuation in
                oldContinuation = continuation
            }
        }
        return [Self.record(id: "new-bot")]
    }

    func cancelPendingRequests() async {
        // Deliberately leave the first continuation pending. This models a
        // cancellation-resistant transport and proves generation filtering is
        // independent from the transport's cooperation.
        cancellations += 1
    }

    func completeOldRequest() {
        oldContinuation?.resume(returning: [Self.record(id: "old-bot")])
        oldContinuation = nil
    }

    func requestedTokens() -> [String] { tokens }
    func cancellationCount() -> Int { cancellations }

    private static func record(id: String) -> GatewayAgentRecord {
        GatewayAgentRecord(
            id: id,
            name: id,
            isGroup: false,
            memberIds: [],
            avatarShape: "blob",
            avatarColor: "blue",
            isRunning: false,
            isComposingMessage: false,
            hasAwaitingUserResponse: false,
            messageRevision: nil
        )
    }
}

private actor GatewayUpdateRecorder {
    private var updates: [GatewayUpdate] = []

    func append(_ update: GatewayUpdate) { updates.append(update) }

    func contains(botId: BotID) -> Bool {
        updates.contains {
            guard case .roster(let roster) = $0 else { return false }
            return roster.bots[botId] != nil
        }
    }
}

private func eventually(
    timeout: Duration = .seconds(1),
    condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}
