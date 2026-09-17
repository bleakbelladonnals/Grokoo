import CoreGraphics
import Foundation

@MainActor
final class PetBehaviorController {
    private let coordinator: AnimationCoordinator
    private var revisions: [BotID: UInt64] = [:]

    init(coordinator: AnimationCoordinator) {
        self.coordinator = coordinator
    }

    func apply(
        presence: PresenceState,
        to pet: PetLayer,
        stationPoint: CGPoint,
        groupPoint: CGPoint? = nil,
        revision: UInt64
    ) {
        guard revisions[pet.botId] != revision else { return }
        revisions[pet.botId] = revision
        pet.opacity = 1
        pet.faceLayer.setClosed(false)
        pet.showStateMarker(presence)
        switch presence {
        case .idle:
            coordinator.play(.idleBreathe, on: pet, phase: Double.random(in: 0...2))
        case .working, .thinking:
            let target = groupPoint ?? stationPoint
            let arrival: PetAction = groupPoint == nil ? .teleportToStation : .joinGroupStation
            coordinator.play(arrival, on: pet, destination: target) { [weak self, weak pet] in
                guard let self, let pet else { return }
                self.coordinator.play(groupPoint == nil ? .workAtStation : .workInGroup, on: pet, phase: Double.random(in: 0...1.5))
            }
        case .waiting, .blocked:
            coordinator.play(.teleportToStation, on: pet, destination: groupPoint ?? stationPoint) { [weak self, weak pet] in
                guard let self, let pet else { return }
                self.coordinator.play(.waitAtStation, on: pet)
            }
        case .done:
            coordinator.play(.celebrate, on: pet)
        case .offline:
            coordinator.play(.offlineSleep, on: pet)
        }
    }

    func cancelAll(pets: [PetLayer]) {
        revisions.removeAll()
        coordinator.cancelAll(pets: pets)
    }

    func cancel(pet: PetLayer) {
        revisions[pet.botId] = nil
        coordinator.cancel(pet: pet)
    }

    func leaveGroup(
        pet: PetLayer,
        destination: CGPoint,
        resultingPresence: PresenceState,
        revision: UInt64,
        completion: (() -> Void)? = nil
    ) {
        revisions[pet.botId] = revision
        coordinator.play(.leaveGroupStation, on: pet, destination: destination) { [weak self, weak pet] in
            guard let self, let pet else { return }
            self.revisions[pet.botId] = nil
            self.apply(presence: resultingPresence, to: pet, stationPoint: destination, revision: revision)
            completion?()
        }
    }
}
