import AppKit
import XCTest
@testable import Grokoo

final class DockSettingsTests: XCTestCase {
    @MainActor
    func testDockDefaultsOffAndRestoresIndependentlyOfSchemaTwoSettings() throws {
        let suite = "DockSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let storageKey = "dock-settings"
        let store = SettingsStore(defaults: defaults, storageKey: storageKey)
        XCTAssertTrue(store.dockEnabledIDs.isEmpty)
        store.setDockEnabled(true, for: "bot:one")
        XCTAssertFalse(store.hasPersistedConfiguration, "A Dock choice must not skip first-time desktop setup")
        store.merge(botIDs: ["one", "two"])
        store.setMBTI(.infp, for: "two")
        let desktopData = try XCTUnwrap(defaults.data(forKey: storageKey))

        store.setDockEnabled(true, for: "group:pair")
        XCTAssertEqual(defaults.data(forKey: storageKey), desktopData)
        let restored = SettingsStore(defaults: defaults, storageKey: storageKey)
        XCTAssertEqual(restored.dockEnabledIDs, ["bot:one", "group:pair"])
        XCTAssertEqual(restored.configurations, store.configurations)
        let snapshot = try JSONDecoder().decode(SettingsSnapshot.self, from: desktopData)
        XCTAssertEqual(snapshot.schemaVersion, 2)

        restored.setDockEnabled(false, for: "bot:one")
        XCTAssertEqual(SettingsStore(defaults: defaults, storageKey: storageKey).dockEnabledIDs, ["group:pair"])
        XCTAssertEqual(defaults.data(forKey: storageKey), desktopData)
    }

    @MainActor
    func testDockHasNoDesktopLimitAndVisibilityChoicesStayIndependent() {
        let suite = "DockSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        let botIDs = (1...9).map { "bot-\($0)" }
        store.merge(botIDs: botIDs)
        let desktopBefore = store.configurations
        for id in botIDs { store.setDockEnabled(true, for: "bot:\(id)") }
        store.setDockEnabled(true, for: "group:team")
        XCTAssertEqual(store.dockEnabledIDs.count, 10)
        XCTAssertEqual(store.configurations, desktopBefore)
        XCTAssertFalse(store.setVisibility(true, for: "bot-7"))

        store.setVisibility(false, for: "bot-1")
        XCTAssertTrue(store.dockEnabledIDs.contains("bot:bot-1"))
        let desktopAfterHide = store.configurations
        store.setDockEnabled(false, for: "bot:bot-2")
        XCTAssertEqual(store.configurations, desktopAfterHide)
        XCTAssertTrue(store.configuration(for: "bot-2")!.isVisible)
        XCTAssertTrue(store.dockEnabledIDs.contains("group:team"))
    }

    @MainActor
    func testDockItemsAndNativeKeyboardActivationIncludeGroups() {
        let suite = "DockSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        store.merge(botIDs: ["one"])
        let viewModel = SettingsViewModel(store: store)
        viewModel.update(bots: [SettingsBot(id: "one", name: "Ada")], connectionState: .connected)
        let bot = SettingsDockItem(id: "bot:one", name: "Ada", isGroup: false)
        let group = SettingsDockItem(id: "group:team", name: "产品组", isGroup: true)
        viewModel.updateDockItems([bot, group, bot])
        XCTAssertEqual(viewModel.dockItems, [bot, group])
        XCTAssertEqual(Array(viewModel.keyboardOrder.suffix(2)), [.dock(bot.id), .dock(group.id)])
        XCTAssertTrue(viewModel.dockEnabledIDs.isEmpty)

        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let toggle = SettingsFocusSwitch()
        toggle.onFocus = { viewModel.keyboardFocusedControl = .dock(group.id) }
        window.contentView?.addSubview(toggle)
        viewModel.registerKeyboardControl(toggle, for: .dock(group.id))
        XCTAssertTrue(viewModel.focusNativeControl(.dock(group.id)))
        XCTAssertTrue(window.firstResponder === toggle)
        XCTAssertEqual(viewModel.keyboardFocusedControl, .dock(group.id))
        XCTAssertTrue(viewModel.handleKeyboardCommand(.activate))
        XCTAssertEqual(store.dockEnabledIDs, [group.id])
        XCTAssertEqual(viewModel.dockEnabledIDs, [group.id])
        XCTAssertTrue(viewModel.accessibilityMessage.contains("产品组"))
        XCTAssertTrue(store.configuration(for: "one")!.isVisible)
        XCTAssertTrue(viewModel.handleKeyboardCommand(.activate))
        XCTAssertTrue(store.dockEnabledIDs.isEmpty)

        store.setDockEnabled(true, for: bot.id)
        XCTAssertEqual(viewModel.dockEnabledIDs, [bot.id])
        viewModel.updateDockItems([])
        XCTAssertFalse(viewModel.keyboardOrder.contains(.dock(group.id)))
        XCTAssertFalse(viewModel.handleKeyboardCommand(.activate))
        XCTAssertEqual(store.dockEnabledIDs, [bot.id], "Roster refresh must preserve saved Dock choices")
    }
}
