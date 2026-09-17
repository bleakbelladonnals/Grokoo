import AppKit
import QuartzCore

final class WorkstationLayer: CALayer {
    private let baseLayer = CAShapeLayer()
    private let statusLight = CAShapeLayer()

    override init() {
        super.init()
        addSublayer(baseLayer)
        addSublayer(statusLight)
        opacity = 0
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { nil }

    func configure(frame: CGRect, color: OfficialColor) {
        self.frame = frame
        baseLayer.frame = bounds
        baseLayer.path = CGPath(roundedRect: bounds, cornerWidth: 4, cornerHeight: 4, transform: nil)
        baseLayer.fillColor = NSColor(calibratedWhite: 0.15, alpha: 0.28).cgColor
        statusLight.frame = CGRect(x: 4, y: bounds.midY - 0.75, width: max(1, bounds.width - 8), height: 1.5)
        statusLight.path = CGPath(roundedRect: statusLight.bounds, cornerWidth: 0.75, cornerHeight: 0.75, transform: nil)
        statusLight.fillColor = color.cgColor
    }

    func setState(_ state: PresenceState) {
        removeAllAnimations()
        statusLight.removeAllAnimations()
        statusLight.opacity = 1
        switch state {
        case .idle, .offline:
            opacity = 0
        case .working, .thinking:
            opacity = 1
            let flow = CABasicAnimation(keyPath: "transform.translation.x")
            flow.fromValue = -3
            flow.toValue = 3
            flow.duration = 1.8
            flow.autoreverses = true
            flow.repeatCount = .infinity
            statusLight.add(flow, forKey: "workingFlow")
        case .waiting, .blocked:
            opacity = 1
            statusLight.opacity = 0.75
        case .done:
            opacity = 1
            let flash = CAKeyframeAnimation(keyPath: "opacity")
            flash.values = [1, 0.25, 1]
            flash.duration = 0.45
            flash.repeatCount = 3
            statusLight.add(flash, forKey: "doneFlash")
        }
    }

    func cancelAnimations() {
        removeAllAnimations()
        baseLayer.removeAllAnimations()
        statusLight.removeAllAnimations()
    }
}
