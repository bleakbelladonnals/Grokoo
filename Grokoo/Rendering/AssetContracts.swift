import CoreGraphics
import Foundation

enum AccessoryID: String, Codable, CaseIterable, Sendable {
    case intj, intp, entj, entp
    case infj, infp, enfj, enfp
    case istj, isfj, estj, esfj
    case istp, isfp, estp, esfp

    var assetCatalogKey: String { "MBTI-\(rawValue.uppercased())" }
}

struct NormalizedAccessoryAnchor: Codable, Equatable, Sendable {
    let x: CGFloat
    let y: CGFloat
}

enum BodyAnchorCatalog {
    static let anchors: [OfficialShape: NormalizedAccessoryAnchor] = [
        .blob: .init(x: 0.50, y: 0.84), .pebble: .init(x: 0.50, y: 0.82),
        .squircle: .init(x: 0.50, y: 0.86), .tablet: .init(x: 0.50, y: 0.88),
        .wedge: .init(x: 0.52, y: 0.82), .hex: .init(x: 0.50, y: 0.84),
        .teardrop: .init(x: 0.50, y: 0.80), .cloud: .init(x: 0.50, y: 0.82),
    ]
}

enum AssetContract {
    static let freeBodySize: CGFloat = 32
    static let workspaceBodySize: CGFloat = 42
    static let maximumVisibleExtent: CGFloat = 52
    /// Transparent drawing room from the approved kit, never a hit region.
    static let motionContainerMultiplier: CGFloat = 2.4
    static func isSupportedBodySize(_ size: CGFloat) -> Bool { size == freeBodySize || size == workspaceBodySize }
}

enum MotionActionID: String, Codable, CaseIterable, Sendable {
    case idle, working, thinking, waiting, blocked, done, offline
}

struct MotionProfileMap: Codable, Equatable, Sendable {
    let action: MotionActionID
    let profileKey: String
    static let reserved = PresenceState.allCases.map {
        MotionProfileMap(action: MotionActionID(rawValue: $0.rawValue)!, profileKey: "native.\($0.rawValue).kit-1.0.0")
    }
}
