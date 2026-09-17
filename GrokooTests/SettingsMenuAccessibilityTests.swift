import AppKit
import XCTest
@testable import Grokoo

final class SettingsMenuAccessibilityTests: XCTestCase {
    @MainActor
    func testNativeKeyboardControlsFocusAndActivationDoNotDependOnSystemKeyboardNavigation() {
        let suite = "SettingsMenuAccessibilityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        store.merge(botIDs: ["one", "two"])
        let viewModel = SettingsViewModel(store: store)
        viewModel.update(bots: [SettingsBot(id: "one", name: "One"), SettingsBot(id: "two", name: "Two")], connectionState: .connected)
        XCTAssertFalse(viewModel.keyboardOrder.contains(.moveUp("one")))
        XCTAssertFalse(viewModel.keyboardOrder.contains(.moveDown("two")))

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        let controls: [NSControl] = [SettingsFocusSwitch(), SettingsFocusPopUpButton(), SettingsFocusButton()]
        for control in controls {
            window.contentView?.addSubview(control)
            XCTAssertTrue(control.acceptsFirstResponder)
            XCTAssertTrue(window.makeFirstResponder(control))
            XCTAssertTrue(window.firstResponder === control)
        }
        let disabled = SettingsFocusButton()
        disabled.isEnabled = false
        XCTAssertFalse(disabled.acceptsFirstResponder)

        viewModel.keyboardFocusedControl = .visibility("one")
        XCTAssertTrue(viewModel.handleKeyboardCommand(.activate))
        XCTAssertFalse(store.configuration(for: "one")!.isVisible)
        viewModel.keyboardFocusedControl = .moveDown("one")
        XCTAssertTrue(viewModel.handleKeyboardCommand(.activate))
        XCTAssertEqual(viewModel.bots.map(\.id), ["two", "one"])
        XCTAssertEqual(viewModel.keyboardFocusedControl, .moveUp("one"))
        viewModel.keyboardFocusedControl = .mbti("one")
        XCTAssertFalse(viewModel.handleKeyboardCommand(.activate))
        XCTAssertNil(store.configuration(for: "one")!.mbti)
    }

    @MainActor
    func testSettingsListFollowsPersistedOrderAfterReorderHideAndRosterRefresh() {
        let suite = "SettingsMenuAccessibilityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        store.merge(botIDs: ["one", "two", "three"])
        let viewModel = SettingsViewModel(store: store)
        let roster = ["one", "two", "three"].map { SettingsBot(id: $0, name: $0) }
        viewModel.update(bots: roster, connectionState: .connected)

        viewModel.move(botId: "three", delta: -1)
        XCTAssertEqual(viewModel.bots.map(\.id), ["one", "three", "two"])
        XCTAssertTrue(viewModel.accessibilityMessage.contains("第 2 位"))
        viewModel.setVisibility(false, for: "three")
        XCTAssertEqual(viewModel.bots.map(\.id), ["one", "three", "two"])
        XCTAssertTrue(viewModel.accessibilityMessage.contains("已隐藏"))
        viewModel.update(bots: Array(roster.reversed()), connectionState: .connected)
        XCTAssertEqual(viewModel.bots.map(\.id), ["one", "three", "two"])

        store.move(botId: "two", to: 0)
        XCTAssertEqual(viewModel.bots.map(\.id), ["two", "one", "three"])
        XCTAssertFalse(store.configuration(for: "three")!.isVisible)
    }

    @MainActor
    func testVisibilityLimitAndRetryHaveTextFeedbackAndPreserveSettings() {
        let suite = "SettingsMenuAccessibilityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        let roster = (1...7).map { SettingsBot(id: "bot-\($0)", name: "Bot \($0)") }
        store.merge(botIDs: roster.map(\.id))
        let viewModel = SettingsViewModel(store: store)
        viewModel.update(bots: roster, connectionState: .offline)
        viewModel.setVisibility(true, for: "bot-7")
        XCTAssertTrue(viewModel.visibilityLimitReached)
        XCTAssertTrue(viewModel.accessibilityMessage.contains("请先隐藏一只"))
        XCTAssertFalse(store.configuration(for: "bot-7")!.isVisible)

        viewModel.setMBTI(.intj, for: "bot-2")
        XCTAssertTrue(viewModel.accessibilityMessage.contains("INTJ"))
        let previous = store.configurations
        var retries = 0
        viewModel.onRetry = { retries += 1 }
        viewModel.retry()
        viewModel.retry()
        XCTAssertEqual(retries, 1)
        XCTAssertEqual(viewModel.connectionState, .connecting)
        XCTAssertEqual(store.configurations, previous)
        XCTAssertEqual(viewModel.accessibilityMessage, "正在重新连接 Grok Bot。")
    }

    @MainActor
    func testNotificationPermissionIsExplainedWithoutColor() {
        let suite = "SettingsMenuAccessibilityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let viewModel = SettingsViewModel(store: SettingsStore(defaults: defaults))
        viewModel.updateNotificationPermission(.denied)
        XCTAssertEqual(viewModel.notificationPermissionTitle, "完成通知未获允许")
        XCTAssertTrue(viewModel.notificationPermissionGuidance.contains("系统设置"))
        XCTAssertTrue(viewModel.accessibilityMessage.contains("未获允许"))
        viewModel.updateNotificationPermission(.authorized)
        XCTAssertEqual(viewModel.notificationPermissionTitle, "完成通知已允许")
    }

