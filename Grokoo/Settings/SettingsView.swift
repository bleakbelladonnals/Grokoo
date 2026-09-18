import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @FocusState private var focusedControl: SettingsControl?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Grokoo 设置")
                    .font(.title2.weight(.semibold))
                Text("设置桌面伙伴与 Dock 快捷入口。")
                    .foregroundStyle(.secondary)
            }

            connectionSection
            notificationSection

            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 16) {
                        if !viewModel.bots.isEmpty {
                            HStack {
                                Text("桌面伙伴")
                                Spacer()
                                Text("已显示 \(viewModel.visibleCount) / 6")
                            }
                            .font(.headline)
                            Text("选择最多 6 只桌宠，并设置 MBTI 与工作区顺序。")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            VStack(spacing: 0) {
                                ForEach(viewModel.bots) { bot in
                                    BotSettingsRow(bot: bot, viewModel: viewModel)
                                        .padding(.horizontal, 12)
                                        .id(SettingsControl.visibility(bot.id))
                                    Divider()
                                        .accessibilityHidden(true)
                                }
                            }
                            .padding(.vertical, 4)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .accessibilityIdentifier("settings.bot-list")
                            .accessibilityLabel("桌宠，全局顺序")

                            if viewModel.visibilityLimitReached {
                                Text("已显示 6 只桌宠。请先隐藏一只，再选择新的 Bot。")
                                    .font(.callout)
                                    .foregroundStyle(.orange)
                            }
                            Divider()
                        }
                        dockSection
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: viewModel.keyboardFocusedControl) { _, control in
                    switch control {
                    case let .visibility(id), let .mbti(id), let .moveUp(id), let .moveDown(id):
                        proxy.scrollTo(SettingsControl.visibility(id))
                    case .dock(let id):
                        proxy.scrollTo(SettingsControl.dock(id))
                    default: break
                    }
                }
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 520)
        .defaultFocus($focusedControl, keyboardOrder.first)
        .onAppear { setKeyboardFocus(keyboardOrder.first) }
        .onChange(of: viewModel.keyboardFocusRequest) { _, _ in setKeyboardFocus(keyboardOrder.first) }
        .onChange(of: keyboardOrder) { _, order in
            if let current = viewModel.keyboardFocusedControl, order.contains(current) { return }
            setKeyboardFocus(order.first)
        }
        .onChange(of: focusedControl) { _, control in
            if let control { viewModel.keyboardFocusedControl = control }
        }
        .onReceive(viewModel.keyboardCommands) { command in
            switch command {
            case .moveFocus(let backwards): moveKeyboardFocus(backwards: backwards)
            case .activate: setKeyboardFocus(viewModel.keyboardFocusedControl)
            }
        }
    }

    private var dockSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Dock 入口")
                .font(.headline)
            Text("按需为 Bot 和群聊开启快捷入口，与桌面显示分别设置。")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let message = viewModel.dockErrorMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if viewModel.dockItems.isEmpty {
                Text("连接 Grok Bot 后可选择 Bot 和群聊。")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(viewModel.dockItems) { item in
                        DockSettingsRow(item: item, viewModel: viewModel)
                            .padding(.horizontal, 12)
                            .id(SettingsControl.dock(item.id))
                        Divider()
                            .accessibilityHidden(true)
                    }
                }
                .padding(.vertical, 4)
                .background(Color(nsColor: .controlBackgroundColor))
                .accessibilityIdentifier("settings.dock-list")
                .accessibilityLabel("Bot 和群聊的 Dock 入口")
            }
        }
    }

    @ViewBuilder
    private var connectionSection: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(connectionColor)
                .frame(width: 9, height: 9)
                .padding(.top, 5)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.connectionState.title)
                    .font(.headline)
                if let guidance = viewModel.connectionState.guidance {
                    Text(guidance)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if viewModel.connectionState.canRetry {
                Button("重试") { viewModel.retry() }
                    .fixedSize()
                    .frame(minHeight: 28)
                    .focusable()
                    .focused($focusedControl, equals: .retry)
                    .settingsFocusRing(viewModel.keyboardFocusedControl == .retry)
                    .keyboardShortcut("r", modifiers: [.command])
                    .accessibilityIdentifier("settings.retry")
                    .accessibilityLabel("重新连接 Grok Bot")
                    .accessibilityHint("重新获取 Bot 列表，已有设置保留。")
            }
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var notificationSection: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "bell")
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.notificationPermissionTitle)
                    .font(.headline)
                Text(viewModel.notificationPermissionGuidance)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if [.notDetermined, .unavailable, .denied].contains(viewModel.notificationPermission) {
                Button(notificationActionTitle) {
                    if viewModel.notificationPermission == .denied {
                        viewModel.onOpenNotificationSettings?()
                    } else {
                        viewModel.onRequestNotificationPermission?()
                    }
                }
                .fixedSize()
                .frame(minHeight: 28)
                .focusable()
                .focused($focusedControl, equals: .notifications)
                .settingsFocusRing(viewModel.keyboardFocusedControl == .notifications)
                .accessibilityIdentifier("settings.notifications")
                .accessibilityLabel(notificationActionTitle)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private var notificationActionTitle: String {
        switch viewModel.notificationPermission {
        case .denied: "打开系统设置"
        case .unavailable: "重新检查"
        default: "允许通知"
        }
    }

    private var keyboardOrder: [SettingsControl] { viewModel.keyboardOrder }

    private func moveKeyboardFocus(backwards: Bool) {
        let order = keyboardOrder
        guard !order.isEmpty else { return }
        guard let current = viewModel.keyboardFocusedControl, let index = order.firstIndex(of: current) else {
            setKeyboardFocus(backwards ? order.last : order.first)
            return
        }
        setKeyboardFocus(order[(index + (backwards ? -1 : 1) + order.count) % order.count])
    }

    private func setKeyboardFocus(_ control: SettingsControl?) {
        viewModel.keyboardFocusedControl = control
        guard let control else { focusedControl = nil; return }
        if !viewModel.focusNativeControl(control) { focusedControl = control }
    }

    private var connectionColor: Color {
        switch viewModel.connectionState {
        case .connected: .green
        case .connecting: .blue
        case .timedOut, .keychainDenied, .noBots, .offline: .orange
        }
    }
}
