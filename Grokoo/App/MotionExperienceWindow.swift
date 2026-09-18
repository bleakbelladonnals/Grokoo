import AppKit
import UniformTypeIdentifiers

#if DEBUG
/// A native 8 × 7 review surface. Only the selected cell advances while the rest
/// remain at representative poses, so the overview does not run 56 animations.
@MainActor
final class MotionExperienceWindowController: NSWindowController, NSWindowDelegate {
    let matrixView = MotionExperienceMatrixView()
    private(set) var elapsed: TimeInterval = 0
    private(set) var isPlaying = false
    private var previousTick: TimeInterval?
    private var timer: Timer?
    private let shapeControl = NSPopUpButton()
    private let stateControl = NSPopUpButton()
    private let sizeControl = NSSegmentedControl(labels: ["32 pt", "42 pt"], trackingMode: .selectOne, target: nil, action: nil)
    private let reducedControl = NSButton(checkboxWithTitle: "减少动态效果", target: nil, action: nil)
    private let playControl = NSButton(title: "播放", target: nil, action: nil)
    private let timeControl = NSSlider(value: 0, minValue: 0, maxValue: 20, target: nil, action: nil)
    private let timeLabel = NSTextField(labelWithString: "0.00 秒")

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1052, height: 816),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Grokoo · 原生动作 Experience Check"
        window.appearance = NSAppearance(named: .aqua)
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 1020, height: 580)
        super.init(window: window)
        window.delegate = self
        buildContent(in: window)
        renderSelection()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func open() {
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        synchronizeTimer()
    }

    func shutdown() {
        setPlaying(false)
        close()
    }

    func windowWillClose(_ notification: Notification) { setPlaying(false) }
    func windowDidMiniaturize(_ notification: Notification) { previousTick = nil }
    func windowDidDeminiaturize(_ notification: Notification) { previousTick = nil }

    func select(shape: OfficialShape, state: PresenceState) {
        shapeControl.selectItem(at: OfficialShape.allCases.firstIndex(of: shape) ?? 0)
        stateControl.selectItem(at: PresenceState.allCases.firstIndex(of: state) ?? 0)
        matrixView.select(shape: shape, state: state)
        seek(to: 0)
    }

    func setBodySize(_ size: CGFloat) {
        matrixView.bodySize = size == 32 ? 32 : 42
        sizeControl.selectedSegment = matrixView.bodySize == 32 ? 0 : 1
        matrixView.refreshOverview()
        renderSelection()
    }

    func setReducedMotion(_ value: Bool) {
        matrixView.reducedMotion = value
        reducedControl.state = value ? .on : .off
        previousTick = nil
        matrixView.refreshOverview()
        renderSelection()
        synchronizeTimer()
    }

    func setPlaying(_ value: Bool) {
        isPlaying = value
        playControl.title = value ? "暂停" : "播放"
        previousTick = nil
        synchronizeTimer()
    }

    func seek(to time: TimeInterval) {
        elapsed = max(0, time)
        previousTick = nil
        renderSelection()
    }

    /// Exposed for deterministic lifecycle checks; hidden intervals are ignored.
    func advance(to uptime: TimeInterval, visible: Bool) {
        guard isPlaying, !matrixView.reducedMotion, visible else {
            previousTick = nil
            return
        }
        if let previousTick {
            // A sleep / runloop suspension is not animation time to catch up.
            let delta = uptime - previousTick
            if delta >= 0, delta < 0.5 { elapsed += delta }
        }
        previousTick = uptime
        renderSelection()
    }

    private func buildContent(in window: NSWindow) {
        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = MotionExperienceMatrixView.backgroundColor.cgColor
        window.contentView = content
        let title = NSTextField(labelWithString: "8 种外形 · 7 种状态")
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        let explanation = NSTextField(labelWithString: "选择一格回放动作，其余保持代表姿态。身体按实际 32 / 42 pt 显示。")
        explanation.textColor = .secondaryLabelColor
        explanation.font = .systemFont(ofSize: 12)

        shapeControl.addItems(withTitles: OfficialShape.allCases.map { MotionExperienceMatrixView.shapeTitle($0) })
        stateControl.addItems(withTitles: PresenceState.allCases.map { MotionExperienceMatrixView.stateTitle($0) })
        shapeControl.target = self
        stateControl.target = self
        shapeControl.action = #selector(selectionChanged)
        stateControl.action = #selector(selectionChanged)
        shapeControl.setAccessibilityLabel("回放外形")
        stateControl.setAccessibilityLabel("回放状态")
        stateControl.selectItem(at: 1)
        sizeControl.selectedSegment = 1
        sizeControl.target = self
        sizeControl.action = #selector(sizeChanged)
        sizeControl.setAccessibilityLabel("身体实际尺寸")
        reducedControl.target = self
        reducedControl.action = #selector(reducedChanged)
        playControl.target = self
        playControl.action = #selector(playChanged)
        let restart = NSButton(title: "从头开始", target: self, action: #selector(restartPlayback))
        let export = NSButton(title: "导出原生矩阵…", target: self, action: #selector(exportMatrix))
        let controls = NSStackView(views: [shapeControl, stateControl, sizeControl, reducedControl, playControl, restart, export])
        controls.orientation = .horizontal
        controls.spacing = 10

        timeControl.target = self
        timeControl.action = #selector(timeChanged)
        timeControl.isContinuous = true
        timeControl.setAccessibilityLabel("动作时间，秒")
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        timeLabel.alignment = .right
        timeLabel.widthAnchor.constraint(equalToConstant: 88).isActive = true
        let timeline = NSStackView(views: [NSTextField(labelWithString: "时间"), timeControl, timeLabel])
        timeline.orientation = .horizontal
        timeline.spacing = 10

        let header = NSStackView(views: [title, explanation, controls, timeline])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 10
        header.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(header)
        controls.widthAnchor.constraint(equalTo: header.widthAnchor).isActive = true
        timeline.widthAnchor.constraint(equalTo: header.widthAnchor).isActive = true

        let scroll = NSScrollView()
        scroll.documentView = matrixView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scroll)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        matrixView.onSelect = { [weak self] shape, state in self?.select(shape: shape, state: state) }
        matrixView.scroll(NSPoint(x: 0, y: matrixView.bounds.height))
    }

    private func renderSelection() {
        matrixView.renderSelection(time: elapsed)
        if elapsed > timeControl.maxValue { timeControl.maxValue = ceil(elapsed / 20) * 20 }
        timeControl.doubleValue = elapsed
        timeLabel.stringValue = String(format: "%.2f 秒", elapsed)
    }

    private func synchronizeTimer() {
        timer?.invalidate()
        timer = nil
        guard isPlaying, !matrixView.reducedMotion else { return }
        let next = Timer(timeInterval: 1 / 30, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(next, forMode: .common)
        timer = next
    }

    @objc private func tick() {
        advance(to: ProcessInfo.processInfo.systemUptime,
                visible: window?.isVisible == true && window?.isMiniaturized == false)
    }
    @objc private func selectionChanged() {
        select(shape: OfficialShape.allCases[shapeControl.indexOfSelectedItem],
               state: PresenceState.allCases[stateControl.indexOfSelectedItem])
    }
    @objc private func sizeChanged() { setBodySize(sizeControl.selectedSegment == 0 ? 32 : 42) }
    @objc private func reducedChanged() { setReducedMotion(reducedControl.state == .on) }
    @objc private func playChanged() { setPlaying(!isPlaying) }
    @objc private func restartPlayback() { seek(to: 0); setPlaying(true) }
    @objc private func timeChanged() { setPlaying(false); seek(to: timeControl.doubleValue) }
    @objc private func exportMatrix() {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Grokoo-56-\(Int(matrixView.bodySize))pt.png"
        panel.beginSheetModal(for: window) { [weak self] result in
            guard result == .OK, let url = panel.url, let self else { return }
            do { try self.matrixView.pngData().write(to: url) }
            catch { NSAlert(error: error).runModal() }
        }
    }
}

@MainActor
final class MotionExperienceMatrixView: NSView {
    static let backgroundColor = NSColor(calibratedRed: 0.965, green: 0.98, blue: 0.995, alpha: 1)
    static let canvasSize = NSSize(width: 1020, height: 850)
    static let representativeTimes: [PresenceState: TimeInterval] = [
        .idle: 1, .working: 1.2, .thinking: 2.4, .waiting: 2.4,
        .blocked: 2.4, .done: 4.85, .offline: 0.35
    ]
    private let sampler = NativeMotionSampler()
    private let selectionLayer = CALayer()
    private var cells: [String: NativeMotionLayer] = [:]
    var bodySize: CGFloat = 42
    var reducedMotion = false
    private(set) var selectedShape: OfficialShape = .blob
    private(set) var selectedState: PresenceState = .working
    var onSelect: ((OfficialShape, PresenceState) -> Void)?
    var combinationCount: Int { cells.count }

    init() {
        super.init(frame: NSRect(origin: .zero, size: Self.canvasSize))
        wantsLayer = true
        layer?.backgroundColor = Self.backgroundColor.cgColor
        layer?.masksToBounds = false
        buildGrid()
        refreshOverview()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func select(shape: OfficialShape, state: PresenceState) {
        apply(shape: selectedShape, state: selectedState, time: Self.representativeTimes[selectedState] ?? 0)
        selectedShape = shape
        selectedState = state
        updateSelectionFrame()
        scrollToVisible(cellRect(shape: shape, state: state))
    }

    func refreshOverview() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for shape in OfficialShape.allCases {
            for state in PresenceState.allCases {
                apply(shape: shape, state: state, time: Self.representativeTimes[state] ?? 0)
            }
        }
        updateSelectionFrame()
        CATransaction.commit()
    }

    func renderSelection(time: TimeInterval) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        apply(shape: selectedShape, state: selectedState, time: time)
        CATransaction.commit()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        for shape in OfficialShape.allCases {
            for state in PresenceState.allCases where cellRect(shape: shape, state: state).contains(point) {
                onSelect?(shape, state)
                return
            }
        }
    }

    func pngData() throws -> Data {
        try Self.pngData(layer: layer!, size: bounds.size)
    }

    func cellPNG(shape: OfficialShape, state: PresenceState) throws -> Data {
        let drawing = NativeMotionLayer()
        drawing.apply(frame: sampler.sample(shape: shape, state: state,
                                           time: Self.representativeTimes[state] ?? 0,
                                           instanceID: instanceID(shape), reducedMotion: reducedMotion),
                      color: color(shape).cgColor, bodySize: bodySize)
        let root = CALayer()
        let side = bodySize * 2.4
        root.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        drawing.position = CGPoint(x: side / 2, y: side / 2)
        root.addSublayer(drawing)
        return try Self.pngData(layer: root, size: root.bounds.size)
    }

    private func buildGrid() {
        guard let layer else { return }
        selectionLayer.backgroundColor = NSColor(calibratedRed: 0.88, green: 0.94, blue: 1, alpha: 1).cgColor
        selectionLayer.borderColor = NSColor.systemBlue.withAlphaComponent(0.55).cgColor
        selectionLayer.borderWidth = 1
        selectionLayer.cornerRadius = 5
        layer.addSublayer(selectionLayer)
        for (column, state) in PresenceState.allCases.enumerated() {
            layer.addSublayer(label(Self.stateTitle(state), frame: CGRect(x: 110 + column * 128, y: 804, width: 128, height: 24), size: 13))
        }
        for (row, shape) in OfficialShape.allCases.enumerated() {
            layer.addSublayer(label(Self.shapeTitle(shape), frame: CGRect(x: 8, y: 747 - row * 98, width: 100, height: 24), size: 12))
            let separator = CALayer()
            separator.backgroundColor = NSColor(calibratedWhite: 0.8, alpha: 0.38).cgColor
            separator.frame = CGRect(x: 16, y: CGFloat(710 - row * 98), width: 992, height: 0.5)
            layer.addSublayer(separator)
            for state in PresenceState.allCases {
                let cell = NativeMotionLayer()
                let rect = cellRect(shape: shape, state: state)
                cell.position = CGPoint(x: rect.midX, y: rect.midY)
                layer.addSublayer(cell)
                cells[key(shape, state)] = cell
            }
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("八种官方外形与七种状态，共五十六种组合。使用上方外形和状态菜单选择回放。")
    }

    private func apply(shape: OfficialShape, state: PresenceState, time: TimeInterval) {
        cells[key(shape, state)]?.apply(frame: sampler.sample(shape: shape, state: state,
                                                            time: time, instanceID: instanceID(shape),
                                                            reducedMotion: reducedMotion),
                                       color: color(shape).cgColor, bodySize: bodySize)
    }

    private func updateSelectionFrame() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        selectionLayer.frame = cellRect(shape: selectedShape, state: selectedState).insetBy(dx: 8, dy: 5)
        CATransaction.commit()
    }

    private func cellRect(shape: OfficialShape, state: PresenceState) -> CGRect {
        let row = OfficialShape.allCases.firstIndex(of: shape) ?? 0
        let column = PresenceState.allCases.firstIndex(of: state) ?? 0
        return CGRect(x: 110 + column * 128, y: 712 - row * 98, width: 128, height: 98)
    }

    private func color(_ shape: OfficialShape) -> OfficialColor {
        let palette: [OfficialColor] = [.blue, .cyan, .violet, .orange, .green, .magenta, .brown, .red]
        return palette[OfficialShape.allCases.firstIndex(of: shape) ?? 0]
    }
    private func key(_ shape: OfficialShape, _ state: PresenceState) -> String { "\(shape.rawValue)-\(state.rawValue)" }
    private func instanceID(_ shape: OfficialShape) -> String { "experience-\(shape.rawValue)" }

    private func label(_ text: String, frame: CGRect, size: CGFloat) -> CATextLayer {
        let label = CATextLayer()
        label.frame = frame
        label.string = text
        label.font = NSFont.systemFont(ofSize: size, weight: .medium)
        label.fontSize = size
        label.alignmentMode = .center
        label.foregroundColor = NSColor(calibratedWhite: 0.18, alpha: 1).cgColor
        label.contentsScale = 2
        return label
    }

    private static func pngData(layer: CALayer, size: CGSize) throws -> Data {
        let width = Int(ceil(size.width * 2)), height = Int(ceil(size.height * 2))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CocoaError(.fileWriteUnknown)
        }
        context.scaleBy(x: 2, y: 2)
        layer.render(in: context)
        guard let image = context.makeImage(),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
    }

    static func shapeTitle(_ shape: OfficialShape) -> String {
        switch shape {
        case .blob: "圆形"
        case .pebble: "鹅卵石"
        case .squircle: "方圆形"
        case .tablet: "胶囊"
        case .wedge: "三角形"
        case .hex: "六边形"
        case .cloud: "云朵"
        case .teardrop: "水滴"
        }
    }
    static func stateTitle(_ state: PresenceState) -> String {
        switch state {
        case .idle: "空闲"
        case .working: "工作中"
        case .thinking: "思考中"
        case .waiting: "等待回应"
        case .blocked: "受阻"
        case .done: "已完成"
        case .offline: "离线"
        }
    }
}
#endif
