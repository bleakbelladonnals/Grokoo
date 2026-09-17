import AppKit

@MainActor
final class MainScreenObserver: MainScreenObserving {
    var onChange: ((MainScreenGeometry) -> Void)?

    private let notificationCenter: NotificationCenter
    private let workspaceNotificationCenter: NotificationCenter
    private let screenProvider: () -> NSScreen?
    private var observers: [NSObjectProtocol] = []

    init(
        notificationCenter: NotificationCenter = .default,
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        screenProvider: @escaping () -> NSScreen? = { NSScreen.main ?? NSScreen.screens.first }
    ) {
        self.notificationCenter = notificationCenter
        self.workspaceNotificationCenter = workspaceNotificationCenter
        self.screenProvider = screenProvider
    }

    var current: MainScreenGeometry? {
        guard let screen = screenProvider() else { return nil }
        let insets: EdgeInsets
        if #available(macOS 12.0, *) {
            insets = EdgeInsets(
                top: screen.safeAreaInsets.top,
                left: screen.safeAreaInsets.left,
                bottom: screen.safeAreaInsets.bottom,
                right: screen.safeAreaInsets.right
            )
        } else {
            insets = .zero
        }
        return Self.geometry(frame: screen.frame, visibleFrame: screen.visibleFrame, safeAreaInsets: insets)
    }

    static func geometry(frame: CGRect, visibleFrame: CGRect, safeAreaInsets: EdgeInsets) -> MainScreenGeometry {
        let safeRect = CGRect(
            x: frame.minX + safeAreaInsets.left,
            y: frame.minY + safeAreaInsets.bottom,
            width: max(0, frame.width - safeAreaInsets.left - safeAreaInsets.right),
            height: max(0, frame.height - safeAreaInsets.top - safeAreaInsets.bottom)
        )
        return MainScreenGeometry(
            frame: frame,
            visibleFrame: visibleFrame.intersection(safeRect),
            safeAreaInsets: safeAreaInsets
        )
    }

    func start() {
        guard observers.isEmpty else { return }

        observers.append(notificationCenter.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.publish() }
        })
        observers.append(workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.publish() }
        })
        publish()
    }

    func stop() {
        for observer in observers {
            notificationCenter.removeObserver(observer)
            workspaceNotificationCenter.removeObserver(observer)
        }
        observers.removeAll()
        onChange = nil
    }

    /// Injectable acceptance hook for screen/Dock/safe-area topology changes.
    func inject(_ geometry: MainScreenGeometry) {
        onChange?(geometry)
    }

    private func publish() {
        guard let current else { return }
        onChange?(current)
    }
}
