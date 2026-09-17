import AppKit
import CoreGraphics

struct EdgeInsets: Equatable, Codable, Sendable {
    var top: CGFloat
    var left: CGFloat
    var bottom: CGFloat
    var right: CGFloat
    static let zero = EdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
}

struct EdgeGeometry: Equatable, Sendable {
    let screenFrame: CGRect
    let visibleFrame: CGRect
    let safeAreaInsets: EdgeInsets
    let petExtent: CGFloat
    let floorY: CGFloat
    let ceilingY: CGFloat
    let leftX: CGFloat
    let rightX: CGFloat

    init(screenFrame: CGRect, visibleFrame: CGRect, safeAreaInsets: EdgeInsets = .zero, petExtent: CGFloat = 36) {
        self.screenFrame = screenFrame
        self.visibleFrame = visibleFrame
        self.safeAreaInsets = safeAreaInsets
        self.petExtent = petExtent
        let half = petExtent / 2
        leftX = max(screenFrame.minX + safeAreaInsets.left + half, visibleFrame.minX + half)
        rightX = min(screenFrame.maxX - safeAreaInsets.right - half, visibleFrame.maxX - half)
        floorY = max(screenFrame.minY + safeAreaInsets.bottom, visibleFrame.minY)
        ceilingY = min(screenFrame.maxY - safeAreaInsets.top - petExtent, visibleFrame.maxY - petExtent)
    }

    @MainActor
    init(screen: NSScreen, petExtent: CGFloat = 36) {
        let insets: EdgeInsets
        if #available(macOS 12.0, *) {
            insets = EdgeInsets(top: screen.safeAreaInsets.top, left: screen.safeAreaInsets.left, bottom: screen.safeAreaInsets.bottom, right: screen.safeAreaInsets.right)
        } else {
            insets = .zero
        }
        self.init(screenFrame: screen.frame, visibleFrame: screen.visibleFrame, safeAreaInsets: insets, petExtent: petExtent)
    }

    func point(surface: EdgeSurface, normalizedPosition rawPosition: CGFloat) -> CGPoint {
        let position = min(max(rawPosition, 0), 1)
        switch surface {
        case .floor: return CGPoint(x: leftX + (rightX - leftX) * position, y: floorY)
        case .leftWall: return CGPoint(x: leftX, y: floorY + (ceilingY - floorY) * position)
        case .rightWall: return CGPoint(x: rightX, y: floorY + (ceilingY - floorY) * position)
        case .ceiling: return CGPoint(x: leftX + (rightX - leftX) * position, y: ceilingY)
        case .station, .groupStation: return CGPoint(x: visibleFrame.midX, y: floorY)
        }
    }
}
