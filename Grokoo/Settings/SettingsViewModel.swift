import Combine
import AppKit
import Foundation

enum SettingsKeyboardCommand {
    case moveFocus(backwards: Bool)
    case activate
}

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published private(set) var bots: [SettingsBot] = []
    @Published private(set) var dockItems: [SettingsDockItem] = []
    @Published private(set) var dockEnabledIDs: Set<String> = []
    @Published private(set) var connectionState: SettingsConnectionState = .connecting
    @Published private(set) var visibilityLimitReached = false
    @Published private(set) var accessibilityMessage = ""
    @Published private(set) var notificationPermission: NotificationAuthorizationState = .notDetermined
    @Published private(set) var keyboardFocusRequest: UInt64 = 0
    let keyboardCommands = PassthroughSubject<SettingsKeyboardCommand, Never>()
    @Published var keyboardFocusedControl: SettingsControl?
    @Published var dockErrorMessage: String?
    private final class WeakKeyboardControl {
        weak var value: NSControl?
        init(_ value: NSControl) { self.value = value }
    }
    private var keyboardControls: [SettingsControl: WeakKeyboardControl] = [:]

    let store: SettingsStore
    var onRetry: (() -> Void)?
    var onRequestNotificationPermission: (() -> Void)?
    var onOpenNotificationSettings: (() -> Void)?
    private var roster: [SettingsBot] = []
    private var configurationsCancellable: AnyCancellable?
    private var dockCancellable: AnyCancellable?

    init(store: SettingsStore) {
        self.store = store
        configurationsCancellable = store.$configurations.sink { [weak self] configurations in
            self?.refreshOrder(configurations: configurations)
        }
        dockCancellable = store.$dockEnabledIDs.sink { [weak self] enabledIDs in
            self?.dockEnabledIDs = enabledIDs
        }
    }

    func update(bots: [SettingsBot], connectionState: SettingsConnectionState) {
        roster = bots
        refreshOrder(configurations: store.configurations)
        let connectionChanged = self.connectionState != connectionState
        self.connectionState = connectionState
        visibilityLimitReached = false
        if connectionChanged { announce(connectionState.title) }
    }

    func setVisibility(_ isVisible: Bool, for botId: BotID) {
        visibilityLimitReached = !store.setVisibility(isVisible, for: botId)
        if visibilityLimitReached {
            announce("已显示 6 只桌宠。请先隐藏一只，再显示 \(name(for: botId))。")
        } else {
            announce("\(name(for: botId)) 已\(isVisible ? "显示" : "隐藏")。已显示 \(visibleCount) 只桌宠。")
        }
    }

    func updateDockItems(_ items: [SettingsDockItem]) {
        var seen = Set<String>()
        let uniqueItems = items.filter { seen.insert($0.id).inserted }
        if dockItems != uniqueItems { dockItems = uniqueItems }
    }

    func setDockEnabled(_ enabled: Bool, for itemID: String) {
        guard let item = dockItems.first(where: { $0.id == itemID }) else { return }
        dockErrorMessage = nil
        store.setDockEnabled(enabled, for: itemID)
        announce("\(item.name) 的 Dock 入口已\(enabled ? "开启" : "关闭")。")
    }

    func setMBTI(_ mbti: MBTIType?, for botId: BotID) {
        store.setMBTI(mbti, for: botId)
        announce("\(name(for: botId)) 的 MBTI 已设为 \(mbti?.rawValue.uppercased() ?? "中性，无配件")。")
    }

    func move(botId: BotID, delta: Int) {
        let previousOrder = store.configuration(for: botId)?.globalOrder
        store.move(botId: botId, by: delta)
        guard let order = store.configuration(for: botId)?.globalOrder, order != previousOrder else { return }
        announce("\(name(for: botId)) 已移到第 \(order + 1) 位，共 \(bots.count) 只 Bot。")
    }

    var visibleCount: Int { store.configurations.count(where: \.isVisible) }

    var keyboardOrder: [SettingsControl] {
        var controls: [SettingsControl] = []
        if connectionState.canRetry { controls.append(.retry) }
        if [.notDetermined, .unavailable, .denied].contains(notificationPermission) { controls.append(.notifications) }
        for bot in bots {
            guard let configuration = store.configuration(for: bot.id) else { continue }
            controls += [.visibility(bot.id), .mbti(bot.id)]
            if configuration.globalOrder > 0 { controls.append(.moveUp(bot.id)) }
            if configuration.globalOrder < bots.count - 1 { controls.append(.moveDown(bot.id)) }
        }
        controls += dockItems.map { .dock($0.id) }
        return controls
    }

    func requestKeyboardFocus() { keyboardFocusRequest &+= 1 }

    func registerKeyboardControl(_ native: NSControl, for control: SettingsControl) {
        keyboardControls[control] = WeakKeyboardControl(native)
    }

    func focusNativeControl(_ control: SettingsControl) -> Bool {
        guard let native = keyboardControls[control]?.value, let window = native.window else { return false }
        return window.makeFirstResponder(native)
    }

    @discardableResult
    func handleKeyboardCommand(_ command: SettingsKeyboardCommand) -> Bool {
        if case .activate = command {
            guard let control = keyboardFocusedControl else { return false }
            switch control {
            case .mbti: return false
            case .retry:
                retry()
                keyboardFocusedControl = keyboardOrder.first
            case .notifications:
                if notificationPermission == .denied { onOpenNotificationSettings?() }
                else { onRequestNotificationPermission?() }
            case .visibility(let id):
                guard let configuration = store.configuration(for: id) else { return false }
                setVisibility(!configuration.isVisible, for: id)
            case .dock(let id):
                guard dockItems.contains(where: { $0.id == id }) else { return false }
                setDockEnabled(!dockEnabledIDs.contains(id), for: id)
            case .moveUp(let id):
                move(botId: id, delta: -1)
                if !keyboardOrder.contains(control) { keyboardFocusedControl = .moveDown(id) }
            case .moveDown(let id):
                move(botId: id, delta: 1)
                if !keyboardOrder.contains(control) { keyboardFocusedControl = .moveUp(id) }
            }
        }
        keyboardCommands.send(command)
        return true
    }

    func updateNotificationPermission(_ state: NotificationAuthorizationState) {
        let changed = notificationPermission != state
        notificationPermission = state
        if changed { announce(notificationPermissionTitle) }
    }

    var notificationPermissionTitle: String {
        switch notificationPermission {
        case .notDetermined: "完成通知尚未开启"
        case .authorized: "完成通知已允许"
        case .provisional: "完成通知已允许静默投递"
        case .denied: "完成通知未获允许"
        case .unavailable: "系统通知暂不可用"
        }
    }

    var notificationPermissionGuidance: String {
        switch notificationPermission {
        case .notDetermined: "开启后，任务完成会通过 macOS 通知提醒。等待回复不会通知。"
        case .authorized, .provisional: "三秒内完成的结果会合并提醒。"
        case .denied: "可在系统设置中允许 Grokoo 通知；待收起结果仍保留在工作区。"
        case .unavailable: "待收起结果保留在工作区，可稍后重新检查通知权限。"
        }
    }

    func retry() {
        guard connectionState.canRetry else { return }
        connectionState = .connecting
        announce("正在重新连接 Grok Bot。")
        onRetry?()
    }

    private func refreshOrder(configurations: [PetConfiguration]) {
        let byID = Dictionary(roster.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ordered = configurations.sorted { $0.globalOrder < $1.globalOrder }.compactMap { byID[$0.botId] }
        let known = Set(ordered.map(\.id))
        bots = ordered + roster.filter { !known.contains($0.id) }
    }

    private func name(for botId: BotID) -> String { bots.first { $0.id == botId }?.name ?? "Bot" }

    private func announce(_ message: String) {
        accessibilityMessage = message
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue]
        )
    }
}
