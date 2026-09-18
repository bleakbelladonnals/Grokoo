import CoreGraphics
import Foundation

/// Paths use the approved 259-unit coordinate system, centered at (0, 0), y down.
/// Scene movement is intentionally separate from every state-local pose here.
struct NativePaintPath {
    var path: CGPath
    var opacity: Double = 1
}

struct NativeRibbonPaint {
    var path: CGPath
    var start: CGPoint
    var end: CGPoint
    var colors: [CGColor]
    var opacity: Double
}

struct NativeMotionFrame {
    var bodyPath: CGPath
    var eyes: [NativePaintPath] = []
    var marks: [NativePaintPath] = []
    var backRibbons: [NativeRibbonPaint] = []
    var frontRibbons: [NativeRibbonPaint] = []
    var opacity: Double = 1
    var sampleTime: Double = 0
    var surfaceTurn: Double = 0
    var doneActionActive = false

    var visibleBounds: CGRect {
        (eyes.map(\.path) + marks.map(\.path) + backRibbons.map(\.path) + frontRibbons.map(\.path))
            .reduce(bodyPath.boundingBoxOfPath) { $0.union($1.boundingBoxOfPath) }
    }
}

struct NativeFaceGeometry: Decodable, Sendable {
    var x: Double; var y: Double; var sx: Double; var sy: Double; var eye: Double
}
struct NativeMotionGeometry: Decodable, Sendable {
    var path: String; var ring: [[Double]]; var face: NativeFaceGeometry
    var beltRadius: Double; var tiltScale: Double; var solid: [[Double]]?
}
struct NativeStatusGeometry: Decodable, Sendable {
    var path: String?; var face: NativeFaceGeometry; var marks: [String: [Double]]
}
struct NativeRestGeometry: Decodable, Sendable {
    struct Offset: Decodable, Sendable { var x: Double; var y: Double }
    var radii: [Double]; var offsets: [String: Offset]
}
struct NativeGeometryCatalog: Decodable, Sendable {
    var motion: [String: NativeMotionGeometry]
    var eyeContours: [String: [[[Double]]]]
    var status: [String: NativeStatusGeometry]
    var rest: [String: NativeRestGeometry]
    static let shared = try! JSONDecoder().decode(Self.self, from: Data(NativeMotionData.json.utf8))
}

/// Bounded by live instances. A backward seek reconstructs the deterministic 60 Hz
/// simulation; increasing time advances only the new ticks, with no short-loop wrap.
@MainActor
final class NativeMotionSampler {
    static let staticTimes: [PresenceState: Double] = [
        .idle: 1, .working: 1.2, .thinking: 2.4, .waiting: 2.4,
        .blocked: 2.4, .done: 4.85, .offline: 0.35
    ]
    private var clocks: [String: NativeOfficialMotionClock] = [:]
    private var paths: [String: CGPath] = [:]

    func reset(instanceID: String) { clocks.removeValue(forKey: instanceID) }
    func resetAll() { clocks.removeAll() }

    func sample(shape: OfficialShape, state: PresenceState, time: Double,
                instanceID: String, reducedMotion: Bool = false) -> NativeMotionFrame {
        let time = reducedMotion ? Self.staticTimes[state]! : max(0, time)
        if state == .working || state == .done {
            var clock = clocks[instanceID]
            if clock == nil || clock!.state != state || clock!.shape != shape || time < clock!.time - 0.000001 {
                clock = NativeOfficialMotionClock(state: state, shape: shape)
                clocks[instanceID] = clock
            }
            clock!.advance(to: time)
            return clock!.render(basePath: cachedPath("motion-" + shape.rawValue,
                source: NativeGeometryCatalog.shared.motion[shape.rawValue]!.path))
        }
        clocks.removeValue(forKey: instanceID)
        if state == .thinking || state == .blocked { return statusFrame(shape: shape, state: state, time: time) }
        return NativeRestSampler.sample(shape: shape, state: state, time: time)
    }

    private func cachedPath(_ key: String, source: String) -> CGPath {
        if let value = paths[key] { return value }
        let value = nativeSourcePath(source)
        paths[key] = value
        return value
    }

