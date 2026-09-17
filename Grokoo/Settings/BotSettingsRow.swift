import AppKit
import SwiftUI

enum SettingsControl: Hashable {
    case retry, notifications
    case visibility(BotID), mbti(BotID), moveUp(BotID), moveDown(BotID)
}

struct BotSettingsRow: View {
    let bot: SettingsBot
    @ObservedObject var viewModel: SettingsViewModel

    private var configuration: PetConfiguration? { viewModel.store.configuration(for: bot.id) }

    var body: some View {
        if let configuration {
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Text(bot.name)
                        .lineLimit(1)
                        .help(bot.name)
                        .accessibilityHidden(true)
                    Spacer(minLength: 4)
                    nativeControl(.visibility(bot.id), configuration: configuration)
                        .frame(width: 40, height: 28)
                }
                .frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)
                nativeControl(.mbti(bot.id), configuration: configuration)
                    .frame(width: 150, height: 28)
                HStack(spacing: 4) {
                    Text("顺序 \(configuration.globalOrder + 1)")
                        .frame(minWidth: 50, alignment: .trailing)
                        .accessibilityLabel("第 \(configuration.globalOrder + 1) 位，共 \(viewModel.bots.count) 只 Bot")
                    nativeControl(.moveUp(bot.id), configuration: configuration)
                        .frame(width: 36, height: 28)
                        .disabled(configuration.globalOrder == 0)
                    nativeControl(.moveDown(bot.id), configuration: configuration)
                        .frame(width: 36, height: 28)
                        .disabled(configuration.globalOrder == viewModel.bots.count - 1)
                }
            }
            .padding(.vertical, 6)
            .accessibilityElement(children: .contain)
        }
    }

    private func nativeControl(_ control: SettingsControl, configuration: PetConfiguration) -> some View {
        BotSettingsNativeControl(bot: bot, control: control, configuration: configuration, viewModel: viewModel)
            .settingsFocusRing(viewModel.keyboardFocusedControl == control)
    }
}

/// Native controls keep keyboard access available regardless of the system's
/// optional "Keyboard navigation" preference. Focus is scoped to this window.
private struct BotSettingsNativeControl: NSViewRepresentable {
    let bot: SettingsBot
    let control: SettingsControl
    let configuration: PetConfiguration
    let viewModel: SettingsViewModel

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSControl {
        let native: NSControl
        let onFocus: () -> Void = { [weak viewModel] in viewModel?.keyboardFocusedControl = control }
        switch control {
        case .visibility:
            let toggle = SettingsFocusSwitch()
            toggle.onFocus = onFocus
            native = toggle
        case .mbti:
            let picker = SettingsFocusPopUpButton(frame: .zero, pullsDown: false)
            picker.addItems(withTitles: ["中性（无配件）"] + MBTIType.allCases.map { $0.rawValue.uppercased() })
            picker.onFocus = onFocus
            native = picker
        default:
            let button = SettingsFocusButton()
            button.bezelStyle = .rounded
            button.imagePosition = .imageOnly
            button.onFocus = onFocus
            native = button
        }
        native.target = context.coordinator
        native.action = #selector(Coordinator.performAction(_:))
        viewModel.registerKeyboardControl(native, for: control)
        return native
    }

    func updateNSView(_ native: NSControl, context: Context) {
        context.coordinator.parent = self
        switch control {
        case .visibility:
            (native as? NSSwitch)?.state = configuration.isVisible ? .on : .off
            native.setAccessibilityIdentifier("settings.visibility.\(bot.id)")
            native.setAccessibilityLabel("显示 \(bot.name)")
            native.setAccessibilityHelp("隐藏后保留当前顺序。最多同时显示 6 只桌宠。")
        case .mbti:
            let index = configuration.mbti.flatMap { MBTIType.allCases.firstIndex(of: $0).map { $0 + 1 } } ?? 0
            (native as? NSPopUpButton)?.selectItem(at: index)
            native.setAccessibilityIdentifier("settings.mbti.\(bot.id)")
            native.setAccessibilityLabel("\(bot.name) 的 MBTI")
        case .moveUp:
            (native as? NSButton)?.image = NSImage(systemSymbolName: "chevron.up", accessibilityDescription: nil)
            native.isEnabled = configuration.globalOrder > 0
            native.setAccessibilityIdentifier("settings.move-up.\(bot.id)")
            native.setAccessibilityLabel("将 \(bot.name) 从第 \(configuration.globalOrder + 1) 位向上移动")
        case .moveDown:
            (native as? NSButton)?.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)
            native.isEnabled = configuration.globalOrder < viewModel.bots.count - 1
            native.setAccessibilityIdentifier("settings.move-down.\(bot.id)")
            native.setAccessibilityLabel("将 \(bot.name) 从第 \(configuration.globalOrder + 1) 位向下移动")
        default: break
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: BotSettingsNativeControl
        init(parent: BotSettingsNativeControl) { self.parent = parent }

        @objc func performAction(_ sender: NSControl) {
            switch parent.control {
            case .visibility:
                parent.viewModel.setVisibility((sender as? NSSwitch)?.state == .on, for: parent.bot.id)
                (sender as? NSSwitch)?.state = parent.viewModel.store.configuration(for: parent.bot.id)?.isVisible == true ? .on : .off
            case .mbti:
                guard let index = (sender as? NSPopUpButton)?.indexOfSelectedItem else { return }
                parent.viewModel.setMBTI(index == 0 ? nil : MBTIType.allCases[index - 1], for: parent.bot.id)
            case .moveUp: parent.viewModel.move(botId: parent.bot.id, delta: -1)
            case .moveDown: parent.viewModel.move(botId: parent.bot.id, delta: 1)
            default: break
            }
        }
    }
}

final class SettingsFocusSwitch: NSSwitch {
    var onFocus: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?() }
        return accepted
    }
}

final class SettingsFocusPopUpButton: NSPopUpButton {
    var onFocus: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?() }
        return accepted
    }
}

final class SettingsFocusButton: NSButton {
    var onFocus: (() -> Void)?
    override var acceptsFirstResponder: Bool { isEnabled }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?() }
        return accepted
    }
}

extension View {
    func settingsFocusRing(_ focused: Bool) -> some View {
        overlay {
            RoundedRectangle(cornerRadius: 5)
                .stroke(focused ? Color.accentColor : .clear, lineWidth: 2)
                .padding(-3)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
