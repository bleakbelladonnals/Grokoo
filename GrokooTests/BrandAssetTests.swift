import AppKit
import CryptoKit
import XCTest
@testable import Grokoo

final class BrandAssetTests: XCTestCase {
    private var resources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Grokoo/Resources", isDirectory: true)
    }

    @MainActor
    func testBrandResourcesMatchApprovedMastersAndExports() throws {
        let expected = [
            "AppIconSource.svg": "4727ce18ec7cc903a6dd773cb6d2d2fa12ac278acc455d0c68f2d2f6f15d37eb",
            "Assets.xcassets/AppIcon.appiconset/app-icon-16.png": "bb290590f9b7db070563678db76965d9c66ffddf968113a23511fd13506abe48",
            "Assets.xcassets/AppIcon.appiconset/app-icon-32.png": "83691ddfeae218aec4e6dff5d4f314347cfc3e8e5f97d0abac6d00417d27912d",
            "Assets.xcassets/AppIcon.appiconset/app-icon-64.png": "f9562b850316d5620a07e8ce57c10b807309ac542a800059656068bbc42e5261",
            "Assets.xcassets/AppIcon.appiconset/app-icon-128.png": "e5d6caadbee137d4d73b1f18b332030287ca372c47e06e4098b27c9811f5af23",
            "Assets.xcassets/AppIcon.appiconset/app-icon-256.png": "4a63e8cb585702b60a9b426707c4918a80304dfa9fdebc911fb47580e095c2ba",
            "Assets.xcassets/AppIcon.appiconset/app-icon-512.png": "8c45d4b60caef2a191c41bd3e5d634988072ed58b1d4135098856039379880f6",
            "Assets.xcassets/AppIcon.appiconset/app-icon-1024.png": "5dc2bc7466d41df711e1c9918918ef106fafb58a86af1932f29bdb6b98acdef3",
            "MenuBarIconSource.svg": "9382cbec0794a50ca736ea158ec60cebe3404e14ecf288fc6e794c59e60c7b71",
            "Assets.xcassets/MenuBarIcon.imageset/menu-bar-icon-18.png": "29efcddab9b645ff2715be11703f0f6b1c50cb4092d25f84d7cd8af37c226a53",
            "Assets.xcassets/MenuBarIcon.imageset/menu-bar-icon-36.png": "18633a250ff05819a615ce3112985879c444611ef98d9c84228b8f25a1b65d07"
        ]
        for (path, hash) in expected {
            let data = try Data(contentsOf: resources.appendingPathComponent(path))
            XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), hash, path)
        }
        for size in [16, 32, 64, 128, 256, 512, 1024] {
            let image = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: resources.appendingPathComponent(
                "Assets.xcassets/AppIcon.appiconset/app-icon-\(size).png"
            ))))
            XCTAssertEqual(image.pixelsWide, size)
            XCTAssertEqual(image.pixelsHigh, size)
            XCTAssertTrue(image.hasAlpha)
        }
    }

    @MainActor
    func testCompiledMenuTemplateKeeps18ptSizeAndSixTransparentEyeHoles() throws {
        let image = try XCTUnwrap(NSImage(named: "MenuBarIcon"))
        XCTAssertEqual(image.size, NSSize(width: 18, height: 18))
        XCTAssertTrue(image.isTemplate)
        let controller = MenuBarController(onShowAll: {}, onHideAll: {}, onOpenSettings: {}, onQuit: {})
        defer { controller.shutdown() }
        XCTAssertTrue(controller.usesTemplateIcon)

        let eyeCenters: [(CGFloat, CGFloat)] = [(8, 4.5), (10, 4.5), (4, 11.5), (6.5, 11.5), (12, 11.5), (14, 11.5)]
        for scale in [1, 2] {
            let rep = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: resources.appendingPathComponent(
                "Assets.xcassets/MenuBarIcon.imageset/menu-bar-icon-\(18 * scale).png"
            ))))
            XCTAssertEqual(rep.pixelsWide, 18 * scale)
            XCTAssertEqual(rep.pixelsHigh, 18 * scale)
            XCTAssertEqual(rep.colorAt(x: 0, y: 0)?.alphaComponent, 0)
            for (x, y) in eyeCenters {
                XCTAssertEqual(rep.colorAt(x: Int(x * CGFloat(scale)), y: Int(y * CGFloat(scale)))?.alphaComponent, 0)
            }
        }
    }

    @MainActor
    func testNativeBrandControlsRenderEvidence() throws {
        let template = try XCTUnwrap(NSImage(named: "MenuBarIcon"))
        let appIcon = try XCTUnwrap(NSImage(named: "AppIcon"))
        let board = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 530))
        board.wantsLayer = true
        board.layer?.backgroundColor = NSColor(calibratedRed: 0.96, green: 0.98, blue: 1, alpha: 1).cgColor
        let title = NSTextField(labelWithString: "Grokoo · App Icon / 18pt Menu Template")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        title.textColor = .black
        title.frame = NSRect(x: 24, y: 484, width: 850, height: 30)
        board.addSubview(title)
        var x: CGFloat = 24
        for size in [16, 32, 64, 128, 256] {
            let view = NSImageView(frame: NSRect(x: x, y: 194, width: CGFloat(size), height: CGFloat(size)))
            view.image = appIcon
            board.addSubview(view)
            let label = NSTextField(labelWithString: "\(size)pt")
            label.textColor = .black
            label.frame = NSRect(x: x, y: 170, width: CGFloat(max(42, size)), height: 20)
            board.addSubview(label)
            x += CGFloat(size + 34)
        }
        let appearances: [(NSAppearance.Name, String, NSColor)] = [
            (.aqua, "Light", .white),
            (.darkAqua, "Dark", NSColor(calibratedWhite: 0.20, alpha: 1)),
            (.accessibilityHighContrastAqua, "High contrast light", .white),
            (.accessibilityHighContrastDarkAqua, "High contrast dark", .black)
        ]
        for (index, value) in appearances.enumerated() {
            let panel = NSView(frame: NSRect(x: CGFloat(24 + index * 220), y: 22, width: 210, height: 128))
            panel.wantsLayer = true
            panel.layer?.backgroundColor = value.2.cgColor
            panel.appearance = NSAppearance(named: value.0)
            let label = NSTextField(labelWithString: value.1)
            label.font = .systemFont(ofSize: 12, weight: .medium)
            label.frame = NSRect(x: 12, y: 96, width: 188, height: 20)
            panel.addSubview(label)
            for (index, count) in ["", "1", "2", "3", "4", "5", "6", "6 !"].enumerated() {
                let button = NSButton(frame: NSRect(x: CGFloat(8 + index % 4 * 49), y: CGFloat(64 - index / 4 * 34), width: 47, height: 28))
                button.isBordered = false
                button.image = template
                button.title = count
                button.font = .menuBarFont(ofSize: 0)
                button.imagePosition = count.isEmpty ? .imageOnly : .imageLeading
                button.imageScaling = .scaleNone
                panel.addSubview(button)
            }
            board.addSubview(panel)
        }
        let window = NSWindow(contentRect: board.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = board
        board.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(board.bitmapImageRepForCachingDisplay(in: board.bounds))
        board.cacheDisplay(in: board.bounds, to: bitmap)
        let directory = ProcessInfo.processInfo.environment["GROKOO_EVIDENCE_DIR"]
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("GrokooBrandAssetTests").path
        let output = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent("brand", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: output.appendingPathComponent("native-brand-controls.png"))
    }
}
