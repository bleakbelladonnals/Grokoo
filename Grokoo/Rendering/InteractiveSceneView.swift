import AppKit

struct SceneInteractionTarget: Equatable {
    let botID: BotID
    let name: String
    let state: PresenceState
    let frame: CGRect
}

/// Uses native controls so the same actions work with pointer, keyboard and VoiceOver.
final class InteractiveSceneView: NSView {
    var interactiveRegions: [CGRect] = []
    var onAcknowledge: ((BotID) -> Void)?
    var onAcknowledgeAll: (() -> Void)?
    var onHighlightedBot: ((BotID?) -> Void)?
    private(set) var targets: [SceneInteractionTarget] = []
    private(set) var highlightedBotID: BotID?
    private(set) var botButtons: [BotID: SceneBotButton] = [:]
    private(set) var dismissButton = SceneActionButton(title: "收起", target: nil, action: nil)
    private(set) var dismissAllButton = SceneActionButton(title: "全部收起", target: nil, action: nil)
    private let nameLabel = NSTextField(labelWithString: "")
    private var keyboardBotID: BotID?
    private var lastPointerPoint: CGPoint?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
        setAccessibilityLabel("Grokoo 桌面工作区")
        for button in [dismissButton, dismissAllButton] {
            button.scene = self
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.focusRingType = .exterior
            button.target = self
            button.isHidden = true
            addSubview(button)
        }
        dismissButton.action = #selector(acknowledgeHighlighted)
        dismissAllButton.action = #selector(acknowledgeAll)
        nameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        nameLabel.alignment = .center
        nameLabel.backgroundColor = .windowBackgroundColor
        nameLabel.drawsBackground = true
        nameLabel.isHidden = true
        nameLabel.setAccessibilityElement(false)
        addSubview(nameLabel)
    }

    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func updateTargets(_ targets: [SceneInteractionTarget]) {
        guard self.targets != targets else { return }
        let previousTargets = self.targets
        let orderChanged = previousTargets.map(\.botID) != targets.map(\.botID)
        self.targets = targets
        if orderChanged {
            let wanted = Set(targets.map(\.botID))
            for id in Array(botButtons.keys) where !wanted.contains(id) {
                botButtons.removeValue(forKey: id)?.removeFromSuperview()
                if keyboardBotID == id { keyboardBotID = nil }
            }
        }
        for target in targets {
            let button = botButtons[target.botID] ?? makeBotButton(id: target.botID)
            if button.frame != target.frame {
                if button.frame.size == target.frame.size {
                    button.setFrameOrigin(target.frame.origin)
                } else {
                    button.frame = target.frame
                }
            }
            // Patrol changes geometry every frame, but not the control's identity or status.
            let previous = previousTargets.first { $0.botID == target.botID }
            if previous?.name != target.name || previous?.state != target.state {
                button.setAccessibilityLabel("\(target.name)，\(Self.statusName(target.state))")
                button.setAccessibilityHelp(target.state == .done ? "按空格显示收起操作；按删除键收起。" : "当前任务状态")
                button.toolTip = "\(target.name) · \(Self.statusName(target.state))"
            }
        }
        if let highlightedBotID, !targets.contains(where: { $0.botID == highlightedBotID && $0.state == .done }) {
            setHighlight(nil)
        }
        if orderChanged || previousTargets.filter({ $0.state == .done }) != targets.filter({ $0.state == .done }) {
            layoutCompletionControls()
        }
    }

    /// Called by the window's mouse monitor, including while it is passing events through.
    func updatePointer(at point: CGPoint) {
        let moved = lastPointerPoint != point
        lastPointerPoint = point
        if !moved, let keyboardBotID {
            setHighlight(keyboardBotID)
            return
        }
        if moved { keyboardBotID = nil }
        if let id = targets.first(where: { $0.frame.contains(point) && $0.state == .done })?.botID {
            setHighlight(id)
        } else if let current = highlightedBotID,
                  let target = targets.first(where: { $0.botID == current }),
                  target.frame.union(dismissButton.frame).union(nameLabel.frame).contains(point) {
            return
        } else if !dismissAllButton.isHidden, dismissAllButton.frame.contains(point) {
            return
        } else {
            setHighlight(keyboardBotID)
        }
    }

    func containsInteractivePoint(_ point: CGPoint) -> Bool {
        guard !isHidden, alphaValue > 0 else { return false }
        return targets.contains(where: { $0.frame.contains(point) })
            || [dismissButton, dismissAllButton].contains(where: { !$0.isHidden && $0.frame.contains(point) })
            || interactiveRegions.contains(where: { $0.contains(point) })
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard containsInteractivePoint(point) else { return nil }
        return super.hitTest(point) ?? self
    }

    func focusPendingCompletions() {
        guard let target = targets.first(where: { $0.state == .done }), let button = botButtons[target.botID] else { return }
        keyboardBotID = target.botID
        setHighlight(target.botID)
        activateKeyboardFocus(on: button)
    }

    func focusBot(_ id: BotID) {
        keyboardBotID = targets.first(where: { $0.botID == id && $0.state == .done })?.botID
        setHighlight(keyboardBotID)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:
            keyboardBotID = nil
            setHighlight(nil)
            window?.makeFirstResponder(nil)
            window?.resignKey()
        case 51, 117:
            if let id = highlightedBotID { onAcknowledge?(id) }
        case 123, 124, 48:
            moveKeyboardFocus(backwards: event.keyCode == 123 || event.modifierFlags.contains(.shift))
        default: super.keyDown(with: event)
        }
    }

    private func makeBotButton(id: BotID) -> SceneBotButton {
        let button = SceneBotButton(title: "", target: self, action: #selector(selectBot(_:)))
        button.botID = id
        button.scene = self
        button.isBordered = false
        button.focusRingType = .exterior
        addSubview(button)
        botButtons[id] = button
        return button
    }

    private func moveKeyboardFocus(backwards: Bool) {
        var controls: [NSView] = targets.compactMap { botButtons[$0.botID] }
        if !dismissButton.isHidden { controls.append(dismissButton) }
        if !dismissAllButton.isHidden { controls.append(dismissAllButton) }
        guard !controls.isEmpty else { return }
        let index = controls.firstIndex(where: { $0 === window?.firstResponder }) ?? (backwards ? 0 : -1)
        let next = (index + (backwards ? -1 : 1) + controls.count) % controls.count
        window?.makeFirstResponder(controls[next])
    }

    private func setHighlight(_ id: BotID?) {
        let id = targets.contains(where: { $0.botID == id && $0.state == .done }) ? id : nil
        guard id != highlightedBotID else { return }
        highlightedBotID = id
        onHighlightedBot?(id)
        layoutCompletionControls()
    }

    private func layoutCompletionControls() {
        if let target = targets.first(where: { $0.botID == highlightedBotID && $0.state == .done }) {
            let width = max(76, min(180, CGFloat(target.name.count) * 9 + 16))
            let x = min(max(4, target.frame.midX - width / 2), max(4, bounds.width - width - 4))
            nameLabel.stringValue = target.name
            nameLabel.frame = CGRect(x: x, y: target.frame.maxY + 32, width: width, height: 20)
            dismissButton.frame = CGRect(x: x, y: target.frame.maxY + 2, width: width, height: 28)
            dismissButton.setAccessibilityLabel("收起 \(target.name) 的已完成任务")
            nameLabel.isHidden = false
            dismissButton.isHidden = false
        } else {
            nameLabel.isHidden = true
            dismissButton.isHidden = true
        }
        let done = targets.filter { $0.state == .done }
        dismissAllButton.isHidden = done.count < 2
        if done.count >= 2 {
            let right = done.map(\.frame.maxX).max() ?? 0
            let top = done.map(\.frame.maxY).max() ?? 0
            dismissAllButton.frame = CGRect(x: min(max(4, right + 8), max(4, bounds.width - 96)), y: top + 2, width: 92, height: 28)
            dismissAllButton.setAccessibilityLabel("全部收起，\(done.count) 个已完成任务")
        }
        var controls: [NSView] = targets.compactMap { botButtons[$0.botID] }
        if !dismissButton.isHidden { controls.append(dismissButton) }
        if !dismissAllButton.isHidden { controls.append(dismissAllButton) }
        for (index, control) in controls.enumerated() {
            let next = controls[(index + 1) % controls.count]
            if control.nextKeyView !== next { control.nextKeyView = next }
        }
    }

    private func activateKeyboardFocus(on control: NSView) {
        // This is an explicit user action (Bot click or menu keyboard entry), never hover.
        // Activation lets real key events reach an accessory app without raising its Scene.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKey()
        window?.makeFirstResponder(control)
    }

    @objc private func selectBot(_ sender: SceneBotButton) {
        activateKeyboardFocus(on: sender)
        focusBot(sender.botID)
    }
    @objc private func acknowledgeHighlighted() {
        if let id = highlightedBotID { onAcknowledge?(id) }
    }
    @objc private func acknowledgeAll() { onAcknowledgeAll?() }

    private static func statusName(_ state: PresenceState) -> String {
        switch state {
        case .idle: "空闲"
        case .working: "工作中"
        case .thinking: "思考中"
        case .waiting: "等待你回复"
        case .blocked: "需要你处理"
        case .done: "已完成"
        case .offline: "离线"
        }
    }
}

final class SceneBotButton: NSButton {
    var botID: BotID = ""
    weak var scene: InteractiveSceneView?
    override var acceptsFirstResponder: Bool { true }
    override var needsPanelToBecomeKey: Bool { true }
    override func draw(_ dirtyRect: NSRect) {}
    override var focusRingMaskBounds: NSRect { bounds.insetBy(dx: 1, dy: 1) }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: focusRingMaskBounds, xRadius: 8, yRadius: 8).fill() }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { scene?.focusBot(botID) }
        return accepted
    }
    override func keyDown(with event: NSEvent) {
        if [48, 51, 53, 117, 123, 124].contains(event.keyCode) {
            scene?.focusBot(botID)
            scene?.keyDown(with: event)
        } else { super.keyDown(with: event) }
    }
}

final class SceneActionButton: NSButton {
    weak var scene: InteractiveSceneView?
    override var acceptsFirstResponder: Bool { true }
    override var needsPanelToBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) {
        if [48, 53, 123, 124].contains(event.keyCode) { scene?.keyDown(with: event) }
        else if event.keyCode == 36 { performClick(nil) }
        else { super.keyDown(with: event) }
    }
}

final class DesktopScenePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
