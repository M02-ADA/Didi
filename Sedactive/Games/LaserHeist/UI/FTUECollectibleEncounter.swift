import Foundation

nonisolated enum FTUECollectible: String, Sendable {
    case diamond, heart
}

struct FTUEPickupReceipt {
    let generation: UUID
    let kind: FTUECollectible
    fileprivate init(generation: UUID, kind: FTUECollectible) {
        self.generation = generation
        self.kind = kind
    }
}

/// A single tutorial passage, using the ordinary domain admission and pickup rules
/// on a disposable game with no round director, gates, or live score/health projection.
struct FTUECollectibleEncounter {
    let kind: FTUECollectible
    let context: BodyInputContext
    let spawn: LaserDiamondSpawn
    private(set) var game: LaserGame

    init(kind: FTUECollectible, configuration: LaserRoundConfiguration, context: BodyInputContext,
         position: LaserDiamondPosition, roster: Set<PlayerID>) throws {
        self.kind = kind
        self.context = context
        spawn = try .init(id: UUID(), position: position, eligiblePlayers: roster,
                          spawnedAt: 0, entry: 0.8, exit: 3.2)
        // Zero points enables the same Diamond admission in this isolated passage
        // without enabling rewards or touching the live round's configuration.
        let training = try LaserRoundConfiguration(evidenceTiming: configuration.evidenceTiming,
            clearanceMargin: configuration.clearanceMargin, diamondPoints: 0)
        game = try .init(configuration: training, context: context, historyCapacityPerPlayer: 1)
        switch kind {
        case .diamond: try game.spawnNormalDiamonds([spawn], beforeVaultAt: spawn.exit)
        case .heart: try game.spawnHeart(spawn, beforeVaultAt: spawn.exit)
        }
    }

    var receipt: FTUEPickupReceipt? {
        let collected: Bool
        switch kind {
        case .diamond:
            if case .collectedByBody? = game.diamonds[spawn.id]?.outcome { collected = true }
            else { collected = false }
        case .heart: collected = game.lastHeartPickup?.id == spawn.id
        }
        return collected ? .init(generation: context.sessionGeneration, kind: kind) : nil
    }

    mutating func advance(to time: Double) throws { try game.advance(to: time) }

    mutating func collect(_ players: Set<PlayerID>, context current: BodyInputContext) throws {
        guard current == context, !players.isEmpty, receipt == nil else { return }
        switch kind {
        case .diamond:
            try game.collectDiamonds([], generation: current.sessionGeneration,
                calibrationRevisions: current.calibrationRevisions, capturedAt: game.gameTime,
                arrivedAt: game.gameTime, bodyContacts: [spawn.id: players])
        case .heart: game.collectHeart(id: spawn.id, players: players)
        }
    }
}
