import AppKit
import QuartzCore

@MainActor
final class AnimationCoordinator {
    private struct RunningAction {
        let token: UUID
        let action: PetAction
        let completion: DispatchWorkItem?
    }

    private var running: [BotID: RunningAction] = [:]
    private let manifest: AnimationManifest?

    init(manifest: AnimationManifest? = try? AnimationManifestLoader.loadBundled()) {
        self.manifest = manifest
    }

    @discardableResult
    func play(
        _ action: PetAction,
        on pet: PetLayer,
        destination: CGPoint? = nil,
        duration requestedDuration: TimeInterval? = nil,
        phase: Double = 0,
        completion: (() -> Void)? = nil
    ) -> UUID {
        let interruptedPosition = pet.presentation()?.position ?? pet.position
        let interruptedTransform = pet.presentation()?.transform ?? pet.transform
        cancel(botId: pet.botId)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pet.position = interruptedPosition
        pet.transform = interruptedTransform
        CATransaction.commit()
        let token = UUID()
        let duration = requestedDuration ?? defaultDuration(for: action)
        apply(action, to: pet, destination: destination, duration: duration, phase: phase)
        let workItem: DispatchWorkItem?
        if isLooping(action) {
            workItem = nil
        } else {
            var item: DispatchWorkItem?
            item = DispatchWorkItem { [weak self, weak pet] in
                Task { @MainActor in
                    guard let self, let pet, let current = self.running[pet.botId], current.token == token else { return }
                    self.running.removeValue(forKey: pet.botId)
                    completion?()
                }
            }
            workItem = item
            if let item { DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: item) }
        }
        running[pet.botId] = RunningAction(token: token, action: action, completion: workItem)
        return token
    }

    func cancel(botId: BotID) {
        running.removeValue(forKey: botId)?.completion?.cancel()
    }

    func cancel(pet: PetLayer) {
        cancel(botId: pet.botId)
        freezePresentationState(of: pet)
        removeAnimations(from: pet)
    }

    func cancelAll(pets: [PetLayer]) {
        running.values.forEach { $0.completion?.cancel() }
        running.removeAll()
        pets.forEach {
            freezePresentationState(of: $0)
            removeAnimations(from: $0)
        }
    }

    func isCurrent(token: UUID, for botId: BotID) -> Bool { running[botId]?.token == token }
    func currentAction(for botId: BotID) -> PetAction? { running[botId]?.action }

    private func removeAnimations(from pet: PetLayer) {
        pet.removeAllAnimations()
        pet.bodyShapeLayer.removeAllAnimations()
        pet.faceLayer.removeAllAnimations()
        pet.stateDecorationLayer.removeAllAnimations()
        pet.mbtiDecorationLayer.removeAllAnimations()
    }

    private func freezePresentationState(of pet: PetLayer) {
        guard let presentation = pet.presentation() else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pet.position = presentation.position
        pet.transform = presentation.transform
        pet.opacity = presentation.opacity
        CATransaction.commit()
    }

    private func apply(_ action: PetAction, to pet: PetLayer, destination: CGPoint?, duration: TimeInterval, phase: Double) {
        pet.removeAllAnimations()
        pet.bodyShapeLayer.removeAllAnimations()
        pet.faceLayer.removeAllAnimations()
        pet.stateDecorationLayer.removeAllAnimations()
        pet.mbtiDecorationLayer.removeAllAnimations()
        switch action {
        case .idleBreathe:
            breathe(pet, duration: duration, amplitude: 0.02, phase: phase)
            pet.faceLayer.animateIdleLiveliness(duration: duration, phase: phase)
        case .blink:
            pet.faceLayer.blink(duration: duration)
        case .floorMove, .climbLeft, .climbRight, .ceilingMove:
            let angle: CGFloat = switch action {
            case .climbLeft: -.pi / 2
            case .climbRight: .pi / 2
            case .ceilingMove: .pi
            default: 0
            }
            pet.setAffineTransform(CGAffineTransform(rotationAngle: angle))
            translate(pet, to: destination ?? pet.position, duration: duration)
            let pulse = CABasicAnimation(keyPath: "transform.scale.x")
            pulse.fromValue = 0.98; pulse.toValue = 1.02; pulse.duration = 0.42; pulse.autoreverses = true; pulse.repeatCount = .infinity
            pet.bodyShapeLayer.add(pulse, forKey: "movementPulse")
        case .ceilingHang:
            pet.setAffineTransform(CGAffineTransform(rotationAngle: .pi))
            let sway = CABasicAnimation(keyPath: "transform.rotation.z")
            sway.fromValue = CGFloat.pi - CGFloat.pi / 90; sway.toValue = CGFloat.pi + CGFloat.pi / 90; sway.duration = duration / 2; sway.autoreverses = true; sway.repeatCount = .infinity
            pet.add(sway, forKey: "hangSway")
        case .turnBottomCorner, .turnTopCorner:
            let group = CAAnimationGroup()
            let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
            rotation.byValue = action == .turnBottomCorner ? CGFloat.pi / 2 : -CGFloat.pi / 2
            let squeeze = CAKeyframeAnimation(keyPath: "transform.scale")
            squeeze.values = [1, 0.82, 1]
            squeeze.keyTimes = [0, 0.45, 1]
            group.animations = [rotation, squeeze]; group.duration = duration; group.isRemovedOnCompletion = true
            pet.add(group, forKey: action.rawValue)
        case .teleportToStation, .joinGroupStation, .leaveGroupStation:
            pet.setAffineTransform(.identity)
            teleport(pet, to: destination ?? pet.position, duration: duration)
        case .workAtStation, .workInGroup:
            pet.setAffineTransform(.identity)
            breathe(pet, duration: duration, amplitude: 0.012, phase: phase)
            let lean = CABasicAnimation(keyPath: "transform.rotation.z")
            lean.fromValue = -0.025; lean.toValue = 0.025; lean.duration = duration; lean.autoreverses = true; lean.repeatCount = .infinity
            pet.bodyShapeLayer.add(lean, forKey: "workLean")
            let groupGaze: CGFloat = action == .workInGroup ? (phase.truncatingRemainder(dividingBy: 2) < 1 ? 0.5 : -0.5) : 0
            pet.faceLayer.setGaze(x: groupGaze, y: -0.8)
            pet.faceLayer.animateWorkBlink(duration: duration, phase: phase)
        case .waitAtStation:
            breathe(pet, duration: duration, amplitude: 0.014, phase: phase)
            let nudge = CABasicAnimation(keyPath: "transform.translation.y")
            nudge.fromValue = 0; nudge.toValue = 1.5; nudge.duration = duration / 2; nudge.autoreverses = true; nudge.repeatCount = .infinity
            pet.add(nudge, forKey: "waitNudge")
        case .celebrate:
            let bounce = CAKeyframeAnimation(keyPath: "transform.translation.y")
            bounce.values = [0, 6, 0, 5, 0]
            bounce.keyTimes = [0, 0.18, 0.36, 0.54, 0.72]
            bounce.duration = duration
            bounce.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            pet.add(bounce, forKey: "doubleBounce")
        case .offlineSleep:
            breathe(pet, duration: duration, amplitude: 0.008, phase: phase)
            pet.opacity = 0.55
            pet.faceLayer.setClosed(true)
        }
    }

    private func breathe(_ pet: PetLayer, duration: TimeInterval, amplitude: CGFloat, phase: Double) {
        let beginTime = CACurrentMediaTime() + phase.truncatingRemainder(dividingBy: max(0.1, duration))
        let horizontal = CAKeyframeAnimation(keyPath: "transform.scale.x")
        horizontal.values = [1, 1 - amplitude * 0.65, 1]
        horizontal.keyTimes = [0, 0.5, 1]
        let vertical = CAKeyframeAnimation(keyPath: "transform.scale.y")
        vertical.values = [1, 1 + amplitude, 1]
        vertical.keyTimes = horizontal.keyTimes
        let breathe = CAAnimationGroup()
        breathe.animations = [horizontal, vertical]
        breathe.duration = duration
        breathe.repeatCount = .infinity
        breathe.beginTime = beginTime
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        pet.bodyShapeLayer.add(breathe, forKey: "breathe")
        if !pet.mbtiDecorationLayer.isHidden {
            let decorationBreathe = CAKeyframeAnimation(keyPath: "transform.scale")
            decorationBreathe.values = [1, 1 + amplitude * 0.45, 1]
            decorationBreathe.keyTimes = horizontal.keyTimes
            decorationBreathe.duration = duration
            decorationBreathe.repeatCount = .infinity
            decorationBreathe.beginTime = beginTime
            decorationBreathe.timingFunction = breathe.timingFunction
            pet.mbtiDecorationLayer.add(decorationBreathe, forKey: "decorationBreathe")
        }
    }

    private func translate(_ pet: PetLayer, to destination: CGPoint, duration: TimeInterval) {
        let origin = pet.presentation()?.position ?? pet.position
        pet.position = destination
        let movement = CABasicAnimation(keyPath: "position")
        movement.fromValue = NSValue(point: origin)
        movement.toValue = NSValue(point: destination)
        movement.duration = duration
        movement.timingFunction = CAMediaTimingFunction(name: .linear)
        pet.add(movement, forKey: "edgeTranslation")
    }

    private func teleport(_ pet: PetLayer, to destination: CGPoint, duration: TimeInterval) {
        let origin = pet.presentation()?.position ?? pet.position
        let fadeOut = CAKeyframeAnimation(keyPath: "opacity")
        fadeOut.values = [1, 0, 0, 1]
        fadeOut.keyTimes = [0, 0.42, 0.58, 1]
        let squeeze = CAKeyframeAnimation(keyPath: "transform.scale")
        squeeze.values = [1, 0.75, 0.75, 1]
        squeeze.keyTimes = fadeOut.keyTimes
        let movement = CAKeyframeAnimation(keyPath: "position")
        movement.values = [NSValue(point: origin), NSValue(point: origin), NSValue(point: destination), NSValue(point: destination)]
        movement.keyTimes = fadeOut.keyTimes
        let group = CAAnimationGroup()
        group.animations = [fadeOut, squeeze, movement]
        group.duration = duration
        pet.position = destination
        pet.add(group, forKey: "teleport")
    }

    private func defaultDuration(for action: PetAction) -> TimeInterval {
        if let range = manifest?[action]?.durationRange {
            return (range.lowerBound + range.upperBound) / 2
        }
        return switch action {
        case .idleBreathe: 3.0
        case .blink: 0.14
        case .floorMove: 8
        case .climbLeft, .climbRight, .ceilingMove: 6.5
        case .ceilingHang: 2.5
        case .turnBottomCorner: 0.29
        case .turnTopCorner: 0.32
        case .teleportToStation: 0.24
        case .workAtStation, .workInGroup: 2
        case .waitAtStation: 1.5
        case .celebrate: 4
        case .offlineSleep: 3.3
        case .joinGroupStation: 0.28
        case .leaveGroupStation: 0.24
        }
    }

    private func isLooping(_ action: PetAction) -> Bool {
        manifest?[action]?.loop
            ?? [.idleBreathe, .workAtStation, .waitAtStation, .offlineSleep, .workInGroup].contains(action)
    }
}