    private func statusFrame(shape: OfficialShape, state: PresenceState, time: Double) -> NativeMotionFrame {
        let geometry = NativeGeometryCatalog.shared.status[shape.kitName]!
        let body: CGPath
        if let source = geometry.path { body = cachedPath("status-" + shape.rawValue, source: source) }
        else { body = CGPath(ellipseIn: CGRect(x: -nativeCenter, y: -nativeCenter, width: 2 * nativeCenter, height: 2 * nativeCenter), transform: nil) }
        let breath = sin(nativeTau * time / 4.2)
        let slowTurn = sin(nativeTau * time / 4.2 + 0.4)
        let roll = state == .thinking ? -1.1 + 0.55 * slowTurn : 0.45 * slowTurn
        let pose = CGAffineTransform(translationX: 0, y: -1.25 * breath)
            .rotated(by: roll * .pi / 180).scaledBy(x: 1 + 0.004 * breath, y: 1 - 0.003 * breath)
        var result = NativeMotionFrame(bodyPath: nativeTransform(body, pose), sampleTime: time)
        let phase = time.truncatingRemainder(dividingBy: 6.3)
        let thinking = state == .thinking
        let blinkAt = thinking ? 3.55 : 3.3
        let lid = 1 - 0.94 * nativeSmooth((phase - blinkAt) / 0.085) * (1 - nativeSmooth((phase - blinkAt - 0.105) / 0.145))
        let lookUp = nativeSmooth((phase - 0.25) / 0.8) * (1 - nativeSmooth((phase - 3.85) / 0.95))
        let ponder = nativeSmooth((phase - 0.9) / 0.55) * (1 - nativeSmooth((phase - 3.8) / 0.55))
        let curiosity = nativeSmooth((time - 0.12) / 0.8) * (0.9 + 0.1 * sin(nativeTau * phase / 6.3))
        let gazeX = thinking ? 6.5 * lookUp : -3 * curiosity
        let gazeY = thinking ? -8 * lookUp : 0.8 * sin(nativeTau * phase / 6.3)
        let tilt = thinking ? 0 : -4.5 * curiosity
        let centers = [CGPoint(x: 22.3518, y: -47.5393), CGPoint(x: 71.4174, y: -57.0622)]
        for index in 0..<2 {
            let eye = NativeGeometryCatalog.shared.eyeContours["0"]![index].map { CGPoint(x: $0[0] - nativeCenter, y: $0[1] - nativeCenter) }
            let center = centers[index], face = geometry.face
            let height = thinking ? 1 - 0.24 * ponder : 1 + (index == 0 ? -0.36 : 0.14) * curiosity
            let width = thinking ? 1 : 1 + (index == 0 ? -0.03 : 0.04) * curiosity
            let lift = thinking ? 0 : (index == 0 ? 4.0 : -4.0) * curiosity
            let matrix = CGAffineTransform(rotationAngle: tilt * .pi / 180)
                .translatedBy(x: face.x + (center.x + gazeX) * face.sx, y: face.y + (center.y + gazeY + lift) * face.sy)
                .rotated(by: -24 * .pi / 180).scaledBy(x: width * face.eye, y: height * lid * face.eye)
                .rotated(by: 24 * .pi / 180).translatedBy(x: -center.x, y: -center.y)
            result.eyes.append(NativePaintPath(path: nativeTransform(nativePolygon(eye), matrix.concatenating(pose))))
        }
        let anchor = geometry.marks[state.rawValue]!
        if thinking {
            let phase = (time / 1.4 + 0.119).truncatingRemainder(dividingBy: 1)
            for index in 0..<3 {
                let separation = abs(phase - Double(index) / 3)
                let distance = min(separation, 1 - separation)
                let pulse = exp(-distance * distance / 0.045)
                let radius = 22 * (index == 1 ? 1 : 1.02) * (0.84 + 0.22 * pulse) * 0.48
                let x = anchor[0] + Double(index - 1) * 62 * 0.48, y = anchor[1] - 11 * pulse * 0.48
                let dot = CGPath(ellipseIn: CGRect(x: x-radius, y: y-radius, width: radius*2, height: radius*2), transform: nil)
                result.marks.append(NativePaintPath(path: nativeTransform(dot, pose), opacity: 0.58 + 0.42 * pulse))
            }
        } else {
            let beat = time.truncatingRemainder(dividingBy: 2.1)
            let bounce = beat < 0.68 ? pow(sin(.pi * beat / 0.68), 2) : 0
            let swing = beat < 0.68 ? 4 * sin(nativeTau * beat / 0.68) * bounce : 0
            let scale = 0.52 * (1 + 0.08 * bounce)
            let matrix = CGAffineTransform(translationX: anchor[0], y: anchor[1] - 13 * bounce)
                .rotated(by: swing * .pi / 180).scaledBy(x: scale, y: scale).concatenating(pose)
            let stem = CGMutablePath()
            stem.move(to: CGPoint(x: -15, y: -57.5))
            stem.addArc(center: CGPoint(x: 0, y: -57.5), radius: 15, startAngle: .pi, endAngle: 2 * .pi, clockwise: false)
            stem.addLine(to: CGPoint(x: 8.5, y: 15))
            stem.addArc(center: CGPoint(x: 0, y: 15), radius: 8.5, startAngle: 0, endAngle: .pi, clockwise: false)
            stem.closeSubpath()
            stem.addEllipse(in: CGRect(x: -13, y: 46.5, width: 26, height: 26))
            result.marks = [NativePaintPath(path: nativeTransform(stem, matrix))]
        }
        return result
    }
}

