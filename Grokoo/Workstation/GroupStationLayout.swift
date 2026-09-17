import AppKit
import CoreGraphics
import Foundation
import QuartzCore

struct GroupStationPlacement: Equatable, Sendable {
    let baseFrame: CGRect
    let memberFrames: [BotID: CGRect]
}

struct GroupStationLayout: Sendable {
    var slotWidth: CGFloat = 42
    var baseHeight: CGFloat = 8
    var clearance: CGFloat = 8

    func placement(
        visibleFrame: CGRect,
        orderedMemberIds: [BotID],
        preferredCenterX: CGFloat? = nil,
        avoiding occupiedFrames: [CGRect] = [],
        socialDistancesByBot: [BotID: CGFloat] = [:]
    ) -> GroupStationPlacement? {
        let ids = Array(orderedMemberIds.prefix(6))
        guard !ids.isEmpty else { return nil }
        let defaultSpacing = min(max(slotWidth, 40), 44)
        var relativeCenters: [CGFloat] = [18]
        if ids.count > 1 {
            for index in 1..<ids.count {
                let previous = socialDistancesByBot[ids[index - 1]] ?? defaultSpacing
                let current = socialDistancesByBot[ids[index]] ?? defaultSpacing
                let spacing = min(68, max(36, (previous + current) / 2))
                relativeCenters.append((relativeCenters.last ?? 18) + spacing)
            }
        }
        let contentWidth = (relativeCenters.last ?? 18) + 18
        let width = max(CGFloat(ids.count) * defaultSpacing, contentWidth)
        let bounds = visibleFrame.insetBy(dx: 12, dy: 0)
        let preferred = min(max(preferredCenterX ?? visibleFrame.midX, bounds.minX + width / 2), bounds.maxX - width / 2)
        let candidates = [preferred, bounds.minX + width / 2, bounds.maxX - width / 2]
        let baseY = visibleFrame.minY + 1
        let baseFrame = candidates
            .map { CGRect(x: $0 - width / 2, y: baseY, width: width, height: baseHeight) }
            .first { candidate in !occupiedFrames.contains(where: { $0.insetBy(dx: -clearance, dy: -clearance).intersects(candidate) }) }
            ?? CGRect(x: preferred - width / 2, y: baseY + baseHeight + clearance, width: width, height: baseHeight)
        let contentOffset = (baseFrame.width - contentWidth) / 2
        let memberFrames = Dictionary(uniqueKeysWithValues: ids.enumerated().map { index, id in
            let centerX = baseFrame.minX + contentOffset + relativeCenters[index]
            return (id, CGRect(x: centerX - 18, y: baseFrame.maxY, width: 36, height: 36))
        })
        return GroupStationPlacement(baseFrame: baseFrame, memberFrames: memberFrames)
    }
}

final class GroupStationLayer: CALayer {
    private let shapeLayer = CAShapeLayer()

    override init() {
        super.init()
        addSublayer(shapeLayer)
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { nil }

    func configure(frame: CGRect) {
        self.frame = frame
        shapeLayer.frame = bounds
        shapeLayer.path = CGPath(roundedRect: bounds, cornerWidth: 4, cornerHeight: 4, transform: nil)
        shapeLayer.fillColor = NSColor(calibratedWhite: 0.12, alpha: 0.34).cgColor
        shapeLayer.strokeColor = NSColor.white.withAlphaComponent(0.28).cgColor
        shapeLayer.lineWidth = 0.7
    }

    func cancelAnimations() {
        removeAllAnimations()
        shapeLayer.removeAllAnimations()
    }
}
