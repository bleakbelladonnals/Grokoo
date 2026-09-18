import AppKit
import XCTest
@testable import Grokoo

final class MotionExperienceTests: XCTestCase {
    @MainActor
    func testReviewClockContinuesPastWindowAndIgnoresHiddenAndSleepGaps() {
        let controller = MotionExperienceWindowController()
        defer { controller.shutdown() }
        XCTAssertEqual(controller.matrixView.combinationCount, 56)
        controller.seek(to: 19.9)
        controller.setPlaying(true)
        controller.advance(to: 1, visible: true)
        controller.advance(to: 1.2, visible: true)
        XCTAssertEqual(controller.elapsed, 20.1, accuracy: 0.0001)
        controller.advance(to: 10, visible: false)
        controller.advance(to: 100, visible: true)
        XCTAssertEqual(controller.elapsed, 20.1, accuracy: 0.0001)
        controller.advance(to: 100.1, visible: true)
        XCTAssertEqual(controller.elapsed, 20.2, accuracy: 0.0001)
        controller.advance(to: 900, visible: true)
        XCTAssertEqual(controller.elapsed, 20.2, accuracy: 0.0001)
        controller.setReducedMotion(true)
        controller.advance(to: 900.1, visible: true)
        XCTAssertEqual(controller.elapsed, 20.2, accuracy: 0.0001)
        controller.select(shape: .teardrop, state: .blocked)
        XCTAssertEqual(controller.elapsed, 0)
        XCTAssertEqual(controller.matrixView.selectedShape, .teardrop)
        XCTAssertEqual(controller.matrixView.selectedState, .blocked)
    }

    @MainActor
    func testExportNativeMatrixAndEveryCombinationAtBothSizes() throws {
        let directory = ProcessInfo.processInfo.environment["GROKOO_EVIDENCE_DIR"]
            ?? "/tmp/GrokooNativeMotionEvidence"
        let output = URL(fileURLWithPath: directory).appendingPathComponent("native-motion-experience", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let view = MotionExperienceMatrixView()
        var combinations: [[String: String]] = []
        for size: CGFloat in [32, 42] {
            view.bodySize = size
            for reduced in [false, true] {
                view.reducedMotion = reduced
                view.refreshOverview()
                let suffix = reduced ? "reduced" : "representative"
                let filename = "matrix-\(Int(size))pt-\(suffix).png"
                let matrix = try view.pngData()
                XCTAssertGreaterThan(matrix.count, 10_000)
                try matrix.write(to: output.appendingPathComponent(filename))
                for shape in OfficialShape.allCases {
                    for state in PresenceState.allCases {
                        let filename = "\(shape.rawValue)-\(state.rawValue)-\(Int(size))pt-\(suffix).png"
                        let data = try view.cellPNG(shape: shape, state: state)
                        XCTAssertGreaterThan(data.count, 200, filename)
                        try data.write(to: output.appendingPathComponent(filename))
                        combinations.append(["shape": shape.rawValue, "state": state.rawValue,
                                             "bodySize": String(Int(size)), "mode": suffix, "file": filename])
                    }
                }
            }
        }
        XCTAssertEqual(combinations.count, 224)
        try JSONSerialization.data(withJSONObject: combinations, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("coverage.json"))
        try """
        # Grokoo 原生动作图层证据

        当前正式应用的 NativeMotionSampler 与 NativeMotionLayer 直接绘制。
        四张矩阵覆盖 8 × 7 × 两种身体尺寸，以及减少动态代表姿态；224 张独立格图片逐项列于 coverage.json。
        图片以 2× 像素导出，身体逻辑尺寸为文件名中的 32 / 42 pt，外层安全容器为身体尺寸的 2.4 倍。
        这是原生图层证据，不等同于系统桌面截图；实际窗口、菜单栏与鼠标/键盘操作另行记录。
        """.write(to: output.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        print("Grokoo native motion evidence: \(output.path)")
    }
}
