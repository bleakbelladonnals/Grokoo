import CoreGraphics
import Foundation

/// The approved resting renderer always samples Bloub's idle silhouette with
/// neutral / blasé / sleepy eyes; unrelated Bloub states and decor stay out.
enum NativeRestSampler {
    private static let blinks: [Double] = {
        let random = NativeSeededRandom(seed: 0x5eed)
        var result: [Double] = [], time = 1.4
        while time < 900 {
            result.append(time)
            time += 1.9 + random.next() * 2.7
            if random.next() < 0.18 { result.append(time); time += 0.24 }
        }
        return result
    }()

    static func sample(shape: OfficialShape, state: PresenceState, time t: Double) -> NativeMotionFrame {
        let geometry = NativeGeometryCatalog.shared.rest[shape.kitName]!
        let wander = state == .waiting ? 0.22 : 1.0
        let dYaw = (noise(t, 11.3, 0.4) * 5.5 + noise(t, 3.7, 2.1) * 1.6) * wander
        let dPitch = (noise(t, 9.1, 1.3) * 4.2 + noise(t, 4.3, 0.7) * 1.3) * wander
        let dRoll = noise(t, 13.7, 3.2) * 2.2 * wander
        let driftX = noise(t, 7.9, 1.9) * 0.006, driftY = noise(t, 5.3, 0.3) * 0.007
        let breath = 1 + sin(t / 3.4 * nativeTau) * 0.005
        let points = geometry.radii.enumerated().map { index, radius in
            let angle = Double(index) / Double(geometry.radii.count) * nativeTau
            return CGPoint(x: (radius * cos(angle) + driftX) * 100, y: (radius * sin(angle) * breath + driftY) * 100)
        }
        let shapeScale: Double
        switch shape {
        case .blob: shapeScale = 0.92
        case .pebble: shapeScale = 0.96
        case .squircle: shapeScale = 0.84
        case .wedge, .hex: shapeScale = 0.94
        default: shapeScale = 1
        }
        let expression: String, yaw: Double, pitch: Double, roll: Double, split: Double
        let eyeWidth: Double, eyeHeight: Double, eyeOpen: Double
        let poseRoll: Double, poseScale: Double, poseX: Double, poseY: Double
        switch state {
        case .waiting:
            expression = "blase"; yaw = -3 + 4 * sin(0.25 * t); pitch = 4 * sin(0.2 * t); roll = 0; split = 16
            eyeWidth = 0.3; eyeHeight = 0.12; eyeOpen = 1
            poseRoll = 5 + 1.5 * sin(0.35 * t); poseScale = 0.98; poseX = -1 + 1.2 * sin(0.25 * t); poseY = 1.2
        case .offline:
            expression = "somnolent"; yaw = 6; pitch = -9; roll = -3; split = 16
            eyeWidth = 0.2; eyeHeight = 0.42; eyeOpen = 0.42
            poseRoll = -3 + 0.6 * sin(0.28 * t); poseScale = 0.94 + 0.006 * sin(0.55 * t); poseX = 0; poseY = 3
        default:
            expression = "neutre"; yaw = 28.49; pitch = 28.62; roll = -13; split = 15.46
            eyeWidth = 0.186; eyeHeight = 0.412; eyeOpen = 1
            poseRoll = 1.2 * sin(0.85 * t); poseScale = 1 + 0.007 * sin(0.85 * t); poseX = 0; poseY = 0
        }
        let scale = nativeRound(1.2927 * shapeScale * poseScale, digits: 10000)
        let pose = CGAffineTransform(translationX: nativeRound(poseX), y: nativeRound(poseY))
            .rotated(by: nativeRound(poseRoll) * .pi / 180).scaledBy(x: scale, y: scale)
        var frame = NativeMotionFrame(bodyPath: nativeTransform(nativePolygon(points, curved: true, rounding: 100), pose),
                                      opacity: state == .offline ? 0.52 : 1, sampleTime: t)
        var lid = 1.0
        for start in blinks {
            if t < start { break }
            let phase = (t - start) / 0.18
            if phase >= 0 && phase <= 1 { lid = phase < 0.45 ? 1 - phase / 0.45 : (phase - 0.45) / 0.55; break }
        }
        let k = 0.06 + 0.94 * nativeClamp(min(lid, eyeOpen))
        let offset = geometry.offsets[expression]!
        let eyePath = CGPath(roundedRect: CGRect(x: -eyeWidth * 50, y: -eyeHeight * 50, width: eyeWidth * 100, height: eyeHeight * 100),
                             cornerWidth: min(eyeWidth, eyeHeight) * 50, cornerHeight: min(eyeWidth, eyeHeight) * 50, transform: nil)
        for eye in eyePoses(yaw: yaw+dYaw, pitch: pitch+dPitch, roll: roll+dRoll, split: split) where eye.depth > 0.02 {
            let fit = radius(geometry.radii, at: atan2(eye.y, eye.x))
            let matrix = CGAffineTransform(a: nativeRound(eye.a), b: nativeRound(eye.b*k), c: nativeRound(eye.c), d: nativeRound(eye.d*k),
                tx: nativeRound(eye.x * fit + (driftX + offset.x)*100), ty: nativeRound(eye.y * fit + (driftY + offset.y)*100))
            frame.eyes.append(NativePaintPath(path: nativeTransform(eyePath, matrix.concatenating(pose)), opacity: nativeClamp(eye.depth/0.12)))
        }
        return frame
    }

    private static func noise(_ t: Double, _ period: Double, _ seed: Double) -> Double {
        let p = t / period * nativeTau
        return 0.55 * sin(p + seed) + 0.3 * sin(2*p + seed*1.7 + 1.1) + 0.15 * sin(3*p + seed*2.3 + 2.4)
    }
    private static func radius(_ radii: [Double], at angle: Double) -> Double {
        let fraction = ((angle / nativeTau).truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1)
        let offset = fraction * Double(radii.count), lower = Int(floor(offset))
        return radii[lower % radii.count] + (radii[(lower+1) % radii.count] - radii[lower % radii.count]) * (offset-Double(lower))
    }
    private struct EyePose { var x: Double; var y: Double; var a: Double; var b: Double; var c: Double; var d: Double; var depth: Double }
    private static func eyePoses(yaw: Double, pitch: Double, roll: Double, split: Double) -> [EyePose] {
        func spin(_ u: [Double], _ v: [Double], _ degrees: Double) -> ([Double], [Double]) {
            let c = cos(degrees * .pi/180), s = sin(degrees * .pi/180)
            return ((0..<3).map { u[$0]*c + v[$0]*s }, (0..<3).map { v[$0]*c - u[$0]*s })
        }
        var forward = [0.0,0,1], right = [1.0,0,0], down = [0.0,1,0]
        (forward,right) = spin(forward,right,yaw)
        (down,forward) = spin(down,forward,pitch)
        (right,down) = spin(right,down,roll)
        return [-1.0,1].map { side in
            let (ef,er) = spin(forward,right,split*side)
            return EyePose(x: ef[0]*100, y: ef[1]*100, a: er[0], b: er[1], c: down[0], d: down[1], depth: ef[2])
        }
    }
}
