import AppKit
import QuartzCore

/// Retained native layers: back ribbons → body → clipped white eyes → marks →
/// front ribbons. The safe canvas never becomes a hit target or layout input.
final class NativeMotionLayer: CALayer {
    // Presentation copies inherit Core Animation's layer tree. Do not allocate
    // a second, unused drawing tree while init(layer:) copies presentation state.
    private lazy var back = CALayer()
    private lazy var body = CAShapeLayer()
    private lazy var eyeContainer = CALayer()
    private lazy var eyeMask = CAShapeLayer()
    private lazy var markContainer = CALayer()
    private lazy var front = CALayer()
    private var eyeLayers: [CAShapeLayer] = []
    private var markLayers: [CAShapeLayer] = []
    private var backLayers: [NativeRibbonLayer] = []
    private var frontLayers: [NativeRibbonLayer] = []
    private(set) var motionFrame: NativeMotionFrame?

    override init() {
        super.init()
        masksToBounds = false
        allowsGroupOpacity = true
        contentsScale = 2
        for layer in [back, body, eyeContainer, markContainer, front] { addSublayer(layer) }
        eyeContainer.mask = eyeMask
    }
    override init(layer: Any) {
        super.init(layer: layer)
        if let source = layer as? NativeMotionLayer { motionFrame = source.motionFrame }
    }
    required init?(coder: NSCoder) { nil }

    func apply(frame: NativeMotionFrame, color: CGColor, bodySize: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        motionFrame = frame
        let side = bodySize * 2.4
        let canvasBounds = CGRect(x: 0, y: 0, width: side, height: side)
        if bounds != canvasBounds { bounds = canvasBounds }
        if opacity != Float(frame.opacity) { opacity = Float(frame.opacity) }
        let scale = bodySize * 1.09 / 259
        let matrix = CGAffineTransform(a: scale, b: 0, c: 0, d: -scale, tx: side/2, ty: side/2)
        for layer in [back, body, eyeContainer, markContainer, front, eyeMask] {
            if layer.frame != canvasBounds { layer.frame = canvasBounds }
            if layer.contentsScale != contentsScale { layer.contentsScale = contentsScale }
        }
        body.path = nativeTransform(frame.bodyPath, matrix)
        if body.fillColor != color { body.fillColor = color }
        eyeMask.path = body.path
        let white = CGColor(gray: 1, alpha: 1)
        if eyeMask.fillColor != white { eyeMask.fillColor = white }
        updatePaths(frame.eyes, layers: &eyeLayers, parent: eyeContainer, color: white, transform: matrix)
        updatePaths(frame.marks, layers: &markLayers, parent: markContainer, color: color, transform: matrix)
        updateRibbons(frame.backRibbons, layers: &backLayers, parent: back, transform: matrix)
        updateRibbons(frame.frontRibbons, layers: &frontLayers, parent: front, transform: matrix)
    }

    private func updatePaths(_ paints: [NativePaintPath], layers: inout [CAShapeLayer], parent: CALayer, color: CGColor, transform: CGAffineTransform) {
        while layers.count < paints.count { let layer = CAShapeLayer(); layer.contentsScale = contentsScale; parent.addSublayer(layer); layers.append(layer) }
        for (index, layer) in layers.enumerated() {
            let hidden = index >= paints.count
            if layer.isHidden != hidden { layer.isHidden = hidden }
            guard index < paints.count else { continue }
            if layer.frame != bounds { layer.frame = bounds }
            layer.path = nativeTransform(paints[index].path, transform)
            if layer.fillColor != color { layer.fillColor = color }
            if layer.opacity != Float(paints[index].opacity) { layer.opacity = Float(paints[index].opacity) }
        }
    }
    private func updateRibbons(_ paints: [NativeRibbonPaint], layers: inout [NativeRibbonLayer], parent: CALayer, transform: CGAffineTransform) {
        while layers.count < paints.count { let layer = NativeRibbonLayer(); parent.addSublayer(layer); layers.append(layer) }
        for (index, layer) in layers.enumerated() {
            let hidden = index >= paints.count
            if layer.isHidden != hidden { layer.isHidden = hidden }
            guard index < paints.count else { continue }
            if layer.frame != bounds { layer.frame = bounds }
            layer.apply(paints[index], transform: transform)
        }
    }
}

private final class NativeRibbonLayer: CAGradientLayer {
    private lazy var contour = CAShapeLayer()
    override init() {
        super.init()
        locations = [0, 0.25, 0.5, 0.75, 1]
        mask = contour
    }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { nil }
    func apply(_ paint: NativeRibbonPaint, transform: CGAffineTransform) {
        if contour.frame != bounds { contour.frame = bounds }
        contour.path = nativeTransform(paint.path, transform)
        let white = CGColor(gray: 1, alpha: 1)
        if contour.fillColor != white { contour.fillColor = white }
        colors = paint.colors
        if opacity != Float(paint.opacity) { opacity = Float(paint.opacity) }
        let start = paint.start.applying(transform), end = paint.end.applying(transform)
        startPoint = CGPoint(x: start.x/bounds.width, y: start.y/bounds.height)
        endPoint = CGPoint(x: end.x/bounds.width, y: end.y/bounds.height)
    }
}
