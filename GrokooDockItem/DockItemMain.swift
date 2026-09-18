import AppKit
import Darwin

@MainActor
final class DockItemAppDelegate: NSObject, NSApplicationDelegate {
    private var configuration: DockHelperConfiguration
    private let configurationURL: URL
    private var frames: [NSImage] = []
    private var frameIndex = 0
    private var iconTimer: Timer?
    private var configurationTimer: Timer?
    private var accessibilityObserver: NSObjectProtocol?

    init(configuration: DockHelperConfiguration, configurationURL: URL) {
        self.configuration = configuration
        self.configurationURL = configurationURL
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        configureMenu()
        rebuildFrames()
        configurationTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshConfiguration() }
        }
        configurationTimer?.tolerance = 0.1
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildFrames() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openTarget()
        return false
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? { itemMenu() }

    func applicationWillTerminate(_ notification: Notification) {
        iconTimer?.invalidate()
        configurationTimer?.invalidate()
        if let accessibilityObserver { NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver) }
    }

    private var reducedMotion: Bool {
        configuration.reducedMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func rebuildFrames() {
        let renderer = DockIconRenderer(item: configuration.item)
        let staticFrame = reducedMotion || configuration.item.state == .offline
        frames = (0..<(staticFrame ? 1 : 4)).map {
            renderer.image(at: Double($0) * configuration.item.state.frameInterval)
        }
        frameIndex = 0
        updateIcon()
        scheduleAnimation()
    }

    private func scheduleAnimation() {
        iconTimer?.invalidate()
        iconTimer = nil
        guard !configuration.suspended, !reducedMotion, frames.count > 1 else { return }
        iconTimer = Timer.scheduledTimer(withTimeInterval: configuration.item.state.frameInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateIcon() }
        }
        iconTimer?.tolerance = 0.08
    }

    private func updateIcon() {
        guard !frames.isEmpty else { return }
        NSApp.applicationIconImage = frames[frameIndex % frames.count]
        frameIndex += 1
    }

    private func refreshConfiguration() {
        // The same signed app may have many instances. Each instance has one
        // immutable configuration path and one host process to watch.
        if kill(configuration.parentPID, 0) != 0 && errno == ESRCH {
            NSApp.terminate(nil)
            return
        }
        guard FileManager.default.fileExists(atPath: configurationURL.path) else {
            NSApp.terminate(nil)
            return
        }
        guard let data = try? Data(contentsOf: configurationURL),
              let incoming = try? JSONDecoder().decode(DockHelperConfiguration.self, from: data),
              incoming.item.id == configuration.item.id,
              incoming.item.revision >= configuration.item.revision,
              incoming != configuration else { return }
        let appearanceChanged = !incoming.item.hasSamePresentation(as: configuration.item)
            || incoming.reducedMotion != configuration.reducedMotion
        configuration = incoming
        configureMenu()
        if appearanceChanged { rebuildFrames() }
        else { scheduleAnimation() }
    }

    private func configureMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem(title: "Grokoo", action: nil, keyEquivalent: "")
        appItem.submenu = itemMenu()
        menu.addItem(appItem)
        NSApp.mainMenu = menu
    }

    private func itemMenu() -> NSMenu {
        let menu = NSMenu()
        let title = NSMenuItem(title: "\(configuration.item.displayName) · \(configuration.item.state.title)", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())
        let open = NSMenuItem(title: "在 Grok Bot 中打开", action: #selector(openTarget), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        if configuration.item.state == .done {
            let acknowledge = NSMenuItem(title: "收起已完成结果", action: #selector(acknowledgeDone), keyEquivalent: "")
            acknowledge.target = self
            menu.addItem(acknowledge)
        }
        menu.addItem(.separator())
        let close = NSMenuItem(title: "不在 Dock 显示", action: #selector(disableItem), keyEquivalent: "q")
        close.target = self
        menu.addItem(close)
        return menu
    }

    @objc private func acknowledgeDone() {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(configuration.commandNotificationName), object: "acknowledge",
            userInfo: ["id": configuration.item.id], deliverImmediately: true)
    }

    @objc private func disableItem() { NSApp.terminate(nil) }

    @objc private func openTarget() {
        let item = configuration.item
        Task {
            let workspace = NSWorkspace.shared
            guard let applicationURL = workspace.urlForApplication(withBundleIdentifier: item.applicationBundleIdentifier) else { return }
            let options = NSWorkspace.OpenConfiguration()
            options.activates = true
            options.addsToRecentItems = false
            if let route = item.routeURL ?? item.fallbackURL {
                do {
                    _ = try await workspace.open([route], withApplicationAt: applicationURL, configuration: options)
                    return
                } catch { }
            }
            if let fallback = item.fallbackURL, fallback != item.routeURL {
                do {
                    _ = try await workspace.open([fallback], withApplicationAt: applicationURL, configuration: options)
                    return
                } catch { }
            }
            _ = try? await workspace.openApplication(at: applicationURL, configuration: options)
        }
    }
}

@main
enum GrokooDockItemMain {
    @MainActor
    static func main() {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--config"), args.indices.contains(index + 1) else { return }
        let configurationURL = URL(fileURLWithPath: args[index + 1])
        guard let data = try? Data(contentsOf: configurationURL),
              let configuration = try? JSONDecoder().decode(DockHelperConfiguration.self, from: data) else { return }
        let app = NSApplication.shared
        let delegate = DockItemAppDelegate(configuration: configuration, configurationURL: configurationURL)
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}
