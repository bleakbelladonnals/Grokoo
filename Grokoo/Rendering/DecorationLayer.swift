import AppKit
import QuartzCore

enum DecorationID: String, Codable, CaseIterable, Sendable {
    case bentBrow = "bent-brow"
    case butterfly
    case nurseCap = "nurse-cap"
    case tinyDrill = "tiny-drill"
}

struct DecorationAnchor: Equatable, Sendable {
    var point: CGPoint
    var rotation: CGFloat
}

final class DecorationLayer: CAShapeLayer {
    private(set) var decorationID: DecorationID?

    override init() {
        super.init()
    }

    override init(layer: Any) {
        decorationID = (layer as? DecorationLayer)?.decorationID
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { nil }

    func configure(id: String?, shape: OfficialShape, contrastColor: NSColor) {
        decorationID = id.flatMap(DecorationID.init(rawValue:))
        guard let decorationID else {
            isHidden = true
            path = nil
            return
        }
        isHidden = false
        let anchor = Self.anchor(for: decorationID, shape: shape)
        let size = Self.size(for: decorationID)
        bounds = CGRect(origin: .zero, size: size)
        setAffineTransform(CGAffineTransform(rotationAngle: anchor.rotation))
        let parentSize = superlayer?.bounds.size ?? CGSize(width: 36, height: 36)
        let halfWidth = abs(cos(anchor.rotation)) * size.width / 2
            + abs(sin(anchor.rotation)) * size.height / 2 + 0.8
        let halfHeight = abs(sin(anchor.rotation)) * size.width / 2
            + abs(cos(anchor.rotation)) * size.height / 2 + 0.8
        position = CGPoint(
            x: min(max(parentSize.width * anchor.point.x, halfWidth), parentSize.width - halfWidth),
            y: min(max(parentSize.height * anchor.point.y, halfHeight), parentSize.height - halfHeight)
        )
        path = Self.path(for: decorationID, in: bounds)
        fillColor = decorationID == .butterfly ? contrastColor.withAlphaComponent(0.12).cgColor : NSColor.clear.cgColor
        strokeColor = contrastColor.cgColor
        lineWidth = 1.2
        lineCap = .round
        lineJoin = .round
        contentsScale = NSScreen.main?.backingScaleFactor ?? 2
    }

    static func anchor(for decoration: DecorationID, shape: OfficialShape) -> DecorationAnchor {
        let corrections: [OfficialShape: [DecorationID: DecorationAnchor]] = [
            .blob: [.bentBrow: .init(point: .init(x: 0.50, y: 0.67), rotation: 0), .butterfly: .init(point: .init(x: 0.84, y: 0.81), rotation: 0.08), .nurseCap: .init(point: .init(x: 0.50, y: 0.91), rotation: 0), .tinyDrill: .init(point: .init(x: 0.91, y: 0.42), rotation: -0.12)],
            .pebble: [.bentBrow: .init(point: .init(x: 0.50, y: 0.66), rotation: 0.02), .butterfly: .init(point: .init(x: 0.84, y: 0.79), rotation: 0.08), .nurseCap: .init(point: .init(x: 0.49, y: 0.90), rotation: 0.03), .tinyDrill: .init(point: .init(x: 0.91, y: 0.43), rotation: -0.08)],
            .squircle: [.bentBrow: .init(point: .init(x: 0.50, y: 0.65), rotation: 0), .butterfly: .init(point: .init(x: 0.84, y: 0.84), rotation: 0.06), .nurseCap: .init(point: .init(x: 0.50, y: 0.94), rotation: 0), .tinyDrill: .init(point: .init(x: 0.94, y: 0.43), rotation: -0.10)],
            .tablet: [.bentBrow: .init(point: .init(x: 0.50, y: 0.64), rotation: 0), .butterfly: .init(point: .init(x: 0.89, y: 0.79), rotation: 0.05), .nurseCap: .init(point: .init(x: 0.50, y: 0.87), rotation: 0), .tinyDrill: .init(point: .init(x: 0.97, y: 0.43), rotation: -0.08)],
            .wedge: [.bentBrow: .init(point: .init(x: 0.50, y: 0.56), rotation: 0), .butterfly: .init(point: .init(x: 0.91, y: 0.70), rotation: 0.12), .nurseCap: .init(point: .init(x: 0.50, y: 0.83), rotation: 0), .tinyDrill: .init(point: .init(x: 0.91, y: 0.35), rotation: -0.16)],
            .hex: [.bentBrow: .init(point: .init(x: 0.50, y: 0.64), rotation: 0), .butterfly: .init(point: .init(x: 0.87, y: 0.76), rotation: 0.09), .nurseCap: .init(point: .init(x: 0.50, y: 0.88), rotation: 0), .tinyDrill: .init(point: .init(x: 0.92, y: 0.42), rotation: -0.10)],
            .cloud: [.bentBrow: .init(point: .init(x: 0.50, y: 0.61), rotation: 0), .butterfly: .init(point: .init(x: 0.86, y: 0.79), rotation: 0.10), .nurseCap: .init(point: .init(x: 0.45, y: 0.87), rotation: -0.03), .tinyDrill: .init(point: .init(x: 0.91, y: 0.39), rotation: -0.11)],
            .teardrop: [.bentBrow: .init(point: .init(x: 0.50, y: 0.54), rotation: 0), .butterfly: .init(point: .init(x: 0.88, y: 0.68), rotation: 0.12), .nurseCap: .init(point: .init(x: 0.35, y: 0.78), rotation: -0.12), .tinyDrill: .init(point: .init(x: 0.85, y: 0.34), rotation: -0.18)]
        ]
        return corrections[shape]?[decoration] ?? .init(point: .init(x: 0.5, y: 0.5), rotation: 0)
    }

    private static func size(for id: DecorationID) -> CGSize {
        switch id {
        case .bentBrow: CGSize(width: 13, height: 6)
        case .butterfly: CGSize(width: 9, height: 8)
        case .nurseCap: CGSize(width: 12, height: 8)
        case .tinyDrill: CGSize(width: 12, height: 7)
        }
    }

    private static func path(for id: DecorationID, in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        switch id {
        case .bentBrow:
            path.move(to: CGPoint(x: 0.5, y: 1.5)); path.addLine(to: CGPoint(x: 4, y: 4.8)); path.addLine(to: CGPoint(x: 6.2, y: 2.4))
            path.move(to: CGPoint(x: 6.8, y: 2.4)); path.addLine(to: CGPoint(x: 9, y: 4.8)); path.addLine(to: CGPoint(x: 12.5, y: 1.5))
        case .butterfly:
            path.move(to: CGPoint(x: 4.5, y: 4));
            path.addCurve(to: CGPoint(x: 0.6, y: 6.6), control1: CGPoint(x: 2.8, y: 7.8), control2: CGPoint(x: 0.4, y: 8))
            path.addCurve(to: CGPoint(x: 4.3, y: 3.3), control1: CGPoint(x: -0.1, y: 3.9), control2: CGPoint(x: 2.1, y: 1.2))
            path.addCurve(to: CGPoint(x: 8.4, y: 6.6), control1: CGPoint(x: 6.9, y: 1.2), control2: CGPoint(x: 9.1, y: 3.9))
            path.addCurve(to: CGPoint(x: 4.5, y: 4), control1: CGPoint(x: 8.6, y: 8), control2: CGPoint(x: 6.1, y: 7.8)); path.closeSubpath()
            path.move(to: CGPoint(x: 4.5, y: 1)); path.addLine(to: CGPoint(x: 4.5, y: 7))
        case .nurseCap:
            path.move(to: CGPoint(x: 0.7, y: 1)); path.addLine(to: CGPoint(x: 11.3, y: 1)); path.addLine(to: CGPoint(x: 10, y: 7)); path.addLine(to: CGPoint(x: 2, y: 7)); path.closeSubpath()
            path.move(to: CGPoint(x: 6, y: 2.3)); path.addLine(to: CGPoint(x: 6, y: 5.7)); path.move(to: CGPoint(x: 4.3, y: 4)); path.addLine(to: CGPoint(x: 7.7, y: 4))
        case .tinyDrill:
            path.move(to: CGPoint(x: 0.7, y: 2)); path.addLine(to: CGPoint(x: 6.8, y: 2)); path.addLine(to: CGPoint(x: 9.5, y: 3.5)); path.addLine(to: CGPoint(x: 6.8, y: 5)); path.addLine(to: CGPoint(x: 0.7, y: 5)); path.closeSubpath()
            path.move(to: CGPoint(x: 9.5, y: 3.5)); path.addLine(to: CGPoint(x: 11.6, y: 3.5)); path.move(to: CGPoint(x: 3.2, y: 5)); path.addLine(to: CGPoint(x: 4.8, y: 6.7))
        }
        return path
    }
}
