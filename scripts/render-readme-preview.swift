import AppKit
import Foundation
import QuartzCore

// Rebuild from the repository root:
// swiftc -O -o /tmp/grokoo-readme-preview scripts/render-readme-preview.swift \
//   Grokoo/Rendering/Native*.swift Grokoo/Rendering/OfficialAppearance.swift \
//   Grokoo/Presence/PresenceModels.swift Grokoo/Gateway/GatewayModels.swift
// /tmp/grokoo-readme-preview .github/assets
// The PNG is an original native layer export, not an application screenshot.
// With ffmpeg on PATH, the same native frames become a 6.2-second looping GIF.

@main
struct ReadmePreview {
    private struct Role {
        let title: String
        let shape: OfficialShape
        let state: PresenceState
        let color: OfficialColor
    }

    @MainActor
    static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".github/assets", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let framesURL = FileManager.default.temporaryDirectory.appendingPathComponent("grokoo-readme-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: framesURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: framesURL) }

        let width = 960, height = 272, fps = 20, frameCount = 124
        let roles: [Role] = [
            Role(title: "空闲", shape: .cloud, state: .idle, color: .green),
            Role(title: "工作", shape: .blob, state: .working, color: .blue),
            Role(title: "思考", shape: .teardrop, state: .thinking, color: .violet),
            Role(title: "等待", shape: .pebble, state: .waiting, color: .cyan),
            Role(title: "完成", shape: .squircle, state: .done, color: .magenta),
            Role(title: "离线", shape: .hex, state: .offline, color: .gray)
        ]
        let root = CALayer()
        root.frame = CGRect(x: 0, y: 0, width: width, height: height)
        root.backgroundColor = NSColor(calibratedRed: 0.955, green: 0.972, blue: 0.995, alpha: 1).cgColor

        func text(_ value: String, frame: CGRect, size: CGFloat, weight: NSFont.Weight, color: NSColor, centered: Bool = false) {
            let layer = CATextLayer()
            layer.frame = frame
            layer.string = value
            layer.font = NSFont.systemFont(ofSize: size, weight: weight)
            layer.fontSize = size
            layer.contentsScale = 2
            layer.foregroundColor = color.cgColor
            layer.alignmentMode = centered ? .center : .left
            root.addSublayer(layer)
        }

        text("Grokoo", frame: CGRect(x: 32, y: 224, width: 124, height: 34), size: 27, weight: .semibold,
             color: NSColor(calibratedRed: 0.08, green: 0.16, blue: 0.25, alpha: 1))
        text("状态随任务而动", frame: CGRect(x: 158, y: 229, width: 280, height: 23), size: 16, weight: .regular,
             color: NSColor(calibratedRed: 0.35, green: 0.43, blue: 0.52, alpha: 1))
        let divider = CALayer()
        divider.frame = CGRect(x: 32, y: 207, width: 896, height: 1)
        divider.backgroundColor = NSColor(calibratedRed: 0.84, green: 0.89, blue: 0.95, alpha: 1).cgColor
        root.addSublayer(divider)

        var layers: [NativeMotionLayer] = []
        for (index, role) in roles.enumerated() {
            let x = CGFloat(80 + index * 160)
            let layer = NativeMotionLayer()
            layer.position = CGPoint(x: x, y: 140)
            root.addSublayer(layer)
            layers.append(layer)
            text(role.title, frame: CGRect(x: x - 64, y: 48, width: 128, height: 29), size: 18, weight: .medium,
                 color: NSColor(calibratedRed: 0.21, green: 0.30, blue: 0.40, alpha: 1), centered: true)
        }

        let sampler = NativeMotionSampler()
        func sample(times: [Double], prefix: String) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for (index, role) in roles.enumerated() {
                let frame = sampler.sample(shape: role.shape, state: role.state, time: times[index], instanceID: "\(prefix)-\(index)")
                layers[index].apply(frame: frame, color: role.color.cgColor, bodySize: 74)
            }
            CATransaction.commit()
        }

        func writePNG(to url: URL) throws {
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            root.render(in: context)
            let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
            try bitmap.representation(using: .png, properties: [:])!.write(to: url)
        }

        for tick in 0..<frameCount {
            sample(times: Array(repeating: Double(tick) / Double(fps), count: roles.count), prefix: "loop")
            try writePNG(to: framesURL.appendingPathComponent(String(format: "frame-%04d.png", tick)))
        }
        sample(times: roles.map { NativeMotionSampler.staticTimes[$0.state]! }, prefix: "poster")
        let poster = output.appendingPathComponent("grokoo-motion.png")
        try writePNG(to: poster)
        print("Native poster:", poster.path)

        let ffmpeg = Process()
        ffmpeg.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        ffmpeg.arguments = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-framerate", String(fps),
            "-i", framesURL.appendingPathComponent("frame-%04d.png").path,
            "-filter_complex", "split[a][b];[a]palettegen=max_colors=192:reserve_transparent=0:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle",
            "-loop", "0", output.appendingPathComponent("grokoo-motion.gif").path]
        try ffmpeg.run()
        ffmpeg.waitUntilExit()
        if ffmpeg.terminationStatus == 0 {
            print("Native motion GIF:", output.appendingPathComponent("grokoo-motion.gif").path, "960×272 · 6.2s · 20fps")
        } else {
            print("GIF was not encoded; the native PNG remains available.")
        }
    }
}
