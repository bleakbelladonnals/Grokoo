import AppKit

@MainActor
final class SystemLifecycleObserver: SystemLifecycleObserving {
    var onWillSleep: (() -> Void)?
    var onDidWake: (() -> Void)?

    private let notificationCenter: NotificationCenter
    private var observers: [NSObjectProtocol] = []

    init(notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        self.notificationCenter = notificationCenter
    }

    func start() {
        guard observers.isEmpty else { return }
        observers.append(notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.emitWillSleep() }
        })
        observers.append(notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.emitDidWake() }
        })
    }

    func stop() {
        for observer in observers {
            notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
        onWillSleep = nil
        onDidWake = nil
    }

    /// Injectable acceptance hooks used without putting the host Mac to sleep.
    func injectWillSleep() { emitWillSleep() }
    func injectDidWake() { emitDidWake() }

    private func emitWillSleep() { onWillSleep?() }
    private func emitDidWake() { onDidWake?() }
}