    @MainActor
    func testMenuExposesReadableOfflineSummaryAndOperableDoneActions() throws {
        var focused = false
        var acknowledged: [BotID] = []
        var acknowledgedAll = false
        let controller = MenuBarController(
            onShowAll: {}, onHideAll: {}, onOpenSettings: {}, onQuit: {},
            onFocusWorkspace: { focused = true },
            onAcknowledgeDone: { acknowledged.append($0) },
            onAcknowledgeAllDone: { acknowledgedAll = true }
        )
        defer { controller.shutdown() }
        let menu = try XCTUnwrap(controller.menu)
        let focusIndex = try XCTUnwrap(menu.items.firstIndex { $0.title == "进入工作区" })
        XCTAssertEqual(menu.items[focusIndex].keyEquivalentModifierMask, [.command, .option])
        menu.performActionForItem(at: focusIndex)
        XCTAssertTrue(focused)

        controller.update(aggregate: PresenceAggregate(
            activeBotCount: nil, attentionPresent: true, waitingCount: 0, blockedCount: 0, pendingDoneCount: 2
        ))
        XCTAssertTrue(controller.accessibilitySummary.contains("暂不可用"))
        XCTAssertTrue(controller.accessibilitySummary.contains("待收起 2"))
        controller.updatePendingDone(bots: [
            SettingsBot(id: "ada", name: "Ada"), SettingsBot(id: "lin", name: "Lin"),
            SettingsBot(id: "ada", name: "Ada")
        ])
        let done = try XCTUnwrap(menu.items.first { $0.title == "待收起结果（2）" }?.submenu)
        done.performActionForItem(at: 0)
        XCTAssertEqual(acknowledged, ["ada"])
        done.performActionForItem(at: done.items.count - 1)
        XCTAssertTrue(acknowledgedAll)

        controller.updatePendingDone(bots: [SettingsBot(id: "lin", name: "Lin")])
        let single = try XCTUnwrap(menu.items.first { $0.title == "待收起结果（1）" }?.submenu)
        XCTAssertEqual(single.items.map(\.title), ["收起 Lin"])
        controller.updatePendingDone(bots: [])
        XCTAssertFalse(controller.menuItemTitles.contains { $0.hasPrefix("待收起结果") })
    }

    #if DEBUG
    @MainActor
    func testExperienceMenuUsesCatalogAndRunsSelectionCallback() throws {
        var selected: String?
        let controller = MenuBarController(onShowAll: {}, onHideAll: {}, onOpenSettings: {}, onQuit: {})
        defer { controller.shutdown() }
        controller.enableExperienceChecks(selectedFixtureID: "solo-6") { selected = $0 }
        let submenu = try XCTUnwrap(controller.menu?.items.first { $0.title == "Experience Check" }?.submenu)
        XCTAssertEqual(submenu.items.compactMap { $0.representedObject as? String }, ExperienceFixtureCatalog.loadBundled().map(\.id))
        let selectedIndex = try XCTUnwrap(submenu.items.firstIndex { ($0.representedObject as? String) == "solo-6" })
        XCTAssertEqual(submenu.items[selectedIndex].state, .on)
        submenu.performActionForItem(at: 0)
        XCTAssertEqual(selected, ExperienceFixtureCatalog.loadBundled()[0].id)
        XCTAssertEqual(submenu.items[0].state, .on)
    }
    #endif

    @MainActor
    func testApplicationMenuMirrorsWorkspaceCommandsAndPreservesExistingMenus() throws {
        let originalMenu = NSApp.mainMenu
        let mainMenu = NSMenu()
        let existing = NSMenuItem(title: "Existing", action: nil, keyEquivalent: "")
        mainMenu.addItem(existing)
        NSApp.mainMenu = mainMenu
        defer { NSApp.mainMenu = originalMenu }
        var focused = false
        var acknowledged: BotID?
        let controller = MenuBarController(
            onShowAll: {}, onHideAll: {}, onOpenSettings: {}, onQuit: {},
            onFocusWorkspace: { focused = true },
            onAcknowledgeDone: { acknowledged = $0 }
        )
        defer { controller.shutdown() }
        let workspace = try XCTUnwrap(mainMenu.items.first { $0.title == "工作区" })
        let commands = try XCTUnwrap(workspace.submenu)
        let focusIndex = try XCTUnwrap(commands.items.firstIndex { $0.title == "进入工作区" })
        XCTAssertEqual(commands.items[focusIndex].keyEquivalent, "w")
        XCTAssertEqual(commands.items[focusIndex].keyEquivalentModifierMask, [.command, .option])
        commands.performActionForItem(at: focusIndex)
        XCTAssertTrue(focused)
        controller.updatePendingDone(bots: [SettingsBot(id: "ada", name: "Ada")])
        let done = try XCTUnwrap(workspace.submenu?.items.first { $0.title == "待收起结果（1）" }?.submenu)
        done.performActionForItem(at: 0)
        XCTAssertEqual(acknowledged, "ada")
        XCTAssertTrue(mainMenu.items.contains { $0 === existing })

        let rebuiltMainMenu = NSMenu()
        let rebuiltExisting = NSMenuItem(title: "Rebuilt", action: nil, keyEquivalent: "")
        rebuiltMainMenu.addItem(rebuiltExisting)
        NSApp.mainMenu = rebuiltMainMenu
        NotificationCenter.default.post(name: NSApplication.didUpdateNotification, object: NSApp)
        XCTAssertTrue(rebuiltMainMenu.items.contains { $0 === workspace })
        let installedSubmenu = workspace.submenu
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        XCTAssertTrue(workspace.submenu === installedSubmenu)
        XCTAssertTrue(rebuiltMainMenu.items.contains { $0 === rebuiltExisting })

        controller.shutdown()
        XCTAssertEqual(mainMenu.items, [existing])
        XCTAssertEqual(rebuiltMainMenu.items, [rebuiltExisting])
    }
}
