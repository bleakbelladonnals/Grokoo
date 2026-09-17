import Foundation

struct SeededRandomNumberGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x6D2B79F5
        var value = state
        value = (value ^ (value >> 15)) &* (1 | value)
        value ^= value &+ ((value ^ (value >> 7)) &* (61 | value))
        return value ^ (value >> 14)
    }

    mutating func unitInterval() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }
}

struct BehaviorCandidate: Equatable, Sendable {
    let action: PetAction
    var baseWeight: Double
}

struct SampledBehavior: Equatable, Sendable {
    let action: PetAction
    let speedMultiplier: Double
    let dwellMultiplier: Double
    let socialDistance: Double
}

struct BehaviorSampler: Sendable {
    private var random: SeededRandomNumberGenerator

    init(seed: UInt64) { random = SeededRandomNumberGenerator(seed: seed) }

    mutating func sample(
        presence: PresenceState,
        surface: EdgeSurface,
        preset: BehaviorPreset,
        candidates suppliedCandidates: [BehaviorCandidate]? = nil,
        coolingDown: Set<PetAction> = []
    ) -> SampledBehavior {
        guard presence == .idle else {
            let forced: PetAction
            switch presence {
            case .working, .thinking: forced = surface == .groupStation ? .workInGroup : .workAtStation
            case .waiting, .blocked: forced = .waitAtStation
            case .done: forced = .celebrate
            case .offline: forced = .offlineSleep
            case .idle: forced = .idleBreathe
            }
            return result(forced, preset: preset)
        }

        let candidates = (suppliedCandidates ?? defaultCandidates(for: surface)).filter {
            $0.baseWeight > 0 && !coolingDown.contains($0.action) && actionAllowed($0.action, on: surface)
        }
        guard !candidates.isEmpty else { return result(.idleBreathe, preset: preset) }
        let weighted = candidates.map { candidate in
            (candidate, candidate.baseWeight * personalityWeight(for: candidate.action, preset: preset))
        }.filter { $0.1 > 0 }
        let total = weighted.reduce(0) { $0 + $1.1 }
        guard total > 0 else { return result(.idleBreathe, preset: preset) }
        var cursor = random.unitInterval() * total
        for (candidate, weight) in weighted {
            cursor -= weight
            if cursor <= 0 { return result(candidate.action, preset: preset) }
        }
        return result(weighted.last?.0.action ?? .idleBreathe, preset: preset)
    }

    private func result(_ action: PetAction, preset: BehaviorPreset) -> SampledBehavior {
        SampledBehavior(action: action, speedMultiplier: preset.speedMultiplier, dwellMultiplier: preset.dwellMultiplier, socialDistance: preset.socialDistance)
    }

    private func personalityWeight(for action: PetAction, preset: BehaviorPreset) -> Double {
        switch action {
        case .floorMove: preset.moveWeight * 0.8 + preset.socialWeight * 0.2
        case .climbLeft, .climbRight, .ceilingMove: preset.moveWeight
        case .turnBottomCorner, .turnTopCorner: preset.exploreWeight
        case .ceilingHang: (preset.exploreWeight + preset.restWeight) / 2
        case .idleBreathe, .blink: preset.restWeight
        default: 1
        }
    }

    private func actionAllowed(_ action: PetAction, on surface: EdgeSurface) -> Bool {
        switch action {
        case .floorMove: surface == .floor
        case .climbLeft: surface == .leftWall
        case .climbRight: surface == .rightWall
        case .ceilingHang, .ceilingMove: surface == .ceiling
        case .turnBottomCorner: [.floor, .leftWall, .rightWall].contains(surface)
        case .turnTopCorner: [.leftWall, .rightWall, .ceiling].contains(surface)
        case .idleBreathe, .blink: true
        default: false
        }
    }

    private func defaultCandidates(for surface: EdgeSurface) -> [BehaviorCandidate] {
        switch surface {
        case .floor:
            [.init(action: .idleBreathe, baseWeight: 1), .init(action: .blink, baseWeight: 0.28), .init(action: .floorMove, baseWeight: 1), .init(action: .turnBottomCorner, baseWeight: 0.3)]
        case .leftWall:
            [.init(action: .idleBreathe, baseWeight: 0.7), .init(action: .blink, baseWeight: 0.25), .init(action: .climbLeft, baseWeight: 1), .init(action: .turnBottomCorner, baseWeight: 0.2), .init(action: .turnTopCorner, baseWeight: 0.25)]
        case .rightWall:
            [.init(action: .idleBreathe, baseWeight: 0.7), .init(action: .blink, baseWeight: 0.25), .init(action: .climbRight, baseWeight: 1), .init(action: .turnBottomCorner, baseWeight: 0.2), .init(action: .turnTopCorner, baseWeight: 0.25)]
        case .ceiling:
            [.init(action: .ceilingHang, baseWeight: 0.8), .init(action: .blink, baseWeight: 0.25), .init(action: .ceilingMove, baseWeight: 1), .init(action: .turnTopCorner, baseWeight: 0.25)]
        case .station, .groupStation:
            [.init(action: .idleBreathe, baseWeight: 1), .init(action: .blink, baseWeight: 0.3)]
        }
    }
}
