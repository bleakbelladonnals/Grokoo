import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    let viewModel: SettingsViewModel
    private(set) var presentationCount = 0
    private var keyboardMonitor: Any?

    init(viewModel: SettingsViewModel) {
        self.viewModel = viewModel
        let hostingController = NSHostingController(rootView: SettingsView(viewModel: viewModel))
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Grokoo 设置"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 680, height: 680))
        window.contentMinSize = NSSize(width: 620, height: 520)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func open(connectionState: SettingsConnectionState? = nil) {
        presentationCount += 1
        if let connectionState {
            viewModel.update(bots: viewModel.bots, connectionState: connectionState)
        }
        installKeyboardMonitor()
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        viewModel.requestKeyboardFocus()
    }

    func shutdown() {
        removeKeyboardMonitor()
        close()
        window?.contentViewController = nil
    }

    func windowWillClose(_ notification: Notification) { removeKeyboardMonitor() }

    private func installKeyboardMonitor() {
        guard keyboardMonitor == nil else { return }
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.consumeKeyboardEvent(event) ?? false }
            return consumed ? nil : event
        }
    }

    private func removeKeyboardMonitor() {
        if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor) }
        keyboardMonitor = nil
    }

    private func consumeKeyboardEvent(_ event: NSEvent) -> Bool {
        guard let window,
              event.window === window || (event.window == nil && NSApp.keyWindow === window) else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.intersection([.command, .control, .option]).isEmpty else { return false }
        if event.keyCode == 48 {
            viewModel.handleKeyboardCommand(.moveFocus(backwards: modifiers.contains(.shift)))
            return true
        }
        guard !modifiers.contains(.shift), [UInt16(36), 49, 76].contains(event.keyCode) else { return false }
        if event.isARepeat {
            if let control = viewModel.keyboardFocusedControl, case .mbti = control { return false }
            return true
        }
        return viewModel.handleKeyboardCommand(.activate)
    }
}
