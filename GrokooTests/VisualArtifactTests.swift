import AppKit
import XCTest
@testable import Grokoo

final class VisualArtifactTests: XCTestCase {
    @MainActor
    func testShapeAndDecorationMatricesRenderAtAcceptanceScale() throws {
        let shapeImage = makeShapeMatrix()
        let decorationImage = makeDecorationMatrix()
        XCTAssertEqual(shapeImage.size, CGSize(width: 720, height: 220))
        XCTAssertEqual(decorationImage.size, CGSize(width: 720, height: 690))

        let directory = ProcessInfo.processInfo.environment["GROKOO_EVIDENCE_DIR"] ?? ProcessInfo.processInfo.environment["GROKLING_EVIDENCE_DIR"]
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("GrokooVisualArtifactTests", isDirectory: true).path
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try pngData(shapeImage).write(to: output.appendingPathComponent("official-shape-palette.png"))
        try pngData(decorationImage).write(to: output.appendingPathComponent("decoration-matrix-8x4.png"))
    }

    @MainActor
    private func makeShapeMatrix() -> NSImage {
        let size = CGSize(width: 720, height: 220)
        let root = baseLayer(size: size, title: "Grokoo · Official 32px Shapes and Colors")
        let shapes = OfficialShape.allCases
        let colors = OfficialColor.allCases
        for (index, shape) in shapes.enumerated() {
            let x = CGFloat(55 + index * 82)
            let pet = PetLayer(identity: BotIdentity(
                id: "shape-\(shape.rawValue)",
                name: shape.rawValue,
                shape: shape,
                color: colors[index % colors.count]
            ))
            pet.position = CGPoint(x: x, y: 96)
            root.addSublayer(pet)
            root.addSublayer(label(shape.rawValue, frame: CGRect(x: x - 38, y: 60, width: 76, height: 20)))
        }
        root.addSublayer(label("Body 32px · overall 36px · eyes constrained to silhouette", frame: CGRect(x: 20, y: 18, width: 680, height: 24), fontSize: 13))
        return render(root, size: size)
    }

    @MainActor
    private func makeDecorationMatrix() -> NSImage {
        let size = CGSize(width: 720, height: 690)
        let root = baseLayer(size: size, title: "Grokoo · 8 Shapes × 4 Original MBTI Decorations")
        let decorations: [(String, String)] = [
            ("ENTP", DecorationID.bentBrow.rawValue),
            ("INFP", DecorationID.butterfly.rawValue),
            ("ISFJ", DecorationID.nurseCap.rawValue),
            ("ISTP", DecorationID.tinyDrill.rawValue)
        ]
        for (column, decoration) in decorations.enumerated() {
            root.addSublayer(label(decoration.0, frame: CGRect(x: 208 + CGFloat(column * 115), y: 624, width: 96, height: 24), fontSize: 14))
        }
        for (row, shape) in OfficialShape.allCases.enumerated() {
            let y = CGFloat(558 - row * 70)
            root.addSublayer(label(shape.rawValue, frame: CGRect(x: 28, y: y + 8, width: 130, height: 24), fontSize: 14, alignment: .right))
            for (column, decoration) in decorations.enumerated() {
                let identity = BotIdentity(
                    id: "\(shape.rawValue)-\(decoration.0)",
                    name: decoration.0,
                    shape: shape,
                    color: OfficialColor.allCases[(row + column) % OfficialColor.allCases.count]
                )
                let pet = PetLayer(identity: identity)
                pet.setMBTIDecoration(decoration.1)
                pet.position = CGPoint(x: CGFloat(256 + column * 115), y: y)
                root.addSublayer(pet)
            }
        }
        root.addSublayer(label("Original vector attachments · face / floating / head / side anchors", frame: CGRect(x: 20, y: 18, width: 680, height: 24), fontSize: 13))
        return render(root, size: size)
    }

    private func baseLayer(size: CGSize, title: String) -> CALayer {
        let root = CALayer()
        root.frame = CGRect(origin: .zero, size: size)
        root.backgroundColor = NSColor(calibratedRed: 0.94, green: 0.97, blue: 1, alpha: 1).cgColor
        root.addSublayer(label(title, frame: CGRect(x: 20, y: size.height - 48, width: size.width - 40, height: 30), fontSize: 20))
        return root
    }

    private func label(
        _ value: String,
        frame: CGRect,
        fontSize: CGFloat = 11,
        alignment: CATextLayerAlignmentMode = .center
    ) -> CATextLayer {
        let layer = CATextLayer()
        layer.frame = frame
        layer.string = value
        layer.font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        layer.fontSize = fontSize
        layer.foregroundColor = NSColor(calibratedWhite: 0.12, alpha: 1).cgColor
        layer.alignmentMode = alignment
        layer.contentsScale = 2
        return layer
    }

    private func render(_ layer: CALayer, size: CGSize) -> NSImage {
        let width = Int(size.width * 2)
        let height = Int(size.height * 2)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.scaleBy(x: 2, y: 2)
        layer.render(in: context)
        return NSImage(cgImage: context.makeImage()!, size: size)
    }

    private func pngData(_ image: NSImage) throws -> Data {
        let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let representation = NSBitmapImageRep(cgImage: cgImage)
        return try XCTUnwrap(representation.representation(using: .png, properties: [:]))
    }
}
