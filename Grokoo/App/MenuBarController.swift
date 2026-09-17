import AppKit

@MainActor
final class MenuBarController: NSObject {
    private let statusBar: NSStatusBar
    private let statusItem: NSStatusItem
    private let onShowAll: () -> Void
    private let onHideAll: () -> Void
    private let onOpenSettings: () -> Void
    private let onQuit: () -> Void
    private let onFocusWorkspace: (() -> Void)?
    private let onAcknowledgeDone: ((BotID) -> Void)?
    private let onAcknowledgeAllDone: (() -> Void)?
    private var summaryItem: NSMenuItem?
    private var detailItem: NSMenuItem?
    private var doneItem: NSMenuItem?
    private var workspaceMainMenuItem: NSMenuItem?
    private var applicationMenuObservers: [NSObjectProtocol] = []
    private var pendingDone: [SettingsBot] = []
    #if DEBUG
    private var experienceItem: NSMenuItem?
    private var onSelectExperienceFixture: ((String) -> Void)?
    #endif

    var menuItemTitles: [String] {
        statusItem.menu?.items.compactMap { $0.isSeparatorItem || $0.isHidden ? nil : $0.title } ?? []
    }

    var usesTemplateIcon: Bool { statusItem.button?.image?.isTemplate == true }
    var accessibilitySummary: String { statusItem.button?.accessibilityLabel() ?? "" }
    var menu: NSMenu? { statusItem.menu }

    init(
        statusBar: NSStatusBar = .system,
        onShowAll: @escaping () -> Void,
        onHideAll: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        onQuit: @escaping () -> Void,
        onFocusWorkspace: (() -> Void)? = nil,
        onAcknowledgeDone: ((BotID) -> Void)? = nil,
        onAcknowledgeAllDone: (() -> Void)? = nil
    ) {
        self.statusBar = statusBar
        statusItem = statusBar.statusItem(withLength: NSStatusItem.variableLength)
        self.onShowAll = onShowAll
        self.onHideAll = onHideAll
        self.onOpenSettings = onOpenSettings
        self.onQuit = onQuit
        self.onFocusWorkspace = onFocusWorkspace
        self.onAcknowledgeDone = onAcknowledgeDone
        self.onAcknowledgeAllDone = onAcknowledgeAllDone
        super.init()
        configureStatusItem()
        observeApplicationMenu()
    }

    func shutdown() {
        applicationMenuObservers.forEach { NotificationCenter.default.removeObserver($0) }
        applicationMenuObservers.removeAll()
        if let workspaceMainMenuItem {
            workspaceMainMenuItem.menu?.removeItem(workspaceMainMenuItem)
        }
        workspaceMainMenuItem = nil
        statusItem.menu = nil
        statusBar.removeStatusItem(statusItem)
    }

    func showForAcceptance() {
        statusItem.button?.performClick(nil)
    }

    func update(aggregate: PresenceAggregate) {
        guard let button = statusItem.button else { return }
        let count = aggregate.activeBotCount.map { $0 > 0 ? String($0) : "" } ?? "—"
        button.title = count + (aggregate.attentionPresent ? " !" : "")
        button.imagePosition = count.isEmpty && !aggregate.attentionPresent ? .imageOnly : .imageLeading
        if let active = aggregate.activeBotCount {
            summaryItem?.title = active == 0 ? "当前没有运行中的 Bot" : "\(active) 只 Bot 正在运行"
        } else {
            summaryItem?.title = "实时运行数量暂不可用"
        }
        detailItem?.title = "等待 \(aggregate.waitingCount) · 受阻 \(aggregate.blockedCount) · 待收起 \(aggregate.pendingDoneCount)"
        updateAccessibilitySummary()
    }

