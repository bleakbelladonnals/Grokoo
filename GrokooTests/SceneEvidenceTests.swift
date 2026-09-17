import AppKit
import XCTest
@testable import Grokoo

/// Current App view captures, distinct from window-server / desktop evidence.
final class SceneEvidenceTests: XCTestCase {
    @MainActor
    func testExportCurrentSceneFixtureViews() async throws {
        let directory = ProcessInfo.processInfo.environment["GROKOO_EVIDENCE_DIR"] ?? ProcessInfo.processInfo.environment["GROKLING_EVIDENCE_DIR"]
            ?? "/tmp/GrokooV11SceneEvidence"
        let output = URL(fileURLWithPath: directory).appendingPathComponent("scene-views", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        print("Grokoo current Scene evidence: \(output.path)")
        let readme = """
        # 当前 App Scene 几何与图层视图

        这些图片由当前 PetSceneController、PetLayer、FogWorkspaceLayer 和 AppKit view 导出，使用真实场景状态与布局。
        图片将透明 Scene 合成到本机 macOS 壁纸背景，方便检查身体尺寸、布局、Fog 对比与状态标记。

        - light 使用 macOS Solid Colors/Silver.png。
        - dark 使用 macOS Solid Colors/Space Gray Pro.png。
        - complex 使用 macOS Sonoma.heic 的缩放背景。
        - 对应系统文件不存在时使用同明度中性底色；壁纸资源没有复制进应用。

        本目录是几何和图层视图证据。AppKit 的原生按钮与焦点环由系统合成，NSView.cacheDisplay 不包含其全部像素；本目录不补画按钮，也不用于证明控件可见或桌面层级。Done 收起、全部收起、键盘、VoiceOver、普通窗口/全屏覆盖和透明空白穿透以真实桌面截图与交互记录为准。
        """
        try readme.write(to: output.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let fixtures = ExperienceFixtureCatalog.loadBundled()
        for fixture in fixtures {
            let scene = PetSceneController(frame: CGRect(x: 0, y: 0, width: 1000, height: 600), visibleFrame: CGRect(x: 0, y: 70, width: 1000, height: 530), allowsEdgeMotion: false, experienceFixture: fixture)
            let identities = Array(AcceptanceFixtureGatewayRuntime.identities.prefix(fixture.visibleBotCount))
            scene.synchronize(identities: identities)
            let snapshot = AcceptanceFixtureGatewayRuntime.snapshot(fixture: fixture)
            var tracker = GroupActivityTracker()
            let group = tracker.update(roster: snapshot, visibleBotIds: Set(identities.map(\.id)))
            let states = Dictionary(uniqueKeysWithValues: identities.enumerated().map { ($0.element.id, fixture.states[$0.offset % fixture.states.count]) })
            scene.updateGroupActivity(group, presenceByBot: states, revision: 1)
            scene.showAll()
            try await Task.sleep(for: .seconds(1.2))
            scene.refreshInteraction()
            let view = try XCTUnwrap(scene.panel.contentView as? InteractiveSceneView)
            if states.values.contains(.done) { view.focusPendingCompletions() }
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            try await Task.sleep(for: .seconds(0.08))
            let capture = CGRect(x: 0, y: 0, width: 1000, height: 240)
            let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: capture))
            view.cacheDisplay(in: capture, to: rep)
            let composite = composite(rep, wallpaper: fixture.wallpaper, size: capture.size)
            let cgImage = try XCTUnwrap(composite.cgImage(forProposedRect: nil, context: nil, hints: nil))
            let png = try XCTUnwrap(NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(png.count, 1000, fixture.id)
            try png.write(to: output.appendingPathComponent("\(fixture.id).png"))
            scene.shutdown()
        }
    }

    @MainActor
    private func composite(_ foreground: NSBitmapImageRep, wallpaper: WorkspaceWallpaperKind, size: CGSize) -> NSImage {
        let path: String
        let fallback: NSColor
        switch wallpaper {
        case .light:
            path = "/System/Library/Desktop Pictures/Solid Colors/Silver.png"
            fallback = NSColor(calibratedWhite: 0.9, alpha: 1)
        case .dark:
            path = "/System/Library/Desktop Pictures/Solid Colors/Space Gray Pro.png"
            fallback = NSColor(calibratedWhite: 0.2, alpha: 1)
        case .complex:
            path = "/System/Library/Desktop Pictures/Sonoma.heic"
            fallback = NSColor(calibratedWhite: 0.6, alpha: 1)
        }
        let result = NSImage(size: size)
        result.lockFocus()
        fallback.setFill()
        NSRect(origin: .zero, size: size).fill()
        NSImage(contentsOfFile: path)?.draw(in: CGRect(x: 0, y: 0, width: size.width, height: 600))
        let scene = NSImage(size: size)
        scene.addRepresentation(foreground)
        scene.draw(in: CGRect(origin: .zero, size: size))
        result.unlockFocus()
        return result
    }

}
