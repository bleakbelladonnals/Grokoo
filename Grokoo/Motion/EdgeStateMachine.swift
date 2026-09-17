import CoreGraphics
import Foundation

enum EdgeSurface: String, Codable, CaseIterable, Sendable {
    case floor
    case leftWall
    case rightWall
    case ceiling
    case station
    case groupStation
}

enum EdgeDirection: Int, Codable, Sendable { case backward = -1, forward = 1 }

struct EdgeState: Equatable, Sendable {
    var surface: EdgeSurface
    var normalizedPosition: CGFloat
    var direction: EdgeDirection
}

struct EdgeTransition: Equatable, Sendable {
    let action: PetAction
    let destination: EdgeState
}

struct EdgeStateMachine: Sendable {
    private(set) var state: EdgeState

    init(state: EdgeState = EdgeState(surface: .floor, normalizedPosition: 0.5, direction: .forward)) {
        self.state = state
    }

    mutating func transition(toward destination: EdgeSurface) -> EdgeTransition? {
        let action: PetAction
        switch (state.surface, destination) {
        case (.floor, .leftWall), (.floor, .rightWall): action = .turnBottomCorner
        case (.leftWall, .floor), (.rightWall, .floor): action = .turnBottomCorner
        case (.leftWall, .ceiling), (.rightWall, .ceiling), (.ceiling, .leftWall), (.ceiling, .rightWall): action = .turnTopCorner
        case (_, .station): action = .teleportToStation
        case (_, .groupStation): action = .joinGroupStation
        case (.groupStation, _): action = .leaveGroupStation
        default:
            switch destination {
            case .floor: action = .floorMove
            case .leftWall: action = .climbLeft
            case .rightWall: action = .climbRight
            case .ceiling: action = .ceilingMove
            case .station: action = .teleportToStation
            case .groupStation: action = .joinGroupStation
            }
        }
        var next = state
        next.surface = destination
        switch destination {
        case .leftWall: next.normalizedPosition = state.surface == .ceiling ? 1 : 0
        case .rightWall: next.normalizedPosition = state.surface == .ceiling ? 1 : 0
        case .ceiling: next.normalizedPosition = state.surface == .leftWall ? 0 : 1
        case .floor: next.normalizedPosition = state.surface == .leftWall ? 0 : 1
        case .station, .groupStation: next.normalizedPosition = 0.5
        }
        state = next
        return EdgeTransition(action: action, destination: next)
    }

    mutating func advance(to normalizedPosition: CGFloat) {
        state.normalizedPosition = min(max(normalizedPosition, 0), 1)
    }
}

struct EdgeOccupancy: Sendable {
    private var reservations: [BotID: ClosedRange<CGFloat>] = [:]

    mutating func reserve(botId: BotID, center: CGFloat, minimumDistance: CGFloat, edgeLength: CGFloat) -> Bool {
        let normalizedHalf = edgeLength > 0 ? minimumDistance / edgeLength / 2 : 1
        let candidate = max(0, center - normalizedHalf)...min(1, center + normalizedHalf)
        guard !reservations.values.contains(where: { $0.overlaps(candidate) }) else { return false }
        reservations[botId] = candidate
        return true
    }

    mutating func release(botId: BotID) { reservations.removeValue(forKey: botId) }
}

/// Physical point/segment reservations shared by all four edges. Reserving the
/// complete travel segment prevents a moving pet from crossing a stationary
/// pet or another in-flight route, including through adjacent corners.
struct EdgePointOccupancy: Sendable {
    private struct Reservation: Sendable {
        let start: CGPoint
        let end: CGPoint
    }

    private var reservations: [BotID: Reservation] = [:]

    mutating func register(botId: BotID, point: CGPoint) {
        reservations[botId] = Reservation(start: point, end: point)
    }

    mutating func reserve(botId: BotID, point: CGPoint, minimumDistance: CGFloat) -> Bool {
        reserve(botId: botId, from: point, to: point, minimumDistance: minimumDistance)
    }

