import AppKit
import QuartzCore

@MainActor
final class PetSceneController: PetSceneServicing {
    static let maximumPetCount = 6

    private(set) var panel: NSPanel
    private(set) var sceneLayer = CALayer()
    private(set) var petLayers: [BotID: PetLayer] = [:]
    /// Retained as empty compatibility surfaces; 1.1 renders one Fog layer instead.
    private(set) var workstationLayers: [BotID: WorkstationLayer] = [:]
    private(set) var groupStationLayers: [GroupID: GroupStationLayer] = [:]
    private(set) var fogLayer = FogWorkspaceLayer()
    private(set) var currentPlacement: WorkspacePlacement = .empty
    private(set) var isVisible = false

    private var screenFrame: CGRect
    private var visibleFrame: CGRect
    private var safeAreaInsets: EdgeInsets
    private var configurations: [BotID: PetConfiguration] = [:]
    private var presenceByBot: [BotID: (state: PresenceState, revision: UInt64)] = [:]
    private var groupAssignments: [BotID: GroupMemberAssignment] = [:]
    private var freePositions: [BotID: CGPoint] = [:]
    private var transitionTasks: [BotID: Task<Void, Never>] = [:]
    private let allowsEdgeMotion: Bool
    private var experienceFixture: ExperienceFixture?
    private var identityNames: [BotID: String] = [:]
    private struct Destination: Equatable {
        var point: CGPoint
        var workspace: Bool
    }
    private var destinations: [BotID: Destination] = [:]
    private var fadingIn: Set<BotID> = []
    private var settledDestinations: [BotID: Destination] = [:]
    private var transitionSchedule = WorkspaceTransitionSchedule()
    private var pointerMonitor: Any?
    private var localPointerMonitor: Any?
    private var interactionTimer: Timer?
    private var motionClocks: [BotID: PresenceMotionClock] = [:]
    private let motionSampler = NativeMotionSampler()
    private var lastStaticMotion: [BotID: PresenceState] = [:]
    private var accessibilityObserver: NSObjectProtocol?
    private(set) var reducesMotion = false
    private let animationCoordinator = AnimationCoordinator()
    private lazy var idleMotionController = IdleMotionController(coordinator: animationCoordinator)
    private lazy var presetCatalog = try? MBTIPresetLoader.loadBundled()
    private var stableDockEdge: DockEdge = .bottom
    private var stableDockReference: CGRect?

    init(screen: NSScreen = NSScreen.main ?? NSScreen.screens[0], allowsEdgeMotion: Bool = true, experienceFixture: ExperienceFixture? = nil) {
        screenFrame = screen.frame
        let insets = screen.safeAreaInsets
        safeAreaInsets = EdgeInsets(top: insets.top, left: insets.left, bottom: insets.bottom, right: insets.right)
        visibleFrame = screen.visibleFrame
        self.allowsEdgeMotion = allowsEdgeMotion
        self.experienceFixture = experienceFixture
        panel = Self.makePanel(frame: screen.frame)
        configureScene(frame: screen.frame)
        updateStableDockGeometry(frame: screen.frame, visibleFrame: screen.visibleFrame)
        applyExperienceAppearance()
    }

    init(frame: CGRect, visibleFrame: CGRect, safeAreaInsets: EdgeInsets = .zero, allowsEdgeMotion: Bool = true, experienceFixture: ExperienceFixture? = nil) {
        screenFrame = frame
        self.visibleFrame = visibleFrame
        self.safeAreaInsets = safeAreaInsets
        self.allowsEdgeMotion = allowsEdgeMotion
        self.experienceFixture = experienceFixture
        panel = Self.makePanel(frame: frame)
        configureScene(frame: frame)
        updateStableDockGeometry(frame: frame, visibleFrame: visibleFrame)
        applyExperienceAppearance()
    }

    func synchronize(identities: [BotIdentity]) {
        let values = identities.enumerated().map { index, identity in
            configurations[identity.id] ?? PetConfiguration(botId: identity.id, isVisible: true, mbti: nil, globalOrder: index)
        }
        synchronize(identities: identities, configurations: values)
    }

