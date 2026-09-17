import AppKit
import QuartzCore

enum WorkspaceWallpaperKind: String, Codable, CaseIterable, Sendable { case light, dark, complex }

final class FogWorkspaceLayer: CAGradientLayer {
    private(set) var isReducedTransparency = false

    override init() {
        super.init()
        startPoint = CGPoint(x: 0, y: 0.5)
        endPoint = CGPoint(x: 1, y: 0.5)
        locations = [0, 0.24, 0.5, 0.76, 1]
        cornerRadius = 9
        masksToBounds = true
        updateAppearance(wallpaper: .complex, reducedTransparency: false)
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { nil }

    func updateAppearance(wallpaper: WorkspaceWallpaperKind, reducedTransparency: Bool) {
        isReducedTransparency = reducedTransparency
        let white: CGFloat
        let alpha: CGFloat
        if reducedTransparency {
            white = wallpaper == .dark ? 0.88 : 0.12
            alpha = 0.18
        } else {
            white = wallpaper == .dark ? 0.05 : 0.16
            alpha = wallpaper == .dark ? 0.42 : 0.24
        }
        let clear = NSColor(calibratedWhite: white, alpha: 0).cgColor
        let mid = NSColor(calibratedWhite: white, alpha: alpha * 0.65).cgColor
        let center = NSColor(calibratedWhite: white, alpha: alpha).cgColor
        colors = [clear, mid, center, mid, clear]
        borderWidth = 0
        shadowOpacity = 0
    }
}
