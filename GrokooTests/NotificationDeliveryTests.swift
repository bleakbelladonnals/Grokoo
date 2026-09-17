import Foundation
import UserNotifications
import XCTest
@testable import Grokoo

final class NotificationDeliveryTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 100)

    func testDoneWindowStartsAtFirstEventAndDoesNotDebounceLaterEvents() {
        var queue = NotificationEventQueue()
        queue.ingestDone(eventId: "r1", botId: "a", botName: "Atlas", at: start)
        queue.ingestDone(eventId: "r2", botId: "b", botName: "Nova", at: start.addingTimeInterval(2.99))
        XCTAssertEqual(queue.nextDoneDeadline, start.addingTimeInterval(3))
        XCTAssertNil(queue.flushDone(at: start.addingTimeInterval(2.999)))
        guard case .done(let ids, let payload) = queue.flushDone(at: start.addingTimeInterval(3)) else {
            return XCTFail("The first window must flush exactly at three seconds")
        }
        XCTAssertEqual(ids, ["r1", "r2"])
        XCTAssertEqual(payload.destination, .mainWindow)
        XCTAssertNil(queue.nextDoneDeadline)
        queue.ingestDone(eventId: "r3", botId: "c", botName: "Milo", at: start.addingTimeInterval(3.01))
        XCTAssertEqual(queue.nextDoneDeadline, start.addingTimeInterval(6.01))
    }

    func testAcknowledgedOrSupersededDoneIsRemovedBeforeDelivery() {
        var queue = NotificationEventQueue()
        queue.ingestDone(eventId: "r1", botId: "a", botName: "Atlas", at: start)
        queue.ingestDone(eventId: "r2", botId: "b", botName: "Nova", at: start.addingTimeInterval(1))
        queue.discardDone(botId: "a", at: start.addingTimeInterval(2))
        guard case .done(let ids, let payload) = queue.flushDone(at: start.addingTimeInterval(3)) else {
            return XCTFail("The remaining pending Bot must still notify")
        }
        XCTAssertEqual(ids, ["r2"])
        XCTAssertEqual(payload.title, "Nova 已完成任务")
        queue.ingestDone(eventId: "r1", botId: "a", botName: "Atlas", at: start.addingTimeInterval(4))
        XCTAssertNil(queue.nextDoneDeadline, "An obsolete event must not be replayed")
    }

    func testDiscardingWholeBatchAllowsANewWindow() {
        var queue = NotificationEventQueue()
        queue.ingestDone(eventId: "r1", botId: "a", botName: "Atlas", at: start)
        queue.discardDone(botId: "a", at: start.addingTimeInterval(1))
        XCTAssertNil(queue.nextDoneDeadline)
        queue.ingestDone(eventId: "r2", botId: "a", botName: "Atlas", at: start.addingTimeInterval(2))
        XCTAssertNil(queue.flushDone(at: start.addingTimeInterval(3)))
        XCTAssertNotNil(queue.flushDone(at: start.addingTimeInterval(5)))
    }

    func testDeduplicationSeparatesBotsAndEventKindsAndSurvivesRestore() throws {
        var queue = NotificationEventQueue()
        XCTAssertNotNil(queue.ingestBlocked(eventId: "same", botId: "a", botName: "Atlas", at: start))
        XCTAssertNotNil(queue.ingestBlocked(eventId: "same", botId: "b", botName: "Nova", at: start))
        queue.ingestDone(eventId: "same", botId: "a", botName: "Atlas", at: start)
        queue.ingestDone(eventId: "same", botId: "b", botName: "Nova", at: start)
        guard case .done(let ids, _) = queue.flushDone(at: start.addingTimeInterval(3)) else {
            return XCTFail("Equal revisions from different Bots must both be counted")
        }
        XCTAssertEqual(ids.count, 2)
        var restored = NotificationEventQueue(receipts: try JSONDecoder().decode(
            [NotificationReceipt].self, from: JSONEncoder().encode(queue.allReceipts)
        ))
        XCTAssertNil(restored.ingestBlocked(eventId: "same", botId: "a", botName: "Atlas"))
        restored.ingestDone(eventId: "same", botId: "b", botName: "Nova")
        XCTAssertNil(restored.nextDoneDeadline)
    }

    func testExistingReceiptWithoutBotIDStillPreventsReplay() throws {
        let old = Data(#"[{"eventId":"r1","kind":"done","sentAt":100}]"#.utf8)
        let receipts = try JSONDecoder().decode([NotificationReceipt].self, from: old)
        var queue = NotificationEventQueue(receipts: receipts)
        queue.ingestDone(eventId: "r1", botId: "a", botName: "Atlas", at: start)
        XCTAssertNil(queue.nextDoneDeadline)
    }

    func testSystemRequestContainsOnlySafeCopyAndOpaqueDestination() throws {
        let event = PresenceNotification.done(eventIds: ["anonymous-revision"], payload: .init(
            title: "Atlas 已完成任务", body: "点按返回 Grok Bot 查看结果。", destination: .bot("bot_123")
        ))
        let request = PresenceNotificationRequest.make(event)
        XCTAssertEqual(request.content.title, "Atlas 已完成任务")
        XCTAssertNil(request.content.sound)
        XCTAssertNil(request.content.badge)
        XCTAssertNil(request.trigger)
        XCTAssertEqual(request.content.userInfo.count, 1)
        XCTAssertEqual(PresenceNotificationRequest.destination(from: request.content.userInfo), .bot("bot_123"))
        XCTAssertEqual(request.identifier, PresenceNotificationRequest.make(event).identifier)
        XCTAssertFalse(request.identifier.contains("anonymous-revision"))
        let encodedTarget = try XCTUnwrap(request.content.userInfo.values.first as? Data)
        let targetText = String(decoding: encodedTarget, as: UTF8.self)
        for forbidden in ["grokbot://", "https://", "prompt", "fileName", "groupTopic", "errorDetail", "token"] {
            XCTAssertFalse(targetText.contains(forbidden))
        }
    }

    func testMissingOrInvalidNotificationDestinationFallsBackToMainWindow() {
        XCTAssertEqual(PresenceNotificationRequest.destination(from: [:]), .mainWindow)
        XCTAssertEqual(PresenceNotificationRequest.destination(from: ["grokling.destination.v1": Data("bad".utf8)]), .mainWindow)
    }

    func testOnlyVerifiedGrokBotRoutesAreConstructed() {
        XCTAssertEqual(GrokBotNotificationRoute.bundleIdentifier, "com.anysphere.sand")
        XCTAssertEqual(GrokBotNotificationRoute.url(for: .bot("a_B-123")).absoluteString, "grokbot://app/v1/agent?id=a_B-123")
        for destination in [NotificationDestination.mainWindow, .task("opaque-task"), .bot(""), .bot("a&other=value"), .bot("https://example.com"), .bot(String(repeating: "a", count: 129))] {
            XCTAssertEqual(GrokBotNotificationRoute.url(for: destination).absoluteString, "grokbot://app/v1/open")
        }
    }

    @MainActor
    func testDeliveryDoesNotPromptWithoutExplicitPermissionAction() async {
        let center = StubNotificationCenter()
        let service = MacOSNotificationService(center: center, router: StubGrokBotRouter())
        let event = makeEvent()
        let needsPermission = await service.deliver(event)
        XCTAssertEqual(needsPermission, .permissionRequired)
        XCTAssertEqual(center.permissionRequests, 0)
        XCTAssertTrue(center.requests.isEmpty)
        center.status = .denied
        let denied = await service.deliver(event)
        XCTAssertEqual(denied, .denied)
        await service.requestAuthorization()
        XCTAssertEqual(center.permissionRequests, 0)
        XCTAssertTrue(center.requests.isEmpty)
    }

    @MainActor
    func testPermissionActionAndSystemSubmissionReflectActualResults() async {
        let center = StubNotificationCenter()
        let service = MacOSNotificationService(center: center, router: StubGrokBotRouter())
        var observed: [NotificationAuthorizationState] = []
        service.onAuthorizationChange = { observed.append($0) }
        await service.requestAuthorization()
        XCTAssertEqual(center.permissionRequests, 1)
        XCTAssertEqual(center.requestedOptions, [.alert])
        XCTAssertEqual(service.authorizationStatus, .authorized)
        XCTAssertEqual(observed, [.notDetermined, .authorized])
        let submitted = await service.deliver(makeEvent())
        XCTAssertEqual(submitted, .submitted)
        XCTAssertEqual(center.requests.count, 1)
        center.failSubmission = true
        let failed = await service.deliver(makeEvent())
        XCTAssertEqual(failed, .failed)
        XCTAssertEqual(service.lastDeliveryOutcome, .failed)
    }

    @MainActor
    func testPermissionFailureIsVisibleAndNoNotificationIsSubmitted() async {
        let center = StubNotificationCenter()
        center.failPermission = true
        let service = MacOSNotificationService(center: center, router: StubGrokBotRouter())
        await service.requestAuthorization()
        XCTAssertEqual(service.authorizationStatus, .unavailable)
        XCTAssertTrue(center.requests.isEmpty)
    }

    @MainActor
    func testPermissionChangesAreReadAgainBeforeDelivery() async {
        let center = StubNotificationCenter()
        center.status = .authorized
        let service = MacOSNotificationService(center: center, router: StubGrokBotRouter())
        await service.refreshAuthorization()
        center.status = .denied
        let outcome = await service.deliver(makeEvent())
        XCTAssertEqual(outcome, .denied)
        XCTAssertEqual(service.authorizationStatus, .denied)
        XCTAssertTrue(center.requests.isEmpty)
    }

    @MainActor
    func testDecodedClickTargetIsPassedToRouterAndReportsMissingApp() async {
        let router = StubGrokBotRouter()
        let service = MacOSNotificationService(center: StubNotificationCenter(), router: router)
        let request = PresenceNotificationRequest.make(makeEvent())
        let opened = await service.openDestination(PresenceNotificationRequest.destination(from: request.content.userInfo))
        XCTAssertTrue(opened)
        XCTAssertEqual(router.destinations, [.bot("a")])
        router.canOpen = false
        let unavailable = await service.openDestination(.mainWindow)
        XCTAssertFalse(unavailable)
        XCTAssertEqual(router.destinations.last, .mainWindow)
    }

    private func makeEvent() -> PresenceNotification {
        .done(eventIds: ["r1"], payload: .init(
            title: "Atlas 已完成任务", body: "点按返回 Grok Bot 查看结果。", destination: .bot("a")
        ))
    }
}

@MainActor
private final class StubNotificationCenter: NotificationCenterClient {
    weak var delegate: (any UNUserNotificationCenterDelegate)?
    var status: UNAuthorizationStatus = .notDetermined
    var permissionRequests = 0
    var requestedOptions: UNAuthorizationOptions?
    var requests: [UNNotificationRequest] = []
    var failPermission = false
    var failSubmission = false

    func authorizationStatus() async -> UNAuthorizationStatus { status }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        permissionRequests += 1
        requestedOptions = options
        if failPermission { throw URLError(.unknown) }
        status = .authorized
        return true
    }

    func add(_ request: UNNotificationRequest) async throws {
        if failSubmission { throw URLError(.unknown) }
        requests.append(request)
    }
}

@MainActor
private final class StubGrokBotRouter: GrokBotNotificationOpening {
    var destinations: [NotificationDestination] = []
    var canOpen = true

    func open(_ destination: NotificationDestination) async -> Bool {
        destinations.append(destination)
        return canOpen
    }
}
