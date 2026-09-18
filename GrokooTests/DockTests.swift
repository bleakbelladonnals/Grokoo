import AppKit
import XCTest
@testable import Grokoo

@MainActor
final class DockTests: XCTestCase {
    private func item(_ id: String, revision: UInt64 = 1, state: DockPresentationState = .idle,
                      members: [DockMemberAppearance] = []) -> DockItemSnapshot {
        DockItemSnapshot(id: id, kind: id.hasPrefix("group:") ? .group : .bot,
            displayName: id, shape: .blob, color: .blue, members: members,
            state: state, revision: revision,
            routeURL: URL(string: "grokbot://app/v1/agent?id=\(id.dropFirst(id.hasPrefix("group:") ? 6 : 4))"),
            fallbackURL: URL(string: "grokbot://app/v1/open"))
    }

    private func controller() -> DockController {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DockTests-\(UUID().uuidString)")
        let controller = DockController(helperBundleURL: directory.appendingPathComponent("NoHelper.app"), runtimeDirectory: directory)
        controller.suspend() // Exercises persistence without putting test entries in the user's Dock.
        return controller
    }

    func testEnabledIdentitiesHaveNoFiveItemCapAndStableConfigurationPaths() throws {
        let controller = controller()
        defer { controller.shutdown() }
        let items = (0..<8).map { item("bot:b\($0)") } + [item("group:g")]
        controller.synchronize(items: items, reducedMotion: false)
        XCTAssertEqual(controller.items.count, 9)
        let paths = items.map { controller.configurationURL(for: $0.id) }
        XCTAssertEqual(Set(paths).count, 9)
        controller.synchronize(items: Array(items.reversed()), reducedMotion: false)
        XCTAssertEqual(paths, items.map { controller.configurationURL(for: $0.id) })
        for (item, path) in zip(items, paths) {
            let configuration = try JSONDecoder().decode(DockHelperConfiguration.self, from: Data(contentsOf: path))
            XCTAssertEqual(configuration.item, item)
            XCTAssertTrue(configuration.suspended)
        }
    }

    func testRevisionOnlyUpdatesDoNotRewriteFramesButMembershipChangesDo() throws {
        let controller = controller()
        defer { controller.shutdown() }
        let a = DockMemberAppearance(id: "a", shape: .cloud, color: .green)
        let b = DockMemberAppearance(id: "b", shape: .wedge, color: .orange)
        let first = item("group:g", members: [a])
        controller.synchronize(items: [first], reducedMotion: false)
        let path = controller.configurationURL(for: first.id)
        let originalData = try Data(contentsOf: path)
        controller.synchronize(items: [item(first.id, revision: 2, members: [a])], reducedMotion: false)
        XCTAssertEqual(try Data(contentsOf: path), originalData)
        controller.synchronize(items: [item(first.id, revision: 3, members: [a, b])], reducedMotion: false)
        let updated = try JSONDecoder().decode(DockHelperConfiguration.self, from: Data(contentsOf: path))
        XCTAssertEqual(updated.item.members, [a, b])
        XCTAssertEqual(updated.item.revision, 3)
        controller.synchronize(items: [first], reducedMotion: false)
        XCTAssertEqual(controller.items[0].revision, 3)
        XCTAssertEqual(controller.items[0].members, [a, b])
    }

    func testRemovingIdentityDeletesItsConfigurationAndShutdownCleansOnlySession() throws {
        let controller = controller()
        let a = item("bot:one"), b = item("bot:two")
        controller.synchronize(items: [a, b], reducedMotion: false)
        let removedURL = controller.configurationURL(for: a.id)
        controller.synchronize(items: [b], reducedMotion: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: removedURL.path))
        let configuration = try JSONDecoder().decode(DockHelperConfiguration.self,
            from: Data(contentsOf: controller.configurationURL(for: b.id)))
        XCTAssertTrue(configuration.reducedMotion)
        controller.shutdown()
        XCTAssertFalse(FileManager.default.fileExists(atPath: controller.runtimeDirectory.path))
        controller.synchronize(items: [a], reducedMotion: false)
        XCTAssertTrue(controller.items.isEmpty)
    }

    func testDoneAcknowledgementUsesCurrentIdentityAndState() async throws {
        let controller = controller()
        defer { controller.shutdown() }
        let done = item("group:g", state: .done)
        controller.synchronize(items: [done], reducedMotion: false)
        let configuration = try JSONDecoder().decode(DockHelperConfiguration.self,
            from: Data(contentsOf: controller.configurationURL(for: done.id)))
        var acknowledged: [String] = []
        controller.onAcknowledgeItem = { acknowledged.append($0) }
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(configuration.commandNotificationName), object: "acknowledge",
            userInfo: ["id": done.id], deliverImmediately: true)
        for _ in 0..<40 where acknowledged.isEmpty { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertEqual(acknowledged, [done.id])
        controller.synchronize(items: [item(done.id, revision: 2)], reducedMotion: false)
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(configuration.commandNotificationName), object: "acknowledge",
            userInfo: ["id": done.id], deliverImmediately: true)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(acknowledged, [done.id])
    }
}
