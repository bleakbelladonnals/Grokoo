import AppKit
import QuartzCore

final class PetLayer: CALayer {
    static let bodySize = CGSize(width: 32, height: 32)
    static let decoratedSize = CGSize(width: 36, height: 36)

    let botId: BotID
    let bodyShapeLayer = CAShapeLayer()
    let faceLayer = FaceLayer()
    let stateDecorationLayer = CAShapeLayer()
    let mbtiDecorationLayer = DecorationLayer()

    private let shapeEngine = BloubShapeEngine()
    private(set) var shape: OfficialShape
    private(set) var color: OfficialColor

    init(identity: BotIdentity) {
        botId = identity.id
        shape = identity.shape
        color = identity.color
        super.init()
        bounds = CGRect(origin: .zero, size: Self.decoratedSize)
        anchorPoint = CGPoint(x: 0.5, y: 0)
        contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        bodyShapeLayer.frame = CGRect(x: 2, y: 2, width: 32, height: 32)
        faceLayer.frame = bodyShapeLayer.frame
        stateDecorationLayer.frame = bounds
        mbtiDecorationLayer.frame = bounds
        addSublayer(bodyShapeLayer)
        addSublayer(faceLayer)
        addSublayer(stateDecorationLayer)
        addSublayer(mbtiDecorationLayer)
        updateAppearance(shape: shape, color: color)
    }

    override init(layer: Any) {
        if let source = layer as? PetLayer {
            botId = source.botId
            shape = source.shape
            color = source.color
        } else {
            botId = "presentation-copy"
            shape = .blob
            color = .blue
        }
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { nil }

    func updateAppearance(shape: OfficialShape, color: OfficialColor) {
        self.shape = shape
        self.color = color
        bodyShapeLayer.path = shapeEngine.path(for: shape, in: bodyShapeLayer.bounds.insetBy(dx: 0.8, dy: 0.8))
        bodyShapeLayer.fillColor = color.cgColor
        faceLayer.configure(shape: shape, bodyColor: color.nsColor)
        faceLayer.setNeedsLayout()
        mbtiDecorationLayer.configure(id: mbtiDecorationLayer.decorationID?.rawValue, shape: shape, contrastColor: color.nsColor.contrastingMonochrome)
    }

    func setMBTIDecoration(_ id: String?) {
        mbtiDecorationLayer.configure(id: id, shape: shape, contrastColor: color.nsColor.contrastingMonochrome)
    }

    func showStateMarker(_ state: PresenceState) {
        stateDecorationLayer.path = nil
        stateDecorationLayer.opacity = 1
        stateDecorationLayer.fillColor = nil
        stateDecorationLayer.strokeColor = nil
        stateDecorationLayer.lineWidth = 0
        switch state {
        case .thinking:
            let marker = CGMutablePath()
            marker.addEllipse(in: CGRect(x: 27, y: 29, width: 2.4, height: 2.4))
            marker.addEllipse(in: CGRect(x: 31, y: 29, width: 2.4, height: 2.4))
            stateDecorationLayer.path = marker
            stateDecorationLayer.fillColor = color.nsColor.contrastingMonochrome.cgColor
        case .waiting:
            let marker = CGMutablePath()
            marker.move(to: CGPoint(x: 28.5, y: 32))
            marker.addCurve(to: CGPoint(x: 31, y: 29), control1: CGPoint(x: 29, y: 36), control2: CGPoint(x: 35, y: 33))
            marker.addEllipse(in: CGRect(x: 30.3, y: 26.5, width: 1.4, height: 1.4))
            stateDecorationLayer.path = marker
            stateDecorationLayer.strokeColor = color.nsColor.contrastingMonochrome.cgColor
            stateDecorationLayer.lineWidth = 1.2
        case .done:
            let marker = CGMutablePath()
            marker.move(to: CGPoint(x: 27, y: 31))
            marker.addLine(to: CGPoint(x: 30, y: 28))
            marker.addLine(to: CGPoint(x: 35, y: 34))
            stateDecorationLayer.path = marker
            stateDecorationLayer.strokeColor = color.nsColor.contrastingMonochrome.cgColor
            stateDecorationLayer.lineWidth = 1.6
            stateDecorationLayer.lineCap = .round
            stateDecorationLayer.lineJoin = .round
        case .blocked:
            let marker = CGMutablePath()
            marker.move(to: CGPoint(x: 31, y: 29))
            marker.addLine(to: CGPoint(x: 31, y: 33))
            marker.addEllipse(in: CGRect(x: 30.3, y: 34, width: 1.4, height: 1.4))
            stateDecorationLayer.path = marker
            stateDecorationLayer.strokeColor = color.nsColor.contrastingMonochrome.cgColor
            stateDecorationLayer.lineWidth = 1.2
        case .offline:
            let marker = CGMutablePath()
            marker.move(to: CGPoint(x: 28, y: 30)); marker.addLine(to: CGPoint(x: 34, y: 34))
            marker.move(to: CGPoint(x: 34, y: 30)); marker.addLine(to: CGPoint(x: 28, y: 34))
            stateDecorationLayer.path = marker
            stateDecorationLayer.strokeColor = color.nsColor.contrastingMonochrome.cgColor
            stateDecorationLayer.lineWidth = 1.2
            stateDecorationLayer.fillColor = nil
        default:
            break
        }
    }
}
