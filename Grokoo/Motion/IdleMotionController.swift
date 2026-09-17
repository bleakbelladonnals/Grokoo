import CoreGraphics
import Foundation
import QuartzCore

/// Low-frequency, cancellable four-edge route runner for idle pets.
@MainActor
final class IdleMotionController {
    private struct RouteState {
        var step: Int
        var sampler: BehaviorSampler
        var preset: BehaviorPreset
        var consecutiveRests = 0
        var failedReservations = 0
        let clockwise: Bool
        let homePoint: CGPoint
    }

    private let coordinator: AnimationCoordinator
    private var tasks: [BotID: Task<Void, Never>] = [:]
    private var routes: [BotID: RouteState] = [:]
    private var occupancy = EdgePointOccupancy()
    private var sharedClockwise: Bool?

    init(coordinator: AnimationCoordinator) { self.coordinator = coordinator }

    func start(pet: PetLayer, geometry: EdgeGeometry, preset: BehaviorPreset) {
        if routes[pet.botId] != nil {
            routes[pet.botId]?.preset = preset
        }
        guard tasks[pet.botId] == nil else { return }
        let seed = Self.seed(for: pet.botId)
        if routes[pet.botId] == nil {
            if sharedClockwise == nil { sharedClockwise = seed.isMultiple(of: 2) }
            routes[pet.botId] = RouteState(
                step: 0,
                sampler: BehaviorSampler(seed: seed),
                preset: preset,
                clockwise: sharedClockwise ?? true,
                homePoint: pet.position
            )
        }
        occupancy.register(botId: pet.botId, point: pet.position)
        let route = routes[pet.botId]!
        let destination = Self.plan(step: route.step, clockwise: route.clockwise).destination
            .map { geometry.point(surface: $0.surface, normalizedPosition: $0.position) }
            ?? pet.position
        let edgeSpan = max(1, geometry.rightX - geometry.leftX)
        let outwardDelay = 0.10 + min(0.45, abs(destination.x - pet.position.x) / edgeSpan * 0.45)
        tasks[pet.botId] = Task { [weak self, weak pet] in
            try? await Task.sleep(for: .seconds(outwardDelay))
            while !Task.isCancelled {
                guard let self, let pet else { return }
                let duration = self.performNextStep(pet: pet, geometry: geometry)
                try? await Task.sleep(for: .seconds(duration))
            }
        }
    }

    func updatePreset(_ preset: BehaviorPreset, botId: BotID) {
        routes[botId]?.preset = preset
    }

    func currentPreset(for botId: BotID) -> BehaviorPreset? { routes[botId]?.preset }

    func stop(botId: BotID) {
        tasks.removeValue(forKey: botId)?.cancel()
        occupancy.release(botId: botId)
        coordinator.cancel(botId: botId)
    }

    func stopAll(pets: [PetLayer]) {
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        occupancy.removeAll()
        coordinator.cancelAll(pets: pets)
    }

    private func performNextStep(pet: PetLayer, geometry: EdgeGeometry) -> TimeInterval {
        guard var route = routes[pet.botId] else { return 1 }
        occupancy.register(botId: pet.botId, point: pet.position)
        let plan = Self.plan(step: route.step, clockwise: route.clockwise)
        let sampled = route.sampler.sample(
            presence: .idle,
            surface: plan.surface,
            preset: route.preset,
            candidates: [
                BehaviorCandidate(action: plan.action, baseWeight: 1),
                BehaviorCandidate(action: .idleBreathe, baseWeight: route.consecutiveRests >= 2 ? 0 : 0.45),
                BehaviorCandidate(action: .blink, baseWeight: route.consecutiveRests >= 2 ? 0 : 0.12)
            ]
        )
        if sampled.action == .idleBreathe || sampled.action == .blink {
            route.consecutiveRests += 1
            let duration = sampled.action == .blink ? 0.16 : 2.8 * sampled.dwellMultiplier
            coordinator.play(sampled.action, on: pet, duration: duration)
            routes[pet.botId] = route
            return duration
        }

        route.consecutiveRests = 0
        if let destination = plan.destination {
            let point = geometry.point(surface: destination.surface, normalizedPosition: destination.position)
            guard reserve(
                botId: pet.botId,
                from: pet.position,
                to: point,
                minimumDistance: Self.reservationDistance(for: sampled)
            ) else {
                route.failedReservations += 1
                if Self.shouldRecoverRoute(after: route.failedReservations) {
                    route.step = 0
                    route.failedReservations = 0
                    occupancy.register(botId: pet.botId, point: route.homePoint)
                    routes[pet.botId] = route
                    coordinator.play(
                        .teleportToStation,
                        on: pet,
                        destination: route.homePoint,
                        duration: 0.24
                    )
                    return 0.9 * sampled.dwellMultiplier
                }
                routes[pet.botId] = route
                coordinator.play(.idleBreathe, on: pet, duration: 0.8)
                return 0.9
            }
        }
        route.failedReservations = 0
        route.step = (route.step + 1) % 9
        routes[pet.botId] = route
        let duration = Self.duration(for: plan.action, geometry: geometry, speedMultiplier: sampled.speedMultiplier)
        let destination = plan.destination.map { geometry.point(surface: $0.surface, normalizedPosition: $0.position) }
        pet.transform = Self.transform(for: plan.surface)
        coordinator.play(plan.action, on: pet, destination: destination, duration: duration)
        return duration + 0.08 * sampled.dwellMultiplier
    }