    func updatePendingDone(bots: [SettingsBot]) {
        var seen = Set<BotID>()
        pendingDone = bots.filter { seen.insert($0.id).inserted }
        guard let doneItem else { return }
        doneItem.isHidden = pendingDone.isEmpty
        doneItem.title = "待收起结果（\(pendingDone.count)）"
        let submenu = NSMenu(title: "待收起结果")
        submenu.autoenablesItems = false
        for bot in pendingDone {
            let item = menuItem(title: "收起 \(bot.name)", action: #selector(acknowledgeDone(_:)))
            item.representedObject = bot.id
            item.setAccessibilityLabel("收起 \(bot.name) 的已完成结果")
            item.setAccessibilityHelp("确认后不再显示此完成结果。")
            submenu.addItem(item)
        }
        if pendingDone.count >= 2, onAcknowledgeAllDone != nil {
            submenu.addItem(.separator())
            let item = menuItem(title: "全部收起", action: #selector(acknowledgeAllDone), keyEquivalent: "d")
            item.keyEquivalentModifierMask = [.command, .option]
            item.setAccessibilityLabel("全部收起，共 \(pendingDone.count) 只 Bot 的已完成结果")
            submenu.addItem(item)
        }
        doneItem.submenu = submenu
        synchronizeWorkspaceMainMenu()
    }

    #if DEBUG
    func enableExperienceChecks(selectedFixtureID: String?, onSelect: @escaping (String) -> Void) {
        onSelectExperienceFixture = onSelect
        guard let menu = statusItem.menu else { return }
        let item: NSMenuItem
        if let current = experienceItem {
            item = current
        } else {
            item = NSMenuItem(title: "Experience Check", action: nil, keyEquivalent: "")
            menu.insertItem(item, at: max(0, menu.items.count - 2))
            experienceItem = item
        }
        let submenu = NSMenu(title: "Experience Check")
        submenu.autoenablesItems = false
        for fixture in ExperienceFixtureCatalog.loadBundled() {
            let choice = menuItem(title: fixtureTitle(fixture), action: #selector(selectExperienceFixture(_:)))
            choice.representedObject = fixture.id
            choice.state = fixture.id == selectedFixtureID ? .on : .off
            choice.setAccessibilityLabel(fixtureTitle(fixture))
            submenu.addItem(choice)
        }
        item.submenu = submenu
        synchronizeWorkspaceMainMenu()
    }

    private func fixtureTitle(_ fixture: ExperienceFixture) -> String {
        let detail: String
        if fixture.id == "seven-states" {
            detail = "状态同屏，Blocked 仅供验收"
        } else if fixture.states == [.blocked] {
            detail = "Blocked，仅供验收"
        } else if fixture.reducedMotion {
            detail = "减少动态效果"
        } else if fixture.reducedTransparency {
            detail = "降低透明度"
        } else {
            detail = "\(fixture.visibleBotCount) 只 Bot"
        }
        return "\(fixture.id) · \(detail)"
    }

    @objc private func selectExperienceFixture(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        experienceItem?.submenu?.items.forEach { $0.state = ($0.representedObject as? String) == id ? .on : .off }
        onSelectExperienceFixture?(id)
        synchronizeWorkspaceMainMenu()
    }
    #endif

    private func updateAccessibilitySummary() {
        let summary = summaryItem?.title ?? "当前没有运行中的 Bot"
        let detail = detailItem?.title ?? "等待 0 · 受阻 0 · 待收起 0"
        let description = "Grokoo，\(summary)。\(detail)"
        summaryItem?.setAccessibilityLabel(summary)
        detailItem?.setAccessibilityLabel(detail)
        statusItem.menu?.setAccessibilityLabel(description)
        statusItem.button?.toolTip = description
        statusItem.button?.setAccessibilityLabel(description)
        statusItem.button?.setAccessibilityHelp("打开菜单可查看状态、进入工作区和收起已完成结果。")
        synchronizeWorkspaceMainMenu()
    }

    private func synchronizeWorkspaceMainMenu() {
        guard let mainMenu = NSApp.mainMenu,
              let copiedMenu = statusItem.menu?.copy() as? NSMenu else { return }
        let workspace: NSMenuItem
        if let existing = workspaceMainMenuItem {
            workspace = existing
        } else {
            workspace = NSMenuItem(title: "工作区", action: nil, keyEquivalent: "")
            workspace.setAccessibilityLabel("工作区")
            workspaceMainMenuItem = workspace
        }
        if workspace.menu !== mainMenu {
            workspace.menu?.removeItem(workspace)
            mainMenu.addItem(workspace)
        }
        copiedMenu.title = "工作区"
        copiedMenu.setAccessibilityLabel(accessibilitySummary)
        workspace.submenu = copiedMenu
    }

    func ensureWorkspaceMainMenu() {
        guard let mainMenu = NSApp.mainMenu, statusItem.menu != nil else { return }
        if let workspaceMainMenuItem,
           workspaceMainMenuItem.menu === mainMenu,
           mainMenu.items.contains(where: { $0 === workspaceMainMenuItem }) { return }
        synchronizeWorkspaceMainMenu()
    }

    private func observeApplicationMenu() {
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didUpdateNotification] {
            applicationMenuObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: NSApp, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.ensureWorkspaceMainMenu() }
            })
        }
        // SwiftUI installs its command menus after the launch delegate returns.
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.ensureWorkspaceMainMenu()
        }
    }

    private func configureStatusItem() {
        if let button = statusItem.button {
            let image = NSImage(named: "MenuBarIcon")
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageOnly
            button.toolTip = "Grokoo"
        }

        let menu = NSMenu()
        menu.autoenablesItems = false
        let summary = NSMenuItem(title: "当前没有运行中的 Bot", action: nil, keyEquivalent: "")
        summary.isEnabled = false
        menu.addItem(summary)
        summaryItem = summary
        let detail = NSMenuItem(title: "等待 0 · 受阻 0 · 待收起 0", action: nil, keyEquivalent: "")
        detail.isEnabled = false
        menu.addItem(detail)
        detailItem = detail
        menu.addItem(.separator())
        if onFocusWorkspace != nil {
            let focus = menuItem(title: "进入工作区", action: #selector(focusWorkspace), keyEquivalent: "w")
            focus.keyEquivalentModifierMask = [.command, .option]
            focus.setAccessibilityHelp("将键盘焦点移到桌宠。使用 Tab 切换，空格或 Return 操作，Esc 离开。")
            menu.addItem(focus)
        }
        if onAcknowledgeDone != nil {
            let done = NSMenuItem(title: "待收起结果", action: nil, keyEquivalent: "")
            done.isHidden = true
            menu.addItem(done)
            doneItem = done
        }
        menu.addItem(menuItem(title: "显示全部", action: #selector(showAll)))
        menu.addItem(menuItem(title: "隐藏全部", action: #selector(hideAll)))
        menu.addItem(.separator())
        menu.addItem(menuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(menuItem(title: "退出 Grokoo", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
        updateAccessibilitySummary()
    }

    private func menuItem(title: String, action: Selector, keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    @objc private func showAll() { onShowAll() }
    @objc private func hideAll() { onHideAll() }
    @objc private func openSettings() { onOpenSettings() }
    @objc private func quit() { onQuit() }
    @objc private func focusWorkspace() { onFocusWorkspace?() }
    @objc private func acknowledgeDone(_ sender: NSMenuItem) {
        guard let botID = sender.representedObject as? String,
              pendingDone.contains(where: { $0.id == botID }) else { return }
        onAcknowledgeDone?(botID)
    }
    @objc private func acknowledgeAllDone() { onAcknowledgeAllDone?() }
}
