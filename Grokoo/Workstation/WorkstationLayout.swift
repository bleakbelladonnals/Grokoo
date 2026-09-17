import CoreGraphics
import Foundation

enum WorkstationRegion: String, Codable, CaseIterable, Identifiable, Sendable {
    case left
    case center
    case right
    var id: String { rawValue }
}

struct WorkstationSlot: Equatable, Sendable {
    let botId: BotID
    let petFrame: CGRect
    let baseFrame: CGRect
}

struct WorkstationLayout: Sendable {
    var slotWidth: CGFloat = 42
    var baseSize = CGSize(width: 36, height: 8)
    /// Keeps permanent stations clear of the two corner-transition zones.
    var horizontalMargin: CGFloat = 64

    func slots(
        visibleFrame: CGRect,
        region: WorkstationRegion,
        orderedBotIds: [BotID]
    ) -> [WorkstationSlot] {
        let ids = Array(orderedBotIds.prefix(6))
        guard !ids.isEmpty else { return [] }
        let available = max(0, visibleFrame.width - horizontalMargin * 2)
        let spacing = min(max(40, available / CGFloat(ids.count)), min(44, slotWidth))
        let width = spacing * CGFloat(ids.count)
        let originX: CGFloat
        switch region {
        case .left: originX = visibleFrame.minX + horizontalMargin
        case .center: originX = visibleFrame.midX - width / 2
        case .right: originX = visibleFrame.maxX - horizontalMargin - width
        }
        return ids.enumerated().map { index, id in
            let slotCenter = originX + spacing * (CGFloat(index) + 0.5)
            let base = CGRect(
                x: slotCenter - baseSize.width / 2,
                y: visibleFrame.minY + 1,
                width: baseSize.width,
                height: baseSize.height
            )
            let pet = CGRect(
                x: slotCenter - PetLayer.decoratedSize.width / 2,
                y: base.maxY,
                width: PetLayer.decoratedSize.width,
                height: PetLayer.decoratedSize.height
            )
            return WorkstationSlot(botId: id, petFrame: pet, baseFrame: base)
        }
    }
}
