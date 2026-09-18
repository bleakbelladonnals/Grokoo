import AppKit
import CryptoKit
import Darwin

/// Every identity launches the same immutable, signed helper bundle. Identity and
/// state live in per-session configuration files, never in the application bundle.
@MainActor
final class DockController: DockServicing {
    var onDisableItem: ((String) -> Void)?
    var onAcknowledgeItem: ((String) -> Void)?
    var onError: ((String) -> Void)?
    private(set) var lastError: String?
    private(set) var items: [DockItemSnapshot] = []
    private(set) var isSuspended = false
    private(set) var isShutdown = false
    private var reducedMotion = false
    private let helperBundleURL: URL
    let runtimeDirectory: URL
    private var processes: [String: Process] = [:]
    private var writtenConfigurations: [String: DockHelperConfiguration] = [:]
    private var commandObserver: NSObjectProtocol?
    private let commandNotificationName = "local.grokling.dock.\(UUID().uuidString)"

    var runningItemIDs: Set<String> { Set(processes.filter { $0.value.isRunning }.keys) }
    var processIdentifiers: [String: Int32] { processes.mapValues(\.processIdentifier) }

    init(helperBundleURL: URL? = nil, runtimeDirectory: URL? = nil) {
        self.helperBundleURL = helperBundleURL ?? Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/GrokooDockItem.app", isDirectory: true)
        self.runtimeDirectory = runtimeDirectory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Grokoo/DockSessions/\(UUID().uuidString)", isDirectory: true)
    }

    func synchronize(items incoming: [DockItemSnapshot], reducedMotion: Bool) {
        guard !isShutdown else { return }
        observeCommandsIfNeeded()
        // Ignore stale per-identity revisions; order changes do not change the
        // configuration path or process assigned to an identity.
        let previous = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        var seen = Set<String>()
        items = incoming.filter { seen.insert($0.id).inserted }.map { item in
            guard let old = previous[item.id], old.revision > item.revision else { return item }
            return old
        }
        self.reducedMotion = reducedMotion
        reconcile()
    }

    func suspend() {
        guard !isShutdown else { return }
        isSuspended = true
        for item in items where processes[item.id] != nil { writeConfiguration(for: item) }
    }

    func resume() {
        guard !isShutdown else { return }
        isSuspended = false
        reconcile()
    }

    func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        if let commandObserver { DistributedNotificationCenter.default().removeObserver(commandObserver) }
        commandObserver = nil
        for id in Array(processes.keys) { stop(id: id) }
        items.removeAll()
        writtenConfigurations.removeAll()
        // Helpers also watch the host PID and config file, so normal and abnormal
        // host termination cannot leave orphan Dock entries.
        try? FileManager.default.removeItem(at: runtimeDirectory)
    }

    func configurationURL(for id: String) -> URL {
        let digest = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
        return runtimeDirectory.appendingPathComponent(digest + ".json")
    }

    private func reconcile() {
        let enabledIDs = Set(items.map(\.id))
        let existingIDs = Set(processes.keys).union(writtenConfigurations.keys)
        for id in existingIDs.subtracting(enabledIDs) { stop(id: id) }
        for item in items {
            guard writeConfiguration(for: item) else { continue }
            if !isSuspended && processes[item.id] == nil { start(item) }
        }
        if items.isEmpty { try? FileManager.default.removeItem(at: runtimeDirectory) }
    }

    @discardableResult
    private func writeConfiguration(for item: DockItemSnapshot) -> Bool {
        let configuration = DockHelperConfiguration(item: item, parentPID: getpid(),
            reducedMotion: reducedMotion, suspended: isSuspended,
            commandNotificationName: commandNotificationName)
        if let old = writtenConfigurations[item.id],
           old.item.hasSamePresentation(as: item), old.reducedMotion == reducedMotion,
           old.suspended == isSuspended { return true }
        do {
            try FileManager.default.createDirectory(at: runtimeDirectory,
                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let url = configurationURL(for: item.id)
            try JSONEncoder().encode(configuration).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            writtenConfigurations[item.id] = configuration
            return true
        } catch {
            report("无法更新 \(item.displayName) 的 Dock 入口：\(error.localizedDescription)")
            return false
        }
    }

    private func start(_ item: DockItemSnapshot) {
        let executable = helperBundleURL.appendingPathComponent("Contents/MacOS/GrokooDockItem")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            report("应用缺少 Dock 组件，请重新安装完整的 Grokoo。")
            return
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--config", configurationURL(for: item.id).path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] terminated in
            Task { @MainActor [weak self] in
                guard let self, !self.isShutdown, self.processes[item.id] === terminated else { return }
                self.processes.removeValue(forKey: item.id)
                if terminated.terminationReason == .exit && terminated.terminationStatus == 0 {
                    self.items.removeAll { $0.id == item.id }
                    self.writtenConfigurations.removeValue(forKey: item.id)
                    try? FileManager.default.removeItem(at: self.configurationURL(for: item.id))
                    self.onDisableItem?(item.id)
                } else {
                    self.report("\(item.displayName) 的 Dock 入口已退出，可重新启用。")
                }
            }
        }
        do {
            try process.run()
            processes[item.id] = process
            lastError = nil
        } catch { report("无法打开 \(item.displayName) 的 Dock 入口：\(error.localizedDescription)") }
    }

    private func stop(id: String) {
        let process = processes.removeValue(forKey: id)
        if process?.isRunning == true { process?.terminate() }
        writtenConfigurations.removeValue(forKey: id)
        try? FileManager.default.removeItem(at: configurationURL(for: id))
    }

    private func report(_ message: String) { lastError = message; onError?(message) }

    private func observeCommandsIfNeeded() {
        guard commandObserver == nil else { return }
        commandObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(commandNotificationName), object: "acknowledge", queue: .main
        ) { [weak self] notification in
            guard let id = notification.userInfo?["id"] as? String else { return }
            Task { @MainActor [weak self] in
                guard let self, self.items.contains(where: { $0.id == id && $0.state == .done }) else { return }
                self.onAcknowledgeItem?(id)
            }
        }
    }
}