    func synchronize(identities: [BotIdentity], configurations: [PetConfiguration]) {
        identityNames = Dictionary(uniqueKeysWithValues: identities.map { ($0.id, $0.name) })
        self.configurations = Dictionary(uniqueKeysWithValues: configurations.map { ($0.botId, $0) })
        let capped = Array(identities.prefix(Self.maximumPetCount))
        let wanted = Set(capped.map(\.id))
        for id in petLayers.keys where !wanted.contains(id) {
            transitionTasks.removeValue(forKey: id)?.cancel()
            fadingIn.remove(id)
            destinations.removeValue(forKey: id)
            settledDestinations.removeValue(forKey: id)
            transitionSchedule.release(botID: id)
            idleMotionController.stop(botId: id)
            petLayers.removeValue(forKey: id)?.removeFromSuperlayer()
            motionClocks.removeValue(forKey: id)
            lastStaticMotion.removeValue(forKey: id)
            motionSampler.reset(instanceID: id)
            motionSampler.reset(instanceID: id + ".focus")
            presenceByBot.removeValue(forKey: id)
            freePositions.removeValue(forKey: id)
            groupAssignments.removeValue(forKey: id)
        }
        for (index, identity) in capped.enumerated() {
            let pet: PetLayer
            if let current = petLayers[identity.id] {
                current.updateAppearance(shape: identity.shape, color: identity.color)
                pet = current
            } else {
                pet = PetLayer(identity: identity)
                pet.position = defaultFreePosition(index: index)
                freePositions[identity.id] = pet.position
                petLayers[identity.id] = pet
                let occupied = Set(motionClocks.values.map(\.phaseSlot))
                let slot = (0..<Self.maximumPetCount).first { !occupied.contains($0) } ?? 0
                motionClocks[identity.id] = PresenceMotionClock(phaseSlot: slot)
                sceneLayer.addSublayer(pet)
            }
            // 1.1's accessory gate covers all 16 types, including the four legacy
            // candidates. Keep the MBTI setting/behavior, but load no unapproved art.
            pet.setMBTIDecoration(nil)
            lastStaticMotion.removeValue(forKey: identity.id)
            renderMotion(for: pet)
        }
        renderWorkspace()
    }

    func petLayer(for botId: BotID) -> PetLayer? { petLayers[botId] }

    func showAll() {
        isVisible = true
        sceneLayer.isHidden = false
        panel.orderFrontRegardless()
        startInteractionMonitoring()
        renderWorkspace()
    }

    func hideAll() {
        isVisible = false
        transitionTasks.values.forEach { $0.cancel() }
        transitionTasks.removeAll()
        destinations.removeAll()
        settledDestinations.removeAll()
        fadingIn.removeAll()
        transitionSchedule.removeAll()
        stopInteractionMonitoring()
        idleMotionController.stopAll(pets: Array(petLayers.values))
        for pet in petLayers.values {
            motionClocks[pet.botId]?.pause()
            pet.opacity = 1
            pet.removeAllAnimations()
            pet.sublayers?.forEach { $0.removeAllAnimations() }
        }
        sceneLayer.isHidden = true
        panel.ignoresMouseEvents = true
        panel.orderOut(nil)
    }

    func updateMainScreen(frame: CGRect, visibleFrame: CGRect) {
        updateMainScreen(frame: frame, visibleFrame: visibleFrame, safeAreaInsets: safeAreaInsets)
    }

    func updateMainScreen(frame: CGRect, visibleFrame: CGRect, safeAreaInsets: EdgeInsets) {
        screenFrame = frame
        self.visibleFrame = visibleFrame
        self.safeAreaInsets = safeAreaInsets
        updateStableDockGeometry(frame: frame, visibleFrame: visibleFrame)
        panel.setFrame(frame, display: true)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sceneLayer.frame = CGRect(origin: .zero, size: frame.size)
        CATransaction.commit()
        renderWorkspace()
    }

    func updatePresence(_ state: PresenceState, botId: BotID, revision: UInt64) {
        presenceByBot[botId] = (state, revision)
        updateMotionState(state, botID: botId)
        renderWorkspace()
    }

    func updateGroupActivity(
        _ snapshot: GroupActivitySnapshot,
        presenceByBot states: [BotID: PresenceState],
        revision: UInt64
    ) {
        groupAssignments = snapshot.assignments
        for (id, state) in states {
            presenceByBot[id] = (state, revision)
            updateMotionState(state, botID: id)
        }
        renderWorkspace()
    }

