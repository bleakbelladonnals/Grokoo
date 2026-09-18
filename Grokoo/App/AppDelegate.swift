import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: AppCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        let coordinator = AppAssembly.makeDefault()
        self.coordinator = coordinator
        coordinator.start()
        #if DEBUG
        if ProcessInfo.processInfo.environment["GROKOO_MOTION_EXPERIENCE"] == "1" {
            coordinator.openMotionExperience()
        }
        #endif
        if (ProcessInfo.processInfo.environment["GROKOO_ACCEPTANCE_OPEN_SETTINGS"] ?? ProcessInfo.processInfo.environment["GROKLING_ACCEPTANCE_OPEN_SETTINGS"]) == "1" {
            coordinator.openSettings()
        }
        if (ProcessInfo.processInfo.environment["GROKOO_ACCEPTANCE_OPEN_MENU"] ?? ProcessInfo.processInfo.environment["GROKLING_ACCEPTANCE_OPEN_MENU"]) == "1" {
            coordinator.showMenuForAcceptance()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.shutdown()
        coordinator = nil
    }
}
