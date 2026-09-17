import CoreGraphics
import Foundation

/// Native rewrite of the radial-profile and Catmull-Rom path math in Bloub
/// commit b4bb3c1b5f93c7b87a2e8d620f667c4093d97749.
struct BloubShapeEngine: Sendable {
    static let sampleCount = 64
    private static let tau = Double.pi * 2

    struct Silhouette: Equatable, Sendable {
        var radii: [CGFloat]
        var rotation: CGFloat = 0
        var center: CGPoint = .zero
        var scaleX: CGFloat = 1
        var scaleY: CGFloat = 1
    }

    func silhouette(for shape: OfficialShape) -> Silhouette {
        Silhouette(radii: Self.profile(for: shape))
    }

    func points(for silhouette: Silhouette, in rect: CGRect) -> [CGPoint] {
        precondition(silhouette.radii.count == Self.sampleCount)
        let radius = min(rect.width, rect.height) / 2
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let cosine = cos(silhouette.rotation)
        let sine = sin(silhouette.rotation)
        return silhouette.radii.enumerated().map { index, radial in
            let angle = CGFloat(index) / CGFloat(Self.sampleCount) * .pi * 2
            let x = radial * cos(angle)
            let y = radial * sin(angle)
            let rotatedX = x * cosine - y * sine
            let rotatedY = x * sine + y * cosine
            return CGPoint(
                x: center.x + (rotatedX * silhouette.scaleX + silhouette.center.x) * radius,
                y: center.y + (rotatedY * silhouette.scaleY + silhouette.center.y) * radius
            )
        }
    }

    func path(for shape: OfficialShape, in rect: CGRect) -> CGPath {
        closedPath(points(for: silhouette(for: shape), in: rect))
    }

    func path(for silhouette: Silhouette, in rect: CGRect) -> CGPath {
        closedPath(points(for: silhouette, in: rect))
    }

    func blend(_ from: Silhouette, _ to: Silhouette, progress rawProgress: CGFloat) -> Silhouette {
        let progress = min(max(rawProgress, 0), 1)
        var deltaRotation = to.rotation - from.rotation
        while deltaRotation > .pi { deltaRotation -= .pi * 2 }
        while deltaRotation < -.pi { deltaRotation += .pi * 2 }
        return Silhouette(
            radii: zip(from.radii, to.radii).map { $0 + ($1 - $0) * progress },
            rotation: from.rotation + deltaRotation * progress,
            center: CGPoint(
                x: from.center.x + (to.center.x - from.center.x) * progress,
                y: from.center.y + (to.center.y - from.center.y) * progress
            ),
            scaleX: from.scaleX + (to.scaleX - from.scaleX) * progress,
            scaleY: from.scaleY + (to.scaleY - from.scaleY) * progress
        )
    }

    func radius(in direction: CGFloat, silhouette: Silhouette) -> CGFloat {
        let count = silhouette.radii.count
        guard count > 1 else { return silhouette.radii.first ?? 1 }
        let normalized = direction.truncatingRemainder(dividingBy: .pi * 2) / (.pi * 2)
        let positive = normalized < 0 ? normalized + 1 : normalized
        let offset = positive * CGFloat(count)
        let lower = Int(floor(offset)) % count
        let upper = (lower + 1) % count
        let fraction = offset - CGFloat(lower)
        return silhouette.radii[lower] + (silhouette.radii[upper] - silhouette.radii[lower]) * fraction
    }

