import CoreGraphics
import Foundation

enum WorkspaceMembership: Equatable, Sendable {
    case solo
    case group(GroupID)
}

struct WorkspaceMember: Equatable, Sendable, Identifiable {
    let botId: BotID
    let membership: WorkspaceMembership
    var id: BotID { botId }
}

enum WorkspaceFacing: Equatable, Sendable { case forward, inwardLeft, inwardRight }

struct WorkspacePlacement: Equatable, Sendable {
    let center: CGPoint
    let surfaceFrame: CGRect
    let contentBounds: CGRect
    let petFrames: [BotID: CGRect]
    let facing: [BotID: WorkspaceFacing]
    let interactiveRegions: [CGRect]

    static let empty = WorkspacePlacement(
        center: .zero,
        surfaceFrame: .zero,
        contentBounds: .zero,
        petFrames: [:],
        facing: [:],
        interactiveRegions: []
    )
}

enum DockEdge: String, Codable, CaseIterable, Sendable { case bottom, left, right }

struct ScreenTopology: Equatable, Sendable {
    let screenFrame: CGRect
    let safeFrame: CGRect
    let dockEdge: DockEdge
    /// Stable geometry captured from Dock size/position, not transient auto-hide visibility.
    let dockReferenceFrame: CGRect?
    let scale: CGFloat
    let mainScreenID: String
}

struct WorkspaceAnchorResolver: Sendable {
    static let dockGap: CGFloat = 14

    func surfaceOrigin(topology: ScreenTopology, surfaceSize: CGSize) -> CGPoint {
        let x = topology.screenFrame.midX - surfaceSize.width / 2
        let y: CGFloat
        switch topology.dockEdge {
        case .bottom:
            y = (topology.dockReferenceFrame?.maxY ?? topology.safeFrame.minY) + Self.dockGap
        case .left, .right:
            y = topology.safeFrame.minY + Self.dockGap
        }
        return CGPoint(x: x, y: y)
    }
}

struct WorkspaceLayoutEngine: Sendable {
    static let bodySize: CGFloat = 42
    static let surfaceHeight: CGFloat = 18
    static let minimumSurfaceWidth: CGFloat = 88
    static let maximumSurfaceWidth: CGFloat = 320
    static let surfacePadding: CGFloat = 8
    static let botSurfaceOverlap: CGFloat = 7
    static let soloGap: CGFloat = 8
    static let twoPersonGap: CGFloat = 8
    static let groupGap: CGFloat = 4
    static let blockGap: CGFloat = 32

    func placement(members supplied: [WorkspaceMember], topology: ScreenTopology) -> WorkspacePlacement {
        let members = Array(supplied.prefix(6))
        guard !members.isEmpty else { return .empty }

        let blocks = makeBlocks(members)
        let blockWidths = blocks.map(blockWidth)
        let rawWidth = zip(blockWidths, blockWidths.indices).reduce(CGFloat.zero) { partial, pair in
            partial + pair.0 + (pair.1 == 0 ? 0 : Self.blockGap)
        }
        let contentWidth = min(rawWidth, Self.maximumSurfaceWidth)
        let surfaceWidth = min(max(contentWidth + Self.surfacePadding * 2, Self.minimumSurfaceWidth), Self.maximumSurfaceWidth)
        let surfaceSize = CGSize(width: surfaceWidth, height: Self.surfaceHeight)
        let surfaceOrigin = WorkspaceAnchorResolver().surfaceOrigin(topology: topology, surfaceSize: surfaceSize)
        let surface = CGRect(origin: surfaceOrigin, size: surfaceSize)
        let contentMinX = surface.midX - rawWidth / 2
        let bodyY = surface.maxY - Self.botSurfaceOverlap

        var petFrames: [BotID: CGRect] = [:]
        var facing: [BotID: WorkspaceFacing] = [:]
        var cursor = contentMinX
        for (blockIndex, block) in blocks.enumerated() {
            if blockIndex > 0 { cursor += Self.blockGap }
            let gap = gap(for: block)
            for (index, member) in block.enumerated() {
                let lift = arcLift(index: index, count: block.count)
                petFrames[member.botId] = CGRect(x: cursor, y: bodyY + lift, width: Self.bodySize, height: Self.bodySize)
                facing[member.botId] = block.count == 1 ? .forward : (index < block.count / 2 ? .inwardRight : .inwardLeft)
                cursor += Self.bodySize
                if index < block.count - 1 { cursor += gap }
            }
        }

        let bounds = petFrames.values.reduce(CGRect.null) { $0.union($1) }
        return WorkspacePlacement(
            center: CGPoint(x: surface.midX, y: surface.midY),
            surfaceFrame: surface,
            contentBounds: bounds,
            petFrames: petFrames,
            facing: facing,
            interactiveRegions: petFrames.values.sorted { $0.minX < $1.minX }
        )
    }

    private func makeBlocks(_ members: [WorkspaceMember]) -> [[WorkspaceMember]] {
        var result: [[WorkspaceMember]] = []
        var groupIndex: [GroupID: Int] = [:]
        var soloBlock: [WorkspaceMember] = []
        for member in members {
            switch member.membership {
            case .solo:
                soloBlock.append(member)
            case .group(let id):
                if !soloBlock.isEmpty { result.append(soloBlock); soloBlock.removeAll() }
                if let index = groupIndex[id] {
                    result[index].append(member)
                } else {
                    groupIndex[id] = result.count
                    result.append([member])
                }
            }
        }
        if !soloBlock.isEmpty { result.append(soloBlock) }
        return result
    }

    private func gap(for block: [WorkspaceMember]) -> CGFloat {
        guard let first = block.first else { return 0 }
        if case .solo = first.membership { return Self.soloGap }
        return block.count == 2 ? Self.twoPersonGap : Self.groupGap
    }

    private func blockWidth(_ block: [WorkspaceMember]) -> CGFloat {
        guard !block.isEmpty else { return 0 }
        return CGFloat(block.count) * Self.bodySize + CGFloat(block.count - 1) * gap(for: block)
    }

    private func arcLift(index: Int, count: Int) -> CGFloat {
        guard count >= 3 else { return 0 }
        if count == 3 { return index == 1 ? 12 : 0 }
        if count == 4 { return (index == 1 || index == 2) ? 16 : 0 }
        let center = CGFloat(count - 1) / 2
        let normalized = abs(CGFloat(index) - center) / center
        return (1 - normalized) * 16
    }
}
