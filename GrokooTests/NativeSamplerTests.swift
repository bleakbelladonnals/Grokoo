import AppKit
import XCTest
@testable import Grokoo

final class NativeSamplerTests: XCTestCase {
    private struct Reference: Decodable {
        struct Sample: Decodable {
            var shape: String; var state: String; var time: Double; var sampleTime: Double; var surfaceTurn: Double
            var bodyBounds: [Double]; var eyeBounds: [[Double]]; var markBounds: [Double]?
            var backBounds: [[Double]]; var frontBounds: [[Double]]
        }
        var samples: [Sample]
    }

    /// AC-NMB-02/04...09: independently generated from the unmodified approved
    /// ESM, including every shape/state and 200 extra Working/Done keyframes.
    @MainActor
    func testApprovedTypeScriptReference256Keyframes() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/native-motion-reference.json")
        let references = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
        XCTAssertEqual(references.samples.count, 256)
        for reference in references.samples {
            let shape = try XCTUnwrap(OfficialShape.allCases.first { $0.kitName == reference.shape })
            let state = try XCTUnwrap(PresenceState(rawValue: reference.state))
            let frame = NativeMotionSampler().sample(shape: shape, state: state, time: reference.time, instanceID: "reference")
            let label = "\(shape.rawValue)/\(state.rawValue)/\(reference.time)"
            assertBounds(frame.bodyPath.boundingBoxOfPath, reference.bodyBounds, label)
            XCTAssertEqual(frame.surfaceTurn, reference.surfaceTurn, accuracy: 0.00051, label)
            for (paths, expected) in [(frame.eyes.map(\.path), reference.eyeBounds),
                                      (frame.backRibbons.map(\.path), reference.backBounds),
                                      (frame.frontRibbons.map(\.path), reference.frontBounds)] {
                XCTAssertEqual(paths.count, expected.count, label)
                for (path, bounds) in zip(paths, expected) { assertBounds(path.boundingBoxOfPath, bounds, label) }
            }
            if let expected = reference.markBounds {
                assertBounds(frame.marks.reduce(CGRect.null) { $0.union($1.path.boundingBoxOfPath) }, expected, label)
            } else { XCTAssertTrue(frame.marks.isEmpty, label) }
        }
    }

    /// AC-NMB-02/03/05/07/22: identical 20 Hz windows to the handoff's 13,336
    /// samples, including two Thinking/Blocked/Done phrases. Two size mappings
    /// are checked without making the safe canvas a layout or hit region.
    @MainActor
    func testAll13336FramesRetainFiniteGeometryAndStatusSeparationAtBothSizes() {
        let windows: [PresenceState: Double] = [.idle: 8.4, .working: 20, .thinking: 12.6,
            .waiting: 8.4, .blocked: 12.6, .done: 12.6, .offline: 8.4]
        let sampler = NativeMotionSampler()
        var count = 0, extent = CGRect.null
        for shape in OfficialShape.allCases {
            for state in PresenceState.allCases {
                let id = "\(shape.rawValue)-\(state.rawValue)"
                for tick in 0...Int((windows[state]! * 20).rounded()) {
                    let frame = sampler.sample(shape: shape, state: state, time: Double(tick)/20, instanceID: id)
                    let bounds = frame.visibleBounds
                    XCTAssertTrue(bounds.minX.isFinite && bounds.minY.isFinite && bounds.width.isFinite && bounds.height.isFinite, id)
                    XCTAssertTrue(CGRect(x: -285, y: -285, width: 570, height: 570).contains(bounds), "\(id) \(tick): \(bounds)")
                    XCTAssertFalse(frame.bodyPath.isEmpty, id)
                    for size in [32.0, 42.0] {
                        let scale = size * 1.09 / 259
                        XCTAssertLessThan(bounds.width * scale, size * 2.4, id)
                        XCTAssertLessThan(bounds.height * scale, size * 2.4, id)
                    }
                    if state == .thinking || state == .blocked {
                        XCTAssertEqual(frame.eyes.count, 2, id)
                        for eye in frame.eyes {
                            for point in outlinePoints(eye.path) { XCTAssertTrue(frame.bodyPath.contains(point), "\(id) eye \(tick): \(point)") }
                        }
                        for mark in frame.marks {
                            for point in outlinePoints(mark.path) { XCTAssertFalse(frame.bodyPath.contains(point), "\(id) mark \(tick): \(point)") }
                        }
                    }
                    extent = extent.union(bounds)
                    count += 1
                }
            }
        }
        XCTAssertEqual(count, 13_336)
        print("Native sampler: \(count) frames; 32/42pt; visible union \(extent); 42pt maximum dimension \(max(extent.width, extent.height) * 42 * 1.09 / 259)")
    }

    @MainActor
    func testReducedMotionAll56CombinationsAreTimeInvariant() {
        for shape in OfficialShape.allCases {
            for state in PresenceState.allCases {
                let sampler = NativeMotionSampler()
                let first = sampler.sample(shape: shape, state: state, time: 0, instanceID: "static", reducedMotion: true)
                let later = sampler.sample(shape: shape, state: state, time: 400, instanceID: "static", reducedMotion: true)
                XCTAssertEqual(signature(first), signature(later), "\(shape)/\(state)")
            }
        }
    }

    @MainActor
    func testWorkingIsContinuousAndDoneCompletesAndRetriggers() {
        let sampler = NativeMotionSampler()
        var workingStarts: [Double] = [], previousSpin = false
        for tick in 0...2400 {
            let time = Double(tick)/60
            let working = sampler.sample(shape: .cloud, state: .working, time: time, instanceID: "working")
            let spinning = abs(working.surfaceTurn) > 0.00001
            if spinning && !previousSpin { workingStarts.append(time) }
            previousSpin = spinning
        }
        XCTAssertGreaterThanOrEqual(workingStarts.count, 4)
        XCTAssertTrue((1.2...2.4).contains(workingStarts[0]))
        let intervals = zip(workingStarts.dropFirst(), workingStarts).map { $0.0 - $0.1 }
        XCTAssertTrue(intervals.allSatisfy { (6...9.02).contains($0) })
        XCTAssertGreaterThan((intervals.max() ?? 0) - (intervals.min() ?? 0), 0.05)
        let before = sampler.sample(shape: .blob, state: .done, time: 0.14, instanceID: "done")
        let start = sampler.sample(shape: .blob, state: .done, time: 0.15, instanceID: "done")
        let recovery = sampler.sample(shape: .blob, state: .done, time: 5.63, instanceID: "done")
        let rest = sampler.sample(shape: .blob, state: .done, time: 5.65, instanceID: "done")
        let next = sampler.sample(shape: .blob, state: .done, time: 6.35, instanceID: "done")
        XCTAssertFalse(before.doneActionActive)
        XCTAssertTrue(start.doneActionActive)
        XCTAssertTrue(recovery.doneActionActive)
        XCTAssertFalse(rest.doneActionActive)
        XCTAssertTrue(next.doneActionActive)
        XCTAssertTrue(rest.frontRibbons.isEmpty && rest.backRibbons.isEmpty)
    }

    @MainActor
    func testSeekAndStateSwitchRemoveOldGeometryAndReproduceReference() {
        let sampler = NativeMotionSampler()
        let first = sampler.sample(shape: .tablet, state: .done, time: 1.2, instanceID: "same")
        XCTAssertFalse(first.frontRibbons.isEmpty)
        _ = sampler.sample(shape: .tablet, state: .done, time: 12.5, instanceID: "same")
        let seek = sampler.sample(shape: .tablet, state: .done, time: 1.2, instanceID: "same")
        XCTAssertEqual(signature(first), signature(seek))
        let status = sampler.sample(shape: .tablet, state: .thinking, time: 0, instanceID: "same")
        XCTAssertTrue(status.frontRibbons.isEmpty && status.backRibbons.isEmpty)
        XCTAssertEqual(status.marks.count, 3)
        let work = sampler.sample(shape: .tablet, state: .working, time: 0, instanceID: "same")
        XCTAssertTrue(work.marks.isEmpty && work.frontRibbons.isEmpty && work.backRibbons.isEmpty)
        sampler.reset(instanceID: "same")
        let fresh = sampler.sample(shape: .tablet, state: .done, time: 1.2, instanceID: "same")
        XCTAssertEqual(signature(first), signature(fresh))
    }

    @MainActor
    func testNativeLayerClearsEffectsAndKeepsBodyScaleIndependentOfSafeCanvas() {
        let layer = NativeMotionLayer(), sampler = NativeMotionSampler()
        for size in [32.0, 42.0] {
            let done = sampler.sample(shape: .blob, state: .done, time: 1.2, instanceID: "layer")
            layer.apply(frame: done, color: OfficialColor.blue.cgColor, bodySize: size)
            XCTAssertEqual(layer.bounds.width, size * 2.4)
            XCTAssertFalse(layer.masksToBounds)
            let idle = sampler.sample(shape: .blob, state: .idle, time: 1, instanceID: "layer")
            layer.apply(frame: idle, color: OfficialColor.blue.cgColor, bodySize: size)
            XCTAssertTrue(layer.motionFrame!.frontRibbons.isEmpty && layer.motionFrame!.marks.isEmpty)
            XCTAssertTrue(layer.animationKeys()?.isEmpty ?? true)
        }
    }

    private func assertBounds(_ actual: CGRect, _ expected: [Double], _ label: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        for (value, target) in zip([actual.minX, actual.minY, actual.maxX, actual.maxY], expected) {
            // SVG values are rounded to 0.1 for ribbons. 0.12 source units is
            // 0.0213pt at 42pt, below a physical pixel on any supported screen.
            XCTAssertEqual(value, target, accuracy: 0.12, label, file: file, line: line)
        }
    }
    private func signature(_ frame: NativeMotionFrame) -> [Double] {
        let paths = [frame.bodyPath] + frame.eyes.map(\.path) + frame.marks.map(\.path)
            + frame.backRibbons.map(\.path) + frame.frontRibbons.map(\.path)
        return paths.flatMap { outlinePoints($0).flatMap { [$0.x, $0.y] } }
            + [frame.opacity, frame.sampleTime, frame.surfaceTurn]
    }
    private func outlinePoints(_ path: CGPath) -> [CGPoint] {
        var points: [CGPoint] = [], current = CGPoint.zero, start = CGPoint.zero
        path.applyWithBlock { pointer in
            let element = pointer.pointee
            switch element.type {
            case .moveToPoint: current = element.points[0]; start = current; points.append(current)
            case .addLineToPoint: current = element.points[0]; points.append(current)
            case .addQuadCurveToPoint:
                let p = current, control = element.points[0], end = element.points[1]
                for step in 1...8 {
                    let t = Double(step)/8, u = 1-t
                    points.append(CGPoint(x: u*u*p.x+2*u*t*control.x+t*t*end.x, y: u*u*p.y+2*u*t*control.y+t*t*end.y))
                }
                current = end
            case .addCurveToPoint:
                let p = current, c1 = element.points[0], c2 = element.points[1], end = element.points[2]
                for step in 1...8 {
                    let t = Double(step)/8, u = 1-t
                    let x = u*u*u*p.x + 3*u*u*t*c1.x + 3*u*t*t*c2.x + t*t*t*end.x
                    let y = u*u*u*p.y + 3*u*u*t*c1.y + 3*u*t*t*c2.y + t*t*t*end.y
                    points.append(CGPoint(x: x, y: y))
                }
                current = end
            case .closeSubpath: current = start
            @unknown default: break
            }
        }
        return points
    }
}