extension OfficialShape {
    var kitName: String {
        switch self {
        case .blob: "cercle"
        case .pebble: "galet"
        case .squircle: "squircle"
        case .tablet: "capsule"
        case .wedge: "triangle"
        case .hex: "hexagone"
        case .cloud: "nuage"
        case .teardrop: "goutte"
        }
    }
}

let nativeCenter = 114.2705
let nativeTau = Double.pi * 2
func nativeClamp(_ value: Double, _ lower: Double = 0, _ upper: Double = 1) -> Double { max(lower, min(upper, value)) }
func nativeSmooth(_ value: Double) -> Double { let p = nativeClamp(value); return p * p * (3 - 2 * p) }
func nativeRound(_ value: Double, digits: Double = 100) -> Double { floor(value * digits + 0.5) / digits }
func nativeTransform(_ path: CGPath, _ transform: CGAffineTransform) -> CGPath {
    var transform = transform
    return path.copy(using: &transform)!
}
func nativePolygon(_ points: [CGPoint], curved: Bool = false, rounding: Double = 1000) -> CGPath {
    let path = CGMutablePath()
    guard let first = points.first else { return path }
    func round(_ point: CGPoint) -> CGPoint { CGPoint(x: nativeRound(point.x, digits: rounding), y: nativeRound(point.y, digits: rounding)) }
    path.move(to: round(first))
    for i in points.indices {
        let next = points[(i + 1) % points.count]
        if curved {
            let before = points[(i + points.count - 1) % points.count], current = points[i], after = points[(i + 2) % points.count]
            let c1 = CGPoint(x: current.x + (next.x - before.x) / 6, y: current.y + (next.y - before.y) / 6)
            let c2 = CGPoint(x: next.x - (after.x - current.x) / 6, y: next.y - (after.y - current.y) / 6)
            path.addCurve(to: round(next), control1: round(c1), control2: round(c2))
        } else { path.addLine(to: round(next)) }
    }
    path.closeSubpath()
    return path
}

/// The source outlines contain only absolute M/L/C/Q/Z commands. Parsed once per shape.
func nativeSourcePath(_ source: String) -> CGPath {
    let regex = try! NSRegularExpression(pattern: "[MLCQZ]|[-+]?(?:[0-9]*\\.)?[0-9]+(?:[eE][-+]?[0-9]+)?")
    let string = source as NSString
    let tokens = regex.matches(in: source, range: NSRange(location: 0, length: string.length)).map { string.substring(with: $0.range) }
    let path = CGMutablePath()
    var index = 0
    func point() -> CGPoint {
        let result = CGPoint(x: Double(tokens[index])!, y: Double(tokens[index + 1])!)
        index += 2
        return result
    }
    while index < tokens.count {
        let command = tokens[index]; index += 1
        switch command {
        case "M": path.move(to: point())
        case "L": path.addLine(to: point())
        case "C": let c1 = point(), c2 = point(), end = point(); path.addCurve(to: end, control1: c1, control2: c2)
        case "Q": let control = point(), end = point(); path.addQuadCurve(to: end, control: control)
        case "Z": path.closeSubpath()
        default: preconditionFailure("Unsupported approved outline command: \(command)")
        }
    }
    return path
}

final class NativeSeededRandom {
    private var state: UInt32
    init(seed: UInt32 = 1) { state = seed }
    func next() -> Double {
        state = state &+ 1_831_565_813
        var value = (state ^ (state >> 15)) &* (1 | state)
        value ^= value &+ ((value ^ (value >> 7)) &* (61 | value))
        return Double(value ^ (value >> 14)) / 4_294_967_296
    }
    func range(_ a: Double, _ b: Double) -> Double { a + next() * (b - a) }
}