    private func closedPath(_ points: [CGPoint], tension: CGFloat = 1 / 6) -> CGPath {
        let path = CGMutablePath()
        guard points.count >= 3, let first = points.first else { return path }
        path.move(to: first)
        for index in points.indices {
            let p0 = points[(index - 1 + points.count) % points.count]
            let p1 = points[index]
            let p2 = points[(index + 1) % points.count]
            let p3 = points[(index + 2) % points.count]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) * tension, y: p1.y + (p2.y - p0.y) * tension)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) * tension, y: p2.y - (p3.y - p1.y) * tension)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        path.closeSubpath()
        return path
    }

    private static func profile(for shape: OfficialShape) -> [CGFloat] {
        let angles = (0..<sampleCount).map { Double($0) / Double(sampleCount) * tau }
        switch shape {
        case .blob:
            return Array(repeating: 1, count: sampleCount)
        case .pebble:
            return normalize(angles.map { CGFloat(1 + 0.075 * cos(2 * $0 + 0.5) + 0.035 * cos(3 * $0 + 2.1)) }, max: 1.02)
        case .squircle:
            return normalize(angles.map { angle in
                let sum = pow(abs(cos(angle)), 4.2) + pow(abs(sin(angle)), 4.2)
                return CGFloat(pow(sum, -1 / 4.2))
            }, max: 1.15)
        case .tablet:
            return capsuleProfile(left: (-0.42, 0, 0.62), right: (0.42, 0, 0.62))
        case .wedge:
            return regularPolygonProfile(sides: 3, radius: 1.12, cornerRadius: 0.34, rotation: -.pi / 2)
        case .hex:
            return regularPolygonProfile(sides: 6, radius: 1.04, cornerRadius: 0.26, rotation: 0)
        case .cloud:
            return normalize(unionOfCirclesProfile([
                (-0.44, 0.20, 0.54), (0.46, 0.20, 0.50), (0.02, 0.30, 0.60),
                (-0.24, -0.30, 0.48), (0.30, -0.24, 0.44)
            ]), max: 1.02)
        case .teardrop:
            return normalize(capsuleProfile(left: (0, 0.28, 0.66), right: (0, -0.96, 0.05)), max: 1.04)
        }
    }

    private static func normalize(_ values: [CGFloat], max target: CGFloat) -> [CGFloat] {
        let peak = values.max() ?? 1
        guard peak > 0 else { return values }
        return values.map { $0 / peak * target }
    }

    private static func unionOfCirclesProfile(_ circles: [(Double, Double, Double)]) -> [CGFloat] {
        (0..<sampleCount).map { index in
            let angle = Double(index) / Double(sampleCount) * tau
            let dx = cos(angle), dy = sin(angle)
            var best = 0.0
            for (x, y, radius) in circles {
                let projection = dx * x + dy * y
                let discriminant = projection * projection - (x * x + y * y - radius * radius)
                if discriminant >= 0 { best = Swift.max(best, projection + sqrt(discriminant)) }
            }
            return CGFloat(best)
        }
    }

    private static func capsuleProfile(left: (Double, Double, Double), right: (Double, Double, Double)) -> [CGFloat] {
        let circles = [left, right]
        return (0..<sampleCount).map { index in
            let angle = Double(index) / Double(sampleCount) * tau
            let dx = cos(angle), dy = sin(angle)
            return CGFloat(circles.reduce(0.0) { best, circle in
                let (x, y, radius) = circle
                let projection = dx * x + dy * y
                let discriminant = projection * projection - (x * x + y * y - radius * radius)
                return discriminant >= 0 ? Swift.max(best, projection + sqrt(discriminant)) : best
            })
        }
    }

    private static func regularPolygonProfile(sides: Int, radius: Double, cornerRadius: Double, rotation: Double) -> [CGFloat] {
        let effectiveRadius = radius - cornerRadius
        let vertices = (0..<sides).map { index -> CGPoint in
            let angle = rotation + Double(index) / Double(sides) * tau
            return CGPoint(x: cos(angle) * effectiveRadius, y: sin(angle) * effectiveRadius)
        }
        return (0..<sampleCount).map { index in
            let angle = Double(index) / Double(sampleCount) * tau
            let direction = CGVector(dx: cos(angle), dy: sin(angle))
            var best = CGFloat.infinity
            for edge in vertices.indices {
                let a = vertices[edge]
                let b = vertices[(edge + 1) % vertices.count]
                let edgeVector = CGVector(dx: b.x - a.x, dy: b.y - a.y)
                let denominator = direction.dx * edgeVector.dy - direction.dy * edgeVector.dx
                guard abs(denominator) > 1e-8 else { continue }
                let t = (a.x * edgeVector.dy - a.y * edgeVector.dx) / denominator
                let u = (a.x * direction.dy - a.y * direction.dx) / denominator
                if t >= 0, u >= 0, u <= 1 { best = Swift.min(best, t) }
            }
            return (best.isFinite ? best : CGFloat(effectiveRadius)) + CGFloat(cornerRadius)
        }
    }
}