    private struct RoutePlan {
        let action: PetAction
        let surface: EdgeSurface
        let destination: (surface: EdgeSurface, position: CGFloat)?
    }

    private static func plan(step: Int, clockwise: Bool) -> RoutePlan {
        let firstWall: EdgeSurface = clockwise ? .rightWall : .leftWall
        let secondWall: EdgeSurface = clockwise ? .leftWall : .rightWall
        let firstEdge: CGFloat = clockwise ? 1 : 0
        let secondEdge: CGFloat = clockwise ? 0 : 1
        return switch step {
        case 0: RoutePlan(action: .floorMove, surface: .floor, destination: (.floor, firstEdge))
        case 1: RoutePlan(action: .turnBottomCorner, surface: firstWall, destination: (firstWall, 0))
        case 2: RoutePlan(action: firstWall == .leftWall ? .climbLeft : .climbRight, surface: firstWall, destination: (firstWall, 1))
        case 3: RoutePlan(action: .turnTopCorner, surface: .ceiling, destination: (.ceiling, firstEdge))
        case 4: RoutePlan(action: .ceilingHang, surface: .ceiling, destination: (.ceiling, firstEdge))
        case 5: RoutePlan(action: .ceilingMove, surface: .ceiling, destination: (.ceiling, secondEdge))
        case 6: RoutePlan(action: .turnTopCorner, surface: secondWall, destination: (secondWall, 1))
        case 7: RoutePlan(action: secondWall == .leftWall ? .climbLeft : .climbRight, surface: secondWall, destination: (secondWall, 0))
        default: RoutePlan(action: .turnBottomCorner, surface: .floor, destination: (.floor, secondEdge))
        }
    }

    private static func duration(for action: PetAction, geometry: EdgeGeometry, speedMultiplier: Double) -> TimeInterval {
        let speed = max(0.85, min(1.15, speedMultiplier))
        return switch action {
        case .floorMove: min(12, max(4, Double(geometry.rightX - geometry.leftX) / (80 * speed)))
        case .climbLeft, .climbRight, .ceilingMove: min(10, max(3, Double(geometry.ceilingY - geometry.floorY) / (80 * speed)))
        case .turnBottomCorner: 0.29
        case .turnTopCorner: 0.32
        case .ceilingHang: 2.5
        default: 1
        }
    }

    private func reserve(botId: BotID, from start: CGPoint, to end: CGPoint, minimumDistance: CGFloat) -> Bool {
        return occupancy.reserve(
            botId: botId,
            from: start,
            to: end,
            minimumDistance: minimumDistance
        )
    }

    static func reservationDistance(for sampled: SampledBehavior) -> CGFloat {
        CGFloat(sampled.socialDistance)
    }

    static func shouldRecoverRoute(after failedReservations: Int) -> Bool {
        failedReservations >= 4
    }

    private static func transform(for surface: EdgeSurface) -> CATransform3D {
        switch surface {
        case .floor, .station, .groupStation: CATransform3DIdentity
        case .leftWall: CATransform3DMakeRotation(-.pi / 2, 0, 0, 1)
        case .rightWall: CATransform3DMakeRotation(.pi / 2, 0, 0, 1)
        case .ceiling: CATransform3DMakeRotation(.pi, 0, 0, 1)
        }
    }

    private static func seed(for string: String) -> UInt64 {
        string.utf8.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1)) &* 1099511628211 }
    }
}