    func shutdown() {
        hideAll()
        if let accessibilityObserver { NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver) }
        accessibilityObserver = nil
        petLayers.values.forEach { $0.removeFromSuperlayer() }
        petLayers.removeAll()
        motionClocks.removeAll()
        motionSampler.resetAll()
        fogLayer.removeFromSuperlayer()
        panel.contentView?.layer = nil
        panel.close()
    }

    private func configureScene(frame: CGRect) {
        let content = InteractiveSceneView(frame: CGRect(origin: .zero, size: frame.size))
        content.wantsLayer = true
        sceneLayer.frame = content.bounds
        sceneLayer.masksToBounds = true
        fogLayer.opacity = 0
        sceneLayer.addSublayer(fogLayer)
        // Keep AppKit's backing layer so native NSButton rendering and focus rings
        // coexist with the Core Animation scene. A layer-hosting view cannot do both.
        content.layer?.addSublayer(sceneLayer)
        panel.contentView = content
        content.onHighlightedBot = { [weak self] id in self?.focusDoneMotion(id) }
        panel.acceptsMouseMovedEvents = true
        panel.isReleasedWhenClosed = false
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshAccessibilityPreferences() }
        }
    }

    func configureCompletionActions(onAcknowledge: @escaping (BotID) -> Void, onAcknowledgeAll: @escaping () -> Void) {
        guard let view = panel.contentView as? InteractiveSceneView else { return }
        view.onAcknowledge = onAcknowledge
        view.onAcknowledgeAll = onAcknowledgeAll
    }

    func focusPendingCompletions() {
        guard isVisible else { return }
        refreshInteraction()
        panel.makeKey()
        (panel.contentView as? InteractiveSceneView)?.focusPendingCompletions()
    }

    func updateExperienceFixture(_ fixture: ExperienceFixture) {
        experienceFixture = fixture
        updateStableDockGeometry(frame: screenFrame, visibleFrame: visibleFrame)
        refreshAccessibilityPreferences()
        renderWorkspace()
    }

    func refreshAccessibilityPreferences() {
        applyExperienceAppearance()
        renderWorkspace()
    }

    private func renderWorkspace() {
        guard isVisible || panel.isVisible else { return }
        let ordered = configurations.values.filter(\.isVisible).sorted {
            $0.globalOrder == $1.globalOrder ? $0.botId < $1.botId : $0.globalOrder < $1.globalOrder
        }
        let active = ordered.compactMap { config -> WorkspaceMember? in
            guard let state = presenceByBot[config.botId]?.state, state != .idle else { return nil }
            let membership = groupAssignments[config.botId].map { WorkspaceMembership.group($0.groupId) } ?? .solo
            return WorkspaceMember(botId: config.botId, membership: membership)
        }
        let topology = currentTopology
        currentPlacement = WorkspaceLayoutEngine().placement(members: active, topology: topology)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fogLayer.frame = local(currentPlacement.surfaceFrame)
        fogLayer.opacity = active.isEmpty ? 0 : 1
        fogLayer.isHidden = active.isEmpty
        CATransaction.commit()

        for config in ordered {
            guard let pet = petLayers[config.botId] else { continue }
            if let frame = currentPlacement.petFrames[config.botId] {
                transition(pet: pet, to: Destination(point: CGPoint(x: local(frame).midX, y: local(frame).minY - pet.bodyShapeLayer.frame.minY * AssetContract.workspaceBodySize / AssetContract.freeBodySize), workspace: true))
            } else {
                // An idle route owns its current position until it actually enters the workspace.
                if settledDestinations[config.botId]?.workspace != true, destinations[config.botId] == nil {
                    startIdleMotionIfAllowed(pet)
                } else {
                    transition(pet: pet, to: Destination(point: freePositions[config.botId] ?? pet.position, workspace: false))
                }
            }
        }
        refreshInteraction()
    }

    private func transition(pet: PetLayer, to destination: Destination) {
        let id = pet.botId
        if let previous = destinations[id], previous.workspace == destination.workspace {
            if previous == destination { return }
            if !fadingIn.contains(id) {
            // Coalesces the per-Bot presence updates in the same snapshot. The midpoint uses
            // the newest layout while retaining the original batch and opacity trajectory.
                destinations[id] = destination
                return
            }
            // Once visible again, take over from that exact frame immediately rather than
            // finishing the old fade and subsequently replaying an entire lifecycle.
        }
        if settledDestinations[id] == destination, destinations[id] == nil { return }
        let presentation = pet.presentation()
        let point = presentation?.position ?? pet.position
        let transform = presentation?.transform ?? pet.transform
        let opacity = presentation?.opacity ?? pet.opacity
        if destination.workspace, settledDestinations[id]?.workspace != true, destinations[id] == nil {
            freePositions[id] = point
        }
        transitionTasks.removeValue(forKey: id)?.cancel()
        fadingIn.remove(id)
        idleMotionController.stop(botId: id)
        animationCoordinator.cancel(pet: pet)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pet.position = point
        pet.transform = transform
        pet.opacity = opacity
        CATransaction.commit()
        destinations[id] = destination
        let start = transitionSchedule.reserve(botID: id, now: CACurrentMediaTime())
        let delay = max(0, start - CACurrentMediaTime())
        let duration = destination.workspace ? WorkspaceTransitionSchedule.enteringDuration : WorkspaceTransitionSchedule.leavingDuration
        if delay == 0 { fade(pet, from: opacity, to: 0, duration: duration / 2) }
        transitionTasks[id] = Task { [weak self, weak pet] in
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self, let pet else { return }
                self.fade(pet, from: pet.presentation()?.opacity ?? pet.opacity, to: 0, duration: duration / 2)
            }
            try? await Task.sleep(for: .seconds(duration / 2))
            guard !Task.isCancelled, let self, let pet, let target = self.destinations[id] else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            pet.removeAnimation(forKey: "workspace.opacity")
            pet.opacity = 0
            pet.position = target.point
            let scale = target.workspace ? AssetContract.workspaceBodySize / AssetContract.freeBodySize : 1
            pet.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
            CATransaction.commit()
            // Commit a fully transparent position/size change before starting the fade in.
            CATransaction.flush()
            self.fadingIn.insert(id)
            self.fade(pet, from: 0, to: 1, duration: duration / 2)
            try? await Task.sleep(for: .seconds(duration / 2))
            guard !Task.isCancelled else { return }
            pet.removeAnimation(forKey: "workspace.opacity")
            self.transitionTasks[id] = nil
            self.destinations[id] = nil
            self.fadingIn.remove(id)
            self.settledDestinations[id] = target
            self.transitionSchedule.release(botID: id)
            self.startIdleMotionIfAllowed(pet)
            self.refreshInteraction()
            // A layout can change while fading in; finish from the current presentation.
            self.renderWorkspace()
        }
    }

    private func fade(_ pet: PetLayer, from: Float, to: Float, duration: TimeInterval) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pet.opacity = to
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        fade.toValue = to
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        pet.add(fade, forKey: "workspace.opacity")
        CATransaction.commit()
    }

    private func startIdleMotionIfAllowed(_ pet: PetLayer) {
        guard allowsEdgeMotion, !reducesMotion, destinations[pet.botId] == nil,
              (presenceByBot[pet.botId]?.state ?? .idle) == .idle else { return }
        idleMotionController.start(pet: pet, geometry: edgeGeometry, preset: preset(for: pet.botId))
    }

    private func startInteractionMonitoring() {
        guard interactionTimer == nil else { return }
        pointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshInteraction() }
        }
        localPointerMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .leftMouseDragged]) { [weak self] event in
            MainActor.assumeIsolated { self?.refreshInteraction() }
            return event
        }
        interactionTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.advanceMotion()
                self?.refreshInteraction()
            }
        }
        interactionTimer?.tolerance = 0.003
        if let interactionTimer { RunLoop.main.add(interactionTimer, forMode: .common) }
        advanceMotion()
    }

    private func stopInteractionMonitoring() {
        interactionTimer?.invalidate()
        interactionTimer = nil
        if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor) }
        if let localPointerMonitor { NSEvent.removeMonitor(localPointerMonitor) }
        pointerMonitor = nil
        localPointerMonitor = nil
    }

    func refreshInteraction() {
        guard let view = panel.contentView as? InteractiveSceneView else { return }
        let targets = configurations.values.filter(\.isVisible).sorted { $0.globalOrder < $1.globalOrder }.compactMap { config -> SceneInteractionTarget? in
            guard let pet = petLayers[config.botId], !pet.isHidden else { return nil }
            let current = pet.presentation() ?? pet
            guard current.opacity > 0.02 else { return nil }
            let frame = current.convert(current.bounds, to: current.superlayer)
            return SceneInteractionTarget(botID: config.botId, name: identityNames[config.botId] ?? "Bot", state: presenceByBot[config.botId]?.state ?? .idle, frame: frame)
        }
        view.updateTargets(isVisible ? targets : [])
        let mouse = panel.convertPoint(fromScreen: NSEvent.mouseLocation)
        view.updatePointer(at: mouse)
        let ignoresMouseEvents = !isVisible || !view.containsInteractivePoint(mouse)
        if panel.ignoresMouseEvents != ignoresMouseEvents {
            panel.ignoresMouseEvents = ignoresMouseEvents
        }
    }

    private var currentTopology: ScreenTopology {
        let safe = CGRect(
            x: screenFrame.minX + safeAreaInsets.left,
            y: screenFrame.minY + safeAreaInsets.bottom,
            width: screenFrame.width - safeAreaInsets.left - safeAreaInsets.right,
            height: screenFrame.height - safeAreaInsets.top - safeAreaInsets.bottom
        )
        return ScreenTopology(
            screenFrame: screenFrame,
            safeFrame: safe,
            dockEdge: stableDockEdge,
            dockReferenceFrame: stableDockReference,
            scale: panel.backingScaleFactor,
            mainScreenID: "main"
        )
    }

    private func updateStableDockGeometry(frame: CGRect, visibleFrame: CGRect) {
        if let fixture = experienceFixture {
            stableDockEdge = fixture.dockEdge
            stableDockReference = fixture.dockEdge == .bottom
                ? CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: 70)
                : nil
            return
        }
        let left = visibleFrame.minX - frame.minX
        let right = frame.maxX - visibleFrame.maxX
        let bottom = visibleFrame.minY - frame.minY
        if left > 2, left >= right, left >= bottom {
            stableDockEdge = .left
            stableDockReference = CGRect(x: frame.minX, y: frame.minY, width: left, height: frame.height)
        } else if right > 2, right >= bottom {
            stableDockEdge = .right
            stableDockReference = CGRect(x: visibleFrame.maxX, y: frame.minY, width: right, height: frame.height)
        } else if bottom > 2 {
            stableDockEdge = .bottom
            stableDockReference = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: bottom)
        }
        // If all deltas are zero, Dock is transiently hidden; preserve the prior stable reference.
    }

    private func applyExperienceAppearance() {
        let workspace = NSWorkspace.shared
        applyAccessibilityPreferences(
            systemReducedMotion: workspace.accessibilityDisplayShouldReduceMotion,
            systemReducedTransparency: workspace.accessibilityDisplayShouldReduceTransparency
        )
    }

    func applyAccessibilityPreferences(systemReducedMotion: Bool, systemReducedTransparency: Bool) {
        let newReducesMotion = systemReducedMotion || experienceFixture?.reducedMotion == true
        if newReducesMotion != reducesMotion {
            reducesMotion = newReducesMotion
            lastStaticMotion.removeAll()
            for id in motionClocks.keys { motionClocks[id]?.pause() }
            if reducesMotion {
                for pet in petLayers.values where destinations[pet.botId] == nil {
                    idleMotionController.stop(botId: pet.botId)
                    animationCoordinator.cancel(pet: pet)
                }
            }
        }
        fogLayer.updateAppearance(
            wallpaper: experienceFixture?.wallpaper ?? .complex,
            reducedTransparency: systemReducedTransparency || experienceFixture?.reducedTransparency == true
        )
        for pet in petLayers.values { renderMotion(for: pet) }
    }

    private func updateMotionState(_ state: PresenceState, botID: BotID) {
        if motionClocks[botID] == nil { motionClocks[botID] = PresenceMotionClock() }
        if motionClocks[botID]?.setState(state) == true {
            motionSampler.reset(instanceID: botID)
            motionSampler.reset(instanceID: botID + ".focus")
            lastStaticMotion.removeValue(forKey: botID)
            petLayers[botID]?.focusDone(on: nil, duration: 0)
        }
        if let pet = petLayers[botID] { renderMotion(for: pet) }
    }

    /// A single display cadence owns all visible state poses. Layout/edge movement
    /// stays on the parent PetLayer and cannot overwrite a sampled body pose.
    func advanceMotion(now: TimeInterval = CACurrentMediaTime()) {
        let highlighted = (panel.contentView as? InteractiveSceneView)?.highlightedBotID
        for (id, pet) in petLayers {
            let current = pet.presentation() ?? pet
            let onScreen = sceneLayer.bounds.intersects(current.convert(current.bounds, to: current.superlayer))
            let running = isVisible && !pet.isHidden && onScreen && current.opacity > 0.02
                && !reducesMotion && !(highlighted == id && motionClocks[id]?.state == .done)
            motionClocks[id]?.advance(to: now, running: running)
            if isVisible && (running || reducesMotion) { renderMotion(for: pet) }
        }
    }

    private func renderMotion(for pet: PetLayer) {
        guard let clock = motionClocks[pet.botId] else { return }
        if reducesMotion, lastStaticMotion[pet.botId] == clock.state { return }
        if pet.isDoneFocused {
            let frame = motionSampler.sample(shape: pet.shape, state: .done, time: 5.9,
                instanceID: pet.botId + ".focus", reducedMotion: reducesMotion)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            pet.focusDone(on: frame, duration: 0)
            CATransaction.commit()
            if reducesMotion { lastStaticMotion[pet.botId] = clock.state }
            return
        }
        let frame = motionSampler.sample(shape: pet.shape, state: clock.state, time: clock.sampleTime,
                                         instanceID: pet.botId, reducedMotion: reducesMotion)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pet.renderNativeMotion(frame)
        CATransaction.commit()
        if reducesMotion { lastStaticMotion[pet.botId] = clock.state }
    }

    func motionTime(for botID: BotID) -> TimeInterval? { motionClocks[botID]?.elapsed }
    func motionPhaseSlot(for botID: BotID) -> Int? { motionClocks[botID]?.phaseSlot }

    private func focusDoneMotion(_ botID: BotID?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (id, pet) in petLayers {
            let focused = id == botID && motionClocks[id]?.state == .done
            guard focused != pet.isDoneFocused else { continue }
            motionClocks[id]?.pause()
            lastStaticMotion.removeValue(forKey: id)
            // The quiet end of the approved Done phrase faces front without ribbons.
            // Reduced motion retains its approved representative, including recognition.
            let frame = focused ? motionSampler.sample(shape: pet.shape, state: .done, time: 5.9,
                instanceID: id + ".focus", reducedMotion: reducesMotion) : nil
            pet.focusDone(on: frame, duration: reducesMotion ? 0 : 0.18)
            if !focused { motionSampler.reset(instanceID: id + ".focus") }
        }
        CATransaction.commit()
    }

    private var edgeGeometry: EdgeGeometry {
        EdgeGeometry(screenFrame: CGRect(origin: .zero, size: screenFrame.size), visibleFrame: local(visibleFrame), safeAreaInsets: safeAreaInsets, petExtent: 36)
    }

    var currentEdgeGeometry: EdgeGeometry { edgeGeometry }

    private func preset(for id: BotID) -> BehaviorPreset {
        presetCatalog?.preset(for: configurations[id]?.mbti) ?? BehaviorPreset(
            moveWeight: 1, exploreWeight: 1, socialWeight: 1, restWeight: 1,
            speedMultiplier: 1, dwellMultiplier: 1, socialDistance: 52, decorationId: nil
        )
    }

    private func defaultFreePosition(index: Int) -> CGPoint {
        CGPoint(x: 40 + CGFloat(index) * 52, y: max(20, local(visibleFrame).minY))
    }

    private func local(_ rect: CGRect) -> CGRect { rect.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY) }

    private static func makePanel(frame: CGRect) -> NSPanel {
        let panel = DesktopScenePanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        return panel
    }
}
