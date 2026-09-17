import AppKit
import QuartzCore

struct EyeFit: Equatable, Sendable {
    var centerOffset: CGPoint
    var spacing: CGFloat
    var eyeSize: CGSize
}

final class FaceLayer: CALayer {
    private let leftEye = CAShapeLayer()
    private let rightEye = CAShapeLayer()
    private(set) var shape: OfficialShape = .blob
    private(set) var gazeOffset: CGPoint = .zero
    private var bodyColor: NSColor = .black

    override init() {
        super.init()
        addSublayer(leftEye)
        addSublayer(rightEye)
        actions = ["bounds": NSNull(), "position": NSNull()]
    }

    override init(layer: Any) {
        if let source = layer as? FaceLayer {
            shape = source.shape
            bodyColor = source.bodyColor
            gazeOffset = source.gazeOffset
        }
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { nil }

    func configure(shape: OfficialShape, bodyColor: NSColor) {
        self.shape = shape
        self.bodyColor = bodyColor
        setNeedsLayout()
    }

    override func layoutSublayers() {
        super.layoutSublayers()
        let fit = Self.eyeFit(for: shape, bodyBounds: bounds)
        let centers = [
            CGPoint(x: bounds.midX - fit.spacing / 2 + fit.centerOffset.x, y: bounds.midY + fit.centerOffset.y),
            CGPoint(x: bounds.midX + fit.spacing / 2 + fit.centerOffset.x, y: bounds.midY + fit.centerOffset.y)
        ]
        let eyeColor = bodyColor.contrastingMonochrome.cgColor
        for (layer, center) in zip([leftEye, rightEye], centers) {
            let frame = CGRect(
                x: center.x - fit.eyeSize.width / 2,
                y: center.y - fit.eyeSize.height / 2,
                width: fit.eyeSize.width,
                height: fit.eyeSize.height
            )
            layer.frame = frame
            layer.path = CGPath(roundedRect: layer.bounds, cornerWidth: fit.eyeSize.width / 2, cornerHeight: fit.eyeSize.width / 2, transform: nil)
            layer.fillColor = eyeColor
        }
    }

    func setGaze(x: CGFloat, y: CGFloat, animated: Bool = true) {
        gazeOffset = CGPoint(x: min(max(x, -1.2), 1.2), y: min(max(y, -1), 1))
        let translation = CATransform3DMakeTranslation(gazeOffset.x, gazeOffset.y, 0)
        let changes = { [leftEye, rightEye] in
            leftEye.transform = translation
            rightEye.transform = translation
        }
        if animated {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.25)
            changes()
            CATransaction.commit()
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            changes()
            CATransaction.commit()
        }
    }

    func blink(duration: TimeInterval = 0.14) {
        let scale = CABasicAnimation(keyPath: "transform.scale.y")
        scale.fromValue = 1
        scale.toValue = 0.06
        scale.duration = max(0.05, duration / 2)
        scale.autoreverses = true
        scale.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        leftEye.add(scale, forKey: "blink")
        rightEye.add(scale, forKey: "blink")
    }

    func animateIdleLiveliness(duration: TimeInterval, phase: Double) {
        let drift = CAKeyframeAnimation(keyPath: "transform.translation")
        drift.values = [
            NSValue(point: CGPoint(x: -0.55, y: 0.15)),
            NSValue(point: CGPoint(x: 0.65, y: -0.25)),
            NSValue(point: CGPoint(x: -0.55, y: 0.15))
        ]
        drift.keyTimes = [0, 0.52, 1]
        drift.duration = duration * 2.7
        drift.repeatCount = .infinity
        drift.beginTime = CACurrentMediaTime() + phase
        drift.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        add(drift, forKey: "idleGaze")

        let blink = CAKeyframeAnimation(keyPath: "transform.scale.y")
        blink.values = [1, 1, 0.06, 1, 1]
        blink.keyTimes = [0, 0.90, 0.93, 0.96, 1]
        blink.duration = max(2.4, duration * 1.15)
        blink.repeatCount = .infinity
        blink.beginTime = CACurrentMediaTime() + phase * 0.73
        add(blink, forKey: "idleBlink")
    }

    func animateWorkBlink(duration: TimeInterval, phase: Double) {
        let blink = CAKeyframeAnimation(keyPath: "transform.scale.y")
        blink.values = [1, 1, 0.08, 1, 1]
        blink.keyTimes = [0, 0.86, 0.90, 0.94, 1]
        blink.duration = max(2.2, duration * 1.45)
        blink.repeatCount = .infinity
        blink.beginTime = CACurrentMediaTime() + phase
        add(blink, forKey: "workBlink")
    }

    func setClosed(_ closed: Bool) {
        let scale = closed ? CATransform3DMakeScale(1, 0.08, 1) : CATransform3DIdentity
        leftEye.transform = scale
        rightEye.transform = scale
    }

    static func eyeFit(for shape: OfficialShape, bodyBounds: CGRect) -> EyeFit {
        // Stable, shape-specific offsets are resolved once per layout. This follows
        // Bloub eyefit's key rule: never solve against animated gaze every frame.
        let unit = min(bodyBounds.width, bodyBounds.height) / 32
        switch shape {
        case .blob: return EyeFit(centerOffset: CGPoint(x: 0.4 * unit, y: 1.3 * unit), spacing: 8.4 * unit, eyeSize: CGSize(width: 3.5 * unit, height: 7.0 * unit))
        case .pebble: return EyeFit(centerOffset: CGPoint(x: 0.2 * unit, y: 1.1 * unit), spacing: 8.0 * unit, eyeSize: CGSize(width: 3.4 * unit, height: 6.8 * unit))
        case .squircle: return EyeFit(centerOffset: CGPoint(x: 0, y: 0.7 * unit), spacing: 8.2 * unit, eyeSize: CGSize(width: 3.4 * unit, height: 6.8 * unit))
        case .tablet: return EyeFit(centerOffset: CGPoint(x: 0, y: 0.5 * unit), spacing: 8.8 * unit, eyeSize: CGSize(width: 3.2 * unit, height: 6.4 * unit))
        case .wedge: return EyeFit(centerOffset: CGPoint(x: 0, y: 3.0 * unit), spacing: 7.0 * unit, eyeSize: CGSize(width: 3.0 * unit, height: 5.8 * unit))
        case .hex: return EyeFit(centerOffset: CGPoint(x: 0, y: 1.0 * unit), spacing: 7.8 * unit, eyeSize: CGSize(width: 3.3 * unit, height: 6.5 * unit))
        case .cloud: return EyeFit(centerOffset: CGPoint(x: 0, y: 2.4 * unit), spacing: 7.4 * unit, eyeSize: CGSize(width: 3.1 * unit, height: 6.0 * unit))
        case .teardrop: return EyeFit(centerOffset: CGPoint(x: 0, y: 3.5 * unit), spacing: 6.8 * unit, eyeSize: CGSize(width: 2.9 * unit, height: 5.6 * unit))
        }
    }
}
