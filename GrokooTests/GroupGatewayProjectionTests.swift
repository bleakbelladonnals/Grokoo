import Foundation
import XCTest
@testable import Grokoo

@MainActor
final class GroupGatewayProjectionTests: XCTestCase {
    func testRosterPreservesGroupNameAndStructuredRuntime() throws {
        let records = try Self.records()
        let snapshot = BotRosterStore.normalize(records)
        let group = try XCTUnwrap(snapshot.groups["group"])

        XCTAssertEqual(group.name, "Research team")
        XCTAssertEqual(group.memberIds, ["bot"])
        XCTAssertEqual(snapshot.botOrder, ["bot"])
        XCTAssertNil(snapshot.bots["group"])
        XCTAssertEqual(group.runtime, GatewayPresenceAdapter.runtime(from: records[1]))
        XCTAssertTrue(group.runtime.isRunning)
        XCTAssertTrue(group.runtime.isThinking)
        XCTAssertEqual(group.runtime.awaitingUserResponse, .present)
        XCTAssertEqual(group.runtime.waitingEvent, StructuredEventRef("waiting:group:revision-1"))
        XCTAssertEqual(group.runtime.messageRevision, "revision-1")
        XCTAssertNil(group.runtime.blockedEvent)
        XCTAssertNil(group.runtime.taskRevision)
    }

    func testPartialGroupEventsKeepOmittedFieldsAndClearExplicitFields() async throws {
        let store = BotRosterStore()
        await store.replace(with: try Self.records())

        var snapshot = await store.apply(try Self.patch(#"{"agent":{"id":"group","name":"Renamed team"}}"#))
        let renamed = try XCTUnwrap(snapshot.groups["group"])
        XCTAssertEqual(renamed.name, "Renamed team")
        XCTAssertEqual(renamed.memberIds, ["bot"])
        XCTAssertTrue(renamed.runtime.isRunning)
        XCTAssertTrue(renamed.runtime.isThinking)
        XCTAssertEqual(renamed.runtime.awaitingUserResponse, .present)
        XCTAssertEqual(renamed.runtime.messageRevision, "revision-1")

        snapshot = await store.apply(try Self.patch(#"{"agent":{"id":"group","isRunning":false}}"#))
        var group = try XCTUnwrap(snapshot.groups["group"])
        XCTAssertEqual(group.name, "Renamed team")
        XCTAssertFalse(group.runtime.isRunning)
        XCTAssertTrue(group.runtime.isThinking)
        XCTAssertTrue(group.isRunning)
        XCTAssertEqual(group.runtime.waitingEvent, renamed.runtime.waitingEvent)

        snapshot = await store.apply(try Self.patch(#"{"agent":{"id":"group","isComposingMessage":false,"awaitingUserResponse":null},"messageRevision":"revision-2"}"#))
        group = try XCTUnwrap(snapshot.groups["group"])
        XCTAssertFalse(group.runtime.isRunning)
        XCTAssertFalse(group.runtime.isThinking)
        XCTAssertFalse(group.isRunning)
        XCTAssertNil(group.runtime.awaitingUserResponse)
        XCTAssertNil(group.runtime.waitingEvent)
        XCTAssertEqual(group.runtime.messageRevision, "revision-2")
        XCTAssertEqual(group.name, "Renamed team")
        XCTAssertEqual(group.memberIds, ["bot"])
        XCTAssertNil(snapshot.bots["group"])

        snapshot = await store.apply(try Self.patch(#"{"agent":{"id":"group","awaitingUserResponse":true}}"#))
        group = try XCTUnwrap(snapshot.groups["group"])
        XCTAssertEqual(group.runtime.awaitingUserResponse, .present)
        XCTAssertNotNil(group.runtime.waitingEvent)
        XCTAssertFalse(group.isRunning)
        XCTAssertEqual(group.runtime.messageRevision, "revision-2")
    }

    func testMessageMetadataUpdatesGroupRevisionWithoutReplacingRuntime() async throws {
        let store = BotRosterStore()
        let initial = await store.replace(with: try Self.records())
        let event = try XCTUnwrap(GatewayEventDecoder.decode(
            eventName: "message-metadata",
            data: Data(#"{"agent":{"id":"group"},"messageRevision":"revision-2","content":"ignored content"}"#.utf8)
        ))
        var snapshot = await store.apply(event)
        var expected = try XCTUnwrap(initial.groups["group"])
        expected.runtime.messageRevision = "revision-2"
        XCTAssertEqual(snapshot.groups["group"], expected)
        XCTAssertEqual(snapshot.bots, initial.bots)

        snapshot = await store.apply(try Self.patch(#"{"agent":{"id":"group","name":"Updated team"}}"#))
        XCTAssertEqual(snapshot.groups["group"]?.runtime.messageRevision, "revision-2")
        XCTAssertEqual(snapshot.groups["group"]?.name, "Updated team")
        snapshot = await store.apply(.messageMetadata(botId: "bot", revision: "bot-revision"))
        XCTAssertEqual(snapshot.bots["bot"]?.runtime.messageRevision, "bot-revision")
        XCTAssertEqual(snapshot.groups["group"]?.runtime.messageRevision, "revision-2")
    }

    func testThinkingAndWaitingKeepExistingGroupBarrierSemantics() async throws {
        let store = BotRosterStore()
        await store.replace(with: try Self.records())
        var snapshot = await store.apply(try Self.patch(#"{"agent":{"id":"group","isRunning":false,"awaitingUserResponse":null}}"#))
        var tracker = GroupActivityTracker()
        var activity = tracker.update(roster: snapshot, visibleBotIds: ["bot"])
        XCTAssertEqual(activity.assignments["bot"]?.groupId, "group")
        XCTAssertEqual(activity.assignments["bot"]?.mode, .resting)
        XCTAssertEqual(activity.sessions["group"]?.groupRunning, true)

        snapshot = await store.apply(try Self.patch(#"{"agent":{"id":"group","isComposingMessage":false,"awaitingUserResponse":true}}"#))
        XCTAssertEqual(snapshot.groups["group"]?.runtime.awaitingUserResponse, .present)
        activity = tracker.update(roster: snapshot, visibleBotIds: ["bot"])
        XCTAssertNil(activity.sessions["group"])
        XCTAssertNil(activity.assignments["bot"])
    }

    func testLegacyGroupInitializerAndRunningMutationRemainCompatible() {
        var group = GroupRuntime(id: "group", memberIds: ["bot"], isRunning: true)
        XCTAssertEqual(group.name, "group")
        XCTAssertTrue(group.runtime.isRunning)
        XCTAssertFalse(group.runtime.isThinking)
        group.runtime.isThinking = true
        group.runtime.awaitingUserResponse = .present
        group.isRunning = false
        XCTAssertFalse(group.isRunning)
        XCTAssertFalse(group.runtime.isRunning)
        XCTAssertFalse(group.runtime.isThinking)
        XCTAssertEqual(group.runtime.awaitingUserResponse, .present)
    }

    private static func records() throws -> [GatewayAgentRecord] {
        try GatewayAgentDecoder.decodeList(Data(#"[{"id":"bot","name":"Ada"},{"id":"group","name":"Research team","isGroup":true,"memberIds":["bot","missing","bot"],"isRunning":true,"isComposingMessage":true,"awaitingUserResponse":true,"messageRevision":"revision-1","content":"blocked content is ignored"}]"#.utf8))
    }

    private static func patch(_ json: String) throws -> GatewayEvent {
        try XCTUnwrap(GatewayEventDecoder.decode(eventName: "agent-upserted", data: Data(json.utf8)))
    }
}
