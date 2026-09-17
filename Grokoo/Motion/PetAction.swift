import Foundation

enum PetAction: String, Codable, CaseIterable, Sendable {
    case idleBreathe
    case blink
    case floorMove
    case climbLeft
    case climbRight
    case ceilingHang
    case ceilingMove
    case turnBottomCorner
    case turnTopCorner
    case teleportToStation
    case workAtStation
    case waitAtStation
    case celebrate
    case offlineSleep
    case joinGroupStation
    case workInGroup
    case leaveGroupStation

    var priority: Int {
        switch self {
        case .offlineSleep: 500
        case .waitAtStation: 400
        case .joinGroupStation, .workInGroup, .leaveGroupStation: 320
        case .teleportToStation, .workAtStation: 300
        case .celebrate: 250
        case .turnBottomCorner, .turnTopCorner: 200
        default: 100
        }
    }
}

struct AnimationActionDefinition: Codable, Equatable, Sendable {
    let driver: String
    let state: String
    let surfaces: [EdgeSurface]
    let durationRangeSeconds: [Double]
    let loop: Bool
    let preservesShape: Bool
    let fallback: String?

    var durationRange: ClosedRange<TimeInterval> {
        let lower = durationRangeSeconds.first ?? 0
        let upper = durationRangeSeconds.dropFirst().first ?? lower
        return min(lower, upper)...max(lower, upper)
    }
}

struct AnimationManifest: Codable, Equatable, Sendable {
    let version: Int
    private let actions: [String: AnimationActionDefinition]

    subscript(action: PetAction) -> AnimationActionDefinition? { actions[action.rawValue] }
    var mappedActions: Set<PetAction> { Set(actions.keys.compactMap(PetAction.init(rawValue:))) }
    var hasCompleteMVPMapping: Bool { mappedActions == Set(PetAction.allCases) }
}

enum AnimationManifestLoader {
    static func load(from data: Data) throws -> AnimationManifest {
        try JSONDecoder().decode(AnimationManifest.self, from: data)
    }

    static func load(from url: URL) throws -> AnimationManifest {
        try load(from: Data(contentsOf: url))
    }

    static func loadBundled() throws -> AnimationManifest {
        guard let url = Bundle.main.url(forResource: "animation-manifest", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try load(from: url)
    }
}
