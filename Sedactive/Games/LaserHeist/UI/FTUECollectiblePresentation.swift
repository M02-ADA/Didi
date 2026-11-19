import RealityKit
import SwiftUI

/// Runs only in a collectible tutorial phase. The scene provides geometric contact,
/// and the isolated encounter returns a receipt only after the existing domain accepts it.
@MainActor final class FTUECollectiblePresentation {
    private var encounter: FTUECollectibleEncounter?
    private var diamonds: NormalDiamondPresentation?
    private var heart: HeartCollectible?
    private var previous: Double?
    private var feedbackUntil: Double?
    private var lane: PlayerID?

    func update(scene: LaserScene, kind: FTUECollectible, configuration: LaserRoundConfiguration,
                input: BodyInputConfiguration, context: BodyInputContext, at now: Double,
                contactsFrom players: Set<PlayerID>, heartArt: HeartArt?) -> FTUEPickupReceipt? {
        if encounter?.context != context || encounter?.kind != kind { clear() }
        guard players == Set(input.roster), let avatars = scene.robotAvatars else { suspend(); return nil }
        let dt = previous.map { now - $0 } ?? 0
        previous = now
        let step = dt > 0 && dt <= 0.25 ? dt : 0
        let bodies = Dictionary(uniqueKeysWithValues: input.roster.map { ($0, avatars.diamondContactBody($0)) })
        let display = LaserReplayPresentation.diamondDisplay(scene: scene, layout: input.playerPlaneLayout)

        if encounter == nil {
            guard kind != .heart || heartArt != nil,
                  let player = input.roster.first, let torso = bodies[player]?.first else { return nil }
            let center = (torso.start + torso.end) / 2
            let scale = avatars.laserBandScale(for: player, mapping: scene.mapping) ?? 1
            let meters = scene.mapping.metersPerGameUnit * scale
            guard meters > 0, let position = try? LaserDiamondPosition(
                x: input.playerPlaneLayout.centerX(for: player)
                    - Double((center.x - scene.mapping.playerPosition(player).x) / meters),
                y: Double(center.y / meters)) else { return nil }
            guard let attempt = try? FTUECollectibleEncounter(kind: kind, configuration: configuration,
                context: context, position: position, roster: players) else { return nil }
            encounter = attempt
            lane = player
            if kind == .diamond { diamonds = NormalDiamondPresentation(scene: scene) }
            else {
                let entity = heartArt?.makeHeart(generation: context.sessionGeneration, target: attempt.spawn.id)
                if let entity { scene.root.addChild(entity.root); entity.showIdle() }
                heart = entity
            }
        }
        guard var current = encounter, let lane else { return nil }
        let time = current.game.gameTime + step
        do {
            try current.advance(to: time)
            scene.setTravelDistance(scene.travelOffset + scene.layout.travelSpeed * Float(step))
            let spawn = current.spawn
            let placed = display(lane, spawn.position)
            if let diamonds {
                let outcome: NormalDiamond.Outcome = current.receipt != nil ? .collected : time >= spawn.exit ? .missed : .pending
                diamonds.source = { [.init(id: spawn.id, lane: lane, offsetX: placed.offsetX,
                    heightAboveFloor: placed.height, spawnedAt: spawn.spawnedAt, entry: spawn.entry,
                    exit: spawn.exit, outcome: outcome)] }
                diamonds.update(state: .init(sessionGeneration: context.sessionGeneration, phase: .activity,
                    gameTime: time, activityProgress: 0, teamHealth: current.game.teamHealth,
                    teamScore: current.game.teamScore, encounters: []))
            }
            if let heart {
                if current.receipt == nil {
                    var position = scene.mapping.playerPosition(lane, heightAboveFloor: placed.height)
                    position.x += placed.offsetX * scene.mapping.metersPerGameUnit
                    position.z -= scene.layout.travelSpeed * Float((spawn.entry + spawn.exit) / 2 - time)
                    heart.root.position = position
                } else {
                    _ = heart.collect(generation: context.sessionGeneration, target: spawn.id, now: time)
                    heart.update(now: time, generation: context.sessionGeneration)
                }
            }
            if current.receipt == nil {
                let sphere = diamonds?.bodyContactSphere(id: spawn.id) ?? heart?.bodyContactSphere
                if let sphere, sphere.radius > 0, time >= spawn.entry, time < spawn.exit {
                    let overlaps = players.filter { player in
                        bodies[player]?.contains { $0.overlaps(center: sphere.center, radius: sphere.radius) } == true
                    }
                    try current.collect(overlaps, context: context)
                }
            } else if feedbackUntil == nil {
                AudioService.shared.play(kind == .heart ? .healthPickup : .diamondCollect)
                feedbackUntil = time + (kind == .heart ? HeartCollectible.effectLifetime : Diamond.effectLifetime)
            }
            encounter = current
            if let receipt = current.receipt {
                if let feedbackUntil, time >= feedbackUntil { clear(); return receipt }
            } else if time >= spawn.exit {
                // A miss creates another real passage, never a successful pickup.
                clear()
            }
        } catch { clear() }
        return nil
    }

    func suspend() { previous = nil }

    func clear() {
        diamonds?.clear()
        heart?.retire()
        diamonds = nil; heart = nil; encounter = nil; lane = nil
        feedbackUntil = nil; previous = nil
    }
}
