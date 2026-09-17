import Foundation

enum MBTIType: String, Codable, CaseIterable, Identifiable, Sendable {
    case istj = "ISTJ"
    case isfj = "ISFJ"
    case infj = "INFJ"
    case intj = "INTJ"
    case istp = "ISTP"
    case isfp = "ISFP"
    case infp = "INFP"
    case intp = "INTP"
    case estp = "ESTP"
    case esfp = "ESFP"
    case enfp = "ENFP"
    case entp = "ENTP"
    case estj = "ESTJ"
    case esfj = "ESFJ"
    case enfj = "ENFJ"
    case entj = "ENTJ"
    var id: String { rawValue }
}

struct BehaviorPreset: Codable, Equatable, Sendable {
    var moveWeight: Double
    var exploreWeight: Double
    var socialWeight: Double
    var restWeight: Double
    var speedMultiplier: Double
    var dwellMultiplier: Double
    var socialDistance: Double
    var decorationId: String?
}

struct MBTIPresetCatalog: Equatable, Sendable {
    let version: Int
    let neutral: BehaviorPreset
    let presets: [MBTIType: BehaviorPreset]

    func preset(for type: MBTIType?) -> BehaviorPreset { type.flatMap { presets[$0] } ?? neutral }
}

enum MBTIPresetError: Error, Equatable {
    case missingBundledResource
    case incompleteTypes(missing: Set<MBTIType>)
}

enum MBTIPresetLoader {
    private struct RangeDefinition: Codable {
        let min: Double
        let max: Double
    }

    private struct ClampDefinition: Codable {
        let actionWeight: RangeDefinition
        let speedMultiplier: RangeDefinition
        let dwellMultiplier: RangeDefinition
        let socialDistance: RangeDefinition
    }

    private struct Document: Codable {
        let version: Int
        let clamp: ClampDefinition
        let neutral: BehaviorPreset
        let presets: [String: BehaviorPreset]
    }

    static func load(from data: Data) throws -> MBTIPresetCatalog {
        let document = try JSONDecoder().decode(Document.self, from: data)
        let decoded = Dictionary(uniqueKeysWithValues: document.presets.compactMap { key, preset in
            MBTIType(rawValue: key).map { ($0, clamp(preset, with: document.clamp)) }
        })
        let missing = Set(MBTIType.allCases).subtracting(decoded.keys)
        guard missing.isEmpty else { throw MBTIPresetError.incompleteTypes(missing: missing) }
        return MBTIPresetCatalog(
            version: document.version,
            neutral: clamp(document.neutral, with: document.clamp),
            presets: decoded
        )
    }

    static func load(from url: URL) throws -> MBTIPresetCatalog {
        try load(from: Data(contentsOf: url))
    }

    static func loadBundled() throws -> MBTIPresetCatalog {
        guard let url = Bundle.main.url(forResource: "mbti-presets", withExtension: "json") else {
            throw MBTIPresetError.missingBundledResource
        }
        return try load(from: url)
    }

    private static func clamp(_ preset: BehaviorPreset, with ranges: ClampDefinition) -> BehaviorPreset {
        func limited(_ value: Double, _ range: RangeDefinition) -> Double { min(max(value, range.min), range.max) }
        return BehaviorPreset(
            moveWeight: limited(preset.moveWeight, ranges.actionWeight),
            exploreWeight: limited(preset.exploreWeight, ranges.actionWeight),
            socialWeight: limited(preset.socialWeight, ranges.actionWeight),
            restWeight: limited(preset.restWeight, ranges.actionWeight),
            speedMultiplier: limited(preset.speedMultiplier, ranges.speedMultiplier),
            dwellMultiplier: limited(preset.dwellMultiplier, ranges.dwellMultiplier),
            socialDistance: limited(preset.socialDistance, ranges.socialDistance),
            decorationId: preset.decorationId
        )
    }
}
