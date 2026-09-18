import AppKit

/// The approved Dock prototype renderer, using the host's native shape engine.
private struct MotionSample {
    var scale: CGFloat = 1
    var offset = CGPoint.zero
    var gaze = CGPoint.zero
    var opacity: CGFloat = 1
}

@MainActor
final class DockIconRenderer {
    private let item: DockItemSnapshot
    private let phase: Double
    private let shapeEngine = BloubShapeEngine()

    init(item: DockItemSnapshot) {
        self.item = item
        let stablePhase = item.id.unicodeScalars.reduce(0) { ($0 * 31 + Int($1.value)) % 628 }
        phase = Double(stablePhase) / 100.0
    }

    func image(at time: TimeInterval) -> NSImage {
        let image = NSImage(size: NSSize(width: 128, height: 128))
        image.lockFocus()
        guard let context = NSGraphicsContext.current?.cgContext else {
            image.unlockFocus()
            return image
        }
        context.saveGState()
        context.scaleBy(x: 0.5, y: 0.5)
        NSGraphicsContext.current?.imageInterpolation = .high
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: 256, height: 256).fill()

        let motion = motionSample(at: time)
        if item.kind == .group {
            drawGroupBase(in: context)
            context.saveGState()
            apply(motion, to: context)
            drawGroupMembers(in: context, time: time)
            context.restoreGState()
        } else {
            context.saveGState()
            apply(motion, to: context)
            drawBot(in: context, time: time, gaze: motion.gaze)
            context.restoreGState()
        }
        context.restoreGState()
        image.unlockFocus()
        return image
    }

    private func apply(_ motion: MotionSample, to context: CGContext) {
        context.translateBy(x: 128 + motion.offset.x, y: 128 + motion.offset.y)
        context.scaleBy(x: motion.scale, y: motion.scale)
        context.translateBy(x: -128, y: -128)
        context.setAlpha(motion.opacity)
    }

    private func motionSample(at time: TimeInterval) -> MotionSample {
        let t = time + phase
        switch item.state {
        case .idle:
            return MotionSample(scale: 0.97 + CGFloat(sin(t * 1.35)) * 0.012, offset: CGPoint(x: 0, y: CGFloat(sin(t * 1.05)) * 1.8), gaze: CGPoint(x: CGFloat(sin(t * 0.75)) * 1.1, y: 0))
        case .working:
            return MotionSample(scale: 0.985 + CGFloat(sin(t * 3.7)) * 0.015, offset: CGPoint(x: 0, y: CGFloat(abs(sin(t * 3.7))) * 4), gaze: CGPoint(x: 0.8, y: -0.5))
        case .thinking:
            return MotionSample(scale: 0.98 + CGFloat(sin(t * 1.7)) * 0.01, offset: CGPoint(x: CGFloat(sin(t * 1.2)) * 1.8, y: 2), gaze: CGPoint(x: 0.8, y: 1.2))
        case .waiting:
            return MotionSample(scale: 0.98, offset: CGPoint(x: 0, y: 1), gaze: CGPoint(x: CGFloat(sin(t * 2.8)) * 2.2, y: 0.2))
        case .blocked:
            return MotionSample(scale: 0.975, offset: CGPoint(x: CGFloat(sin(t * 8.0)) * 3.2, y: 0), gaze: CGPoint(x: 0, y: -0.8))
        case .done:
            return MotionSample(scale: 0.99 + CGFloat(abs(sin(t * 2.0))) * 0.025, offset: CGPoint(x: 0, y: CGFloat(abs(sin(t * 2.0))) * 5), gaze: .zero)
        case .offline:
            return MotionSample(scale: 0.96, offset: .zero, gaze: .zero, opacity: 0.48)
        }
    }

    private func drawBot(in context: CGContext, time: TimeInterval, gaze: CGPoint) {
        let bodyRect = CGRect(x: 14, y: 14, width: 228, height: 228)
        drawAvatar(shape: item.shape, color: item.color, in: bodyRect, context: context, gaze: gaze, shadow: true)
    }

    private func drawGroupBase(in context: CGContext) {
        let tileRect = CGRect(x: 20, y: 20, width: 216, height: 216)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -6), blur: 12, color: NSColor.black.withAlphaComponent(0.16).cgColor)
        NSColor(calibratedWhite: 0.91, alpha: 0.72).setFill()
        NSBezierPath(roundedRect: tileRect, xRadius: 48, yRadius: 48).fill()
        context.restoreGState()
        NSColor(calibratedWhite: 0.72, alpha: 0.42).setStroke()
        let edge = NSBezierPath(roundedRect: tileRect.insetBy(dx: 1, dy: 1), xRadius: 47, yRadius: 47)
        edge.lineWidth = 2
        edge.stroke()
    }

    private func drawGroupMembers(in context: CGContext, time: TimeInterval) {
        let members = Array(item.members.prefix(6))
        let placements = groupPlacements(count: members.count)
        for (index, member) in members.enumerated() where placements.indices.contains(index) {
            let placement = placements[index]
            let bounce = item.state == .working ? CGFloat(sin(time * 4 + Double(index) + phase)) * 1.8 : 0
            let rect = CGRect(x: placement.center.x - placement.size / 2, y: placement.center.y - placement.size / 2 + bounce, width: placement.size, height: placement.size)
            drawAvatar(shape: member.shape, color: member.color, in: rect, context: context, gaze: .zero, shadow: false)
        }
    }

    private func drawAvatar(shape: OfficialShape, color: OfficialColor, in rect: CGRect, context: CGContext, gaze: CGPoint, shadow: Bool) {
        let bodyColor = self.color(for: color)
        let path = shapeEngine.path(for: shape, in: rect.insetBy(dx: rect.width * 0.045, dy: rect.height * 0.045))
        context.saveGState()
        let shadowColor = shadow ? bodyColor.withAlphaComponent(0.28) : NSColor.black.withAlphaComponent(0.2)
        context.setShadow(offset: CGSize(width: 0, height: shadow ? -7 : -2), blur: shadow ? 13 : 3, color: shadowColor.cgColor)
        context.addPath(path)
        context.setFillColor(bodyColor.cgColor)
        context.fillPath()
        context.restoreGState()
        drawEyes(shape: shape, bodyColor: bodyColor, in: rect, gaze: gaze)
    }

    private func drawEyes(shape: OfficialShape, bodyColor: NSColor, in rect: CGRect, gaze: CGPoint) {
        let unit = min(rect.width, rect.height) / 32
        let fit: (x: CGFloat, y: CGFloat, spacing: CGFloat, width: CGFloat, height: CGFloat)
        switch shape {
        case .blob: fit = (0.4, 1.3, 8.4, 3.5, 7.0)
        case .pebble: fit = (0.2, 1.1, 8.0, 3.4, 6.8)
        case .squircle: fit = (0, 0.7, 8.2, 3.4, 6.8)
        case .tablet: fit = (0, 0.5, 8.8, 3.2, 6.4)
        case .wedge: fit = (0, 3.0, 7.0, 3.0, 5.8)
        case .hex: fit = (0, 1.0, 7.8, 3.3, 6.5)
        case .cloud: fit = (0, 2.4, 7.4, 3.1, 6.0)
        case .teardrop: fit = (0, 3.5, 6.8, 2.9, 5.6)
        }
        let eyeSize = CGSize(width: max(1.5, fit.width * unit), height: max(3, fit.height * unit))
        let centerY = rect.midY + fit.y * unit + gaze.y * unit * 0.45
        let centerX = rect.midX + fit.x * unit + gaze.x * unit * 0.45
        bodyColor.contrastingMonochrome.setFill()
        for x in [centerX - fit.spacing * unit / 2, centerX + fit.spacing * unit / 2] {
            NSBezierPath(roundedRect: CGRect(x: x - eyeSize.width / 2, y: centerY - eyeSize.height / 2, width: eyeSize.width, height: eyeSize.height), xRadius: eyeSize.width / 2, yRadius: eyeSize.width / 2).fill()
        }
    }

    private func color(for value: OfficialColor) -> NSColor { NSColor(hex: value.hex) ?? .systemBlue }

    private func groupPlacements(count: Int) -> [(center: CGPoint, size: CGFloat)] {
        switch count {
        case 0, 1:
            return [(CGPoint(x: 128, y: 128), 116)]
        case 2:
            return [(CGPoint(x: 80, y: 128), 86), (CGPoint(x: 176, y: 128), 86)]
        case 3:
            return [(CGPoint(x: 128, y: 174), 76), (CGPoint(x: 82, y: 86), 76), (CGPoint(x: 174, y: 86), 76)]
        case 4:
            return [(CGPoint(x: 82, y: 174), 72), (CGPoint(x: 174, y: 174), 72), (CGPoint(x: 82, y: 82), 72), (CGPoint(x: 174, y: 82), 72)]
        case 5:
            return [(CGPoint(x: 90, y: 174), 62), (CGPoint(x: 166, y: 174), 62), (CGPoint(x: 52, y: 82), 62), (CGPoint(x: 128, y: 82), 62), (CGPoint(x: 204, y: 82), 62)]
        default:
            return [(CGPoint(x: 52, y: 174), 62), (CGPoint(x: 128, y: 174), 62), (CGPoint(x: 204, y: 174), 62), (CGPoint(x: 52, y: 82), 62), (CGPoint(x: 128, y: 82), 62), (CGPoint(x: 204, y: 82), 62)]
        }
    }
}
