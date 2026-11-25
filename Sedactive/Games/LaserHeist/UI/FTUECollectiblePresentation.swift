import RealityKit
import SwiftUI

/// Runs only in a collectible tutorial phase. The scene provides geometric contact,
/// and the isolated encounter returns a receipt only after the existing domain accepts it.
@MainActor final class FTUECollectiblePresentation {
    private var owner: (context: BodyInputContext, kind: FTUECollectible)?
    private var encounter: FTUECollectibleEncounter?
    private var diamonds: NormalDiamondPresentation?
    private var heart: HeartCollectible?
    private var travel = EligibleTravel()
    private var feedbackUntil: Double?
    private var lane: PlayerID?
    private var diamondLaneIndex = 0

    func update(scene: LaserScene, kind: FTUECollectible, configuration: LaserRoundConfiguration,
                input: BodyInputConfiguration, context: BodyInputContext, at now: Double,
                ready: Bool, contactsFrom players: Set<PlayerID>, heartArt: HeartArt?) -> FTUEPickupReceipt? {
        if owner?.context != context || owner?.kind != kind {
            clear()
            owner = (context, kind)
            #if DEBUG
            reportedPassages = 0
            #endif
        }
        guard ready, context.isActive, context.sessionGeneration == input.sessionGeneration,
              let avatars = scene.robotAvatars else { suspend(); return nil }
        // A Diamond receipt belongs to the player whose current body overlaps it.
        // Keep the existing Heart readiness rule.
        let readyPlayers = players.intersection(input.roster)
        let contactReady = kind == .diamond ? !readyPlayers.isEmpty : readyPlayers == Set(input.roster)
        let step = travel.tick(at: now)
        if step > 0 {
            scene.setTravelDistance(scene.travelOffset + scene.layout.travelSpeed * Float(step))
        }
        #if DEBUG
        defer {
            trace(scene: scene, kind: kind, generation: context.sessionGeneration, now: now,
                  step: step, contactReady: contactReady, hasHeartArt: heartArt != nil)
        }
        #endif
        let bodies = contactReady
            ? Dictionary(uniqueKeysWithValues: readyPlayers.map { ($0, avatars.diamondContactBody($0)) })
            : [:]
        let display = LaserReplayPresentation.diamondDisplay(scene: scene, layout: input.playerPlaneLayout)

        if encounter == nil {
            guard kind != .heart || heartArt != nil, !input.roster.isEmpty else { return nil }
            let player = input.roster[kind == .diamond ? diamondLaneIndex % input.roster.count : 0]
            let torso = avatars.diamondContactBody(player).first
            let laneX = scene.mapping.playerPosition(player).x
            let centerX = torso.map { ($0.start.x + $0.end.x) / 2 } ?? avatars.mascotWorldX(player) ?? laneX
            let centerY = torso.map { ($0.start.y + $0.end.y) / 2 } ?? RobotAvatarLayer.standingHeight * 0.5
            let scale = avatars.laserBandScale(for: player, mapping: scene.mapping) ?? 1
            let meters = scene.mapping.metersPerGameUnit * scale
            guard meters > 0, let position = try? LaserDiamondPosition(
                x: input.playerPlaneLayout.centerX(for: player) - Double((centerX - laneX) / meters),
                y: Double(centerY / meters)) else { return nil }
            guard let attempt = try? FTUECollectibleEncounter(kind: kind, configuration: configuration,
                context: context, position: position, roster: Set(input.roster)) else { return nil }
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
                let sphere = heart?.bodyContactSphere
                let path = diamonds?.bodyContactPath(id: spawn.id) ?? sphere.map {
                    AvatarDiamondContactCapsule(start: $0.center, end: $0.center, radius: $0.radius)
                }
                if time >= spawn.entry, time < spawn.exit {
                    if contactReady, let path, path.radius > 0 {
                        let overlaps = readyPlayers.filter { player in
                            bodies[player]?.contains { $0.overlaps(path) } == true
                        }
                        try current.collect(overlaps, context: context)
                        #if DEBUG
                        if Self.diagnostics {
                            contactWindow.eligible += 1
                            if overlaps.isEmpty { contactWindow.noOverlap += 1 }
                            contactWindow.target = path.end
                            contactWindow.radius = path.radius
                            for player in input.roster {
                                if let torso = bodies[player]?.first {
                                    contactWindow.eligibleByPlayer[player, default: 0] += 1
                                    contactWindow.torsoByPlayer[player] = (torso.start + torso.end) / 2
                                }
                            }
                            contactWindow.lastOverlap = overlaps
                        }
                        #endif
                    } else {
                        #if DEBUG
                        if Self.diagnostics {
                            if contactReady { contactWindow.noSphere += 1 }
                            else { contactWindow.noFreshPose += 1 }
                        }
                        #endif
                    }
                }
                #if DEBUG
                if current.receipt != nil || time >= spawn.exit {
                    reportPassage(current, context: context, time: time)
                }
                #endif
            } else if feedbackUntil == nil {
                AudioService.shared.play(kind == .heart ? .healthPickup : .diamondCollect)
                feedbackUntil = time + (kind == .heart ? HeartCollectible.effectLifetime : Diamond.effectLifetime)
            }
            encounter = current
            if let receipt = current.receipt {
                if let feedbackUntil, time >= feedbackUntil { clear(); return receipt }
            } else if time >= spawn.exit {
                // Give each Co-op player a reachable passage after a miss.
                if kind == .diamond { diamondLaneIndex = (diamondLaneIndex + 1) % input.roster.count }
                retirePassage()
            }
        } catch { retirePassage() }
        return nil
    }

    private struct EligibleTravel {
        private var previous: Double?

        mutating func tick(at now: Double) -> Double {
            guard now.isFinite else { suspend(); return 0 }
            defer { previous = now }
            guard let previous, now > previous else { return 0 }
            return min(now - previous, 0.25)
        }

        mutating func suspend() { previous = nil }
    }

    #if DEBUG
    private static let diagnostics = ProcessInfo.processInfo.arguments.contains("-ftueCollectibleDiagnostics")
    private var traceKey: String?
    private var traceStart: Double = 0
    private var traceDistance: Float = 0
    private var traceTicks = 0
    private var traceContactTicks = 0
    private var traceZeroSteps = 0
    private var traceReported = false

    private struct ContactWindow {
        var eligible = 0
        var noOverlap = 0
        var noSphere = 0
        var noFreshPose = 0
        var target: SIMD3<Float>?
        var radius: Float?
        var eligibleByPlayer: [PlayerID: Int] = [:]
        var torsoByPlayer: [PlayerID: SIMD3<Float>] = [:]
        var lastOverlap: Set<PlayerID> = []
    }
    private var contactWindow = ContactWindow()
    private var reportedPassages = 0

    private func reportPassage(_ encounter: FTUECollectibleEncounter, context: BodyInputContext, time: Double) {
        guard Self.diagnostics, reportedPassages < 3 else { return }
        reportedPassages += 1
        let window = contactWindow
        print("[FTUE Collectible Contact] generation=\(context.sessionGeneration) source=\(String(describing: context.wristContact?.sourceEpoch)) calibration=\(context.calibrationRevisions) target=\(encounter.spawn.id) time=\(time) accepted=\(encounter.receipt != nil) eligible=\(window.eligible) noOverlap=\(window.noOverlap) noSphere=\(window.noSphere) noFreshPose=\(window.noFreshPose) targetWorld=\(String(describing: window.target)) targetRadius=\(String(describing: window.radius)) lane=\(String(describing: lane)) eligibleByPlayer=\(window.eligibleByPlayer) torsoWorldByPlayer=\(window.torsoByPlayer) overlap=\(window.lastOverlap)")
    }

    private func trace(scene: LaserScene, kind: FTUECollectible, generation: UUID, now: Double, step: Double,
                       contactReady: Bool, hasHeartArt: Bool) {
        guard Self.diagnostics else { return }
        let key = "\(generation)/\(kind.rawValue)"
        if traceKey != key {
            traceKey = key; traceStart = now; traceDistance = scene.travelOffset
            traceTicks = 0; traceContactTicks = 0; traceZeroSteps = 0; traceReported = false
        }
        guard !traceReported else { return }
        traceTicks += 1
        if contactReady { traceContactTicks += 1 }
        if step == 0 { traceZeroSteps += 1 }
        guard now - traceStart >= 1 else { return }
        traceReported = true
        let entity = kind == .diamond ? scene.root.findEntity(named: "diamond") : heart?.root
        let point = entity?.position(relativeTo: nil)
        let projection = point.flatMap { scene.screenFraction(of: $0, aspect: 4.0 / 3.0) }
        let spawnStatus: String
        if encounter != nil { spawnStatus = entity == nil ? "admitted, no scene entity" : "attached to scene tree" }
        else if kind == .heart && !hasHeartArt { spawnStatus = "waiting for heart artwork" }
        else { spawnStatus = "no active passage (placement or domain admission)" }
        print("[FTUE Collectibles] \(key) firstEligible=\(traceStart) elapsed=\(now - traceStart) updates=\(traceTicks) freshContactUpdates=\(traceContactTicks) zeroTravelSteps=\(traceZeroSteps) travel=\(scene.travelOffset) travelDelta=\(scene.travelOffset - traceDistance) passage=\(encounter?.game.gameTime ?? 0) spawn=\(spawnStatus) id=\(String(describing: encounter?.spawn.id)) world=\(String(describing: point)) camera=\(scene.layout.cameraPosition) projectedX=\(String(describing: projection)) enabled=\(entity?.isEnabled == true) attached=\(entity?.parent != nil) collected=\(encounter?.receipt != nil)")
    }
    #endif

    func suspend() { travel.suspend() }

    func clear() {
        owner = nil
        diamondLaneIndex = 0
        suspend()
        retirePassage()
    }

    private func retirePassage() {
        #if DEBUG
        contactWindow = ContactWindow()
        #endif
        diamonds?.clear()
        heart?.retire()
        diamonds = nil; heart = nil; encounter = nil; lane = nil
        feedbackUntil = nil
    }
}