    mutating func reserve(
        botId: BotID,
        from start: CGPoint,
        to end: CGPoint,
        minimumDistance: CGFloat
    ) -> Bool {
        let candidate = Reservation(start: start, end: end)
        guard reservations.allSatisfy({ otherBotId, other in
            otherBotId == botId
                || Self.distance(candidate, other) >= minimumDistance
                || Self.canEscapeCrowdedStart(candidate, from: other, minimumDistance: minimumDistance)
        }) else { return false }
        reservations[botId] = candidate
        return true
    }

    mutating func release(botId: BotID) {
        reservations.removeValue(forKey: botId)
    }

    mutating func removeAll() {
        reservations.removeAll()
    }

    private static func distance(_ lhs: Reservation, _ rhs: Reservation) -> CGFloat {
        if intersects(lhs, rhs) { return 0 }
        return min(
            pointDistance(lhs.start, to: rhs),
            pointDistance(lhs.end, to: rhs),
            pointDistance(rhs.start, to: lhs),
            pointDistance(rhs.end, to: lhs)
        )
    }

    /// Workstation slots are intentionally 40–44 pt apart while personality
    /// spacing can be up to 68 pt. Let the outside pet move directly away from
    /// a stationary neighbour so a crowded row can drain into the edge route;
    /// crossing, approaching and conflicts with another in-flight segment stay
    /// rejected.
    private static func canEscapeCrowdedStart(
        _ candidate: Reservation,
        from other: Reservation,
        minimumDistance: CGFloat
    ) -> Bool {
        let epsilon: CGFloat = 0.0001
        let otherLength = hypot(other.end.x - other.start.x, other.end.y - other.start.y)
        let candidateDX = candidate.end.x - candidate.start.x
        let candidateDY = candidate.end.y - candidate.start.y
        let candidateLength = hypot(candidateDX, candidateDY)
        guard otherLength <= epsilon, candidateLength > epsilon else { return false }

        let startDistance = hypot(candidate.start.x - other.start.x, candidate.start.y - other.start.y)
        let endDistance = hypot(candidate.end.x - other.start.x, candidate.end.y - other.start.y)
        guard startDistance < minimumDistance, endDistance >= minimumDistance else { return false }

        let outwardDot = candidateDX * (candidate.start.x - other.start.x)
            + candidateDY * (candidate.start.y - other.start.y)
        return outwardDot > epsilon
    }

    private static func pointDistance(_ point: CGPoint, to segment: Reservation) -> CGFloat {
        let dx = segment.end.x - segment.start.x
        let dy = segment.end.y - segment.start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > .ulpOfOne else {
            return hypot(point.x - segment.start.x, point.y - segment.start.y)
        }
        let projection = ((point.x - segment.start.x) * dx + (point.y - segment.start.y) * dy) / lengthSquared
        let t = min(max(projection, 0), 1)
        return hypot(
            point.x - (segment.start.x + t * dx),
            point.y - (segment.start.y + t * dy)
        )
    }

    private static func intersects(_ lhs: Reservation, _ rhs: Reservation) -> Bool {
        let epsilon: CGFloat = 0.0001
        let lhsLength = hypot(lhs.end.x - lhs.start.x, lhs.end.y - lhs.start.y)
        let rhsLength = hypot(rhs.end.x - rhs.start.x, rhs.end.y - rhs.start.y)
        if lhsLength <= epsilon { return pointDistance(lhs.start, to: rhs) <= epsilon }
        if rhsLength <= epsilon { return pointDistance(rhs.start, to: lhs) <= epsilon }

        let o1 = orientation(lhs.start, lhs.end, rhs.start)
        let o2 = orientation(lhs.start, lhs.end, rhs.end)
        let o3 = orientation(rhs.start, rhs.end, lhs.start)
        let o4 = orientation(rhs.start, rhs.end, lhs.end)
        if o1 * o2 < -epsilon, o3 * o4 < -epsilon { return true }
        return (abs(o1) <= epsilon && pointDistance(rhs.start, to: lhs) <= epsilon)
            || (abs(o2) <= epsilon && pointDistance(rhs.end, to: lhs) <= epsilon)
            || (abs(o3) <= epsilon && pointDistance(lhs.start, to: rhs) <= epsilon)
            || (abs(o4) <= epsilon && pointDistance(lhs.end, to: rhs) <= epsilon)
    }

    private static func orientation(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
        (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
    }
}
