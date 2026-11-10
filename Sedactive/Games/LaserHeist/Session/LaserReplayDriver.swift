import Foundation

/// Synthetic source composition and scripted actions. None of these controls enter CP1 or live input.
@MainActor
final class LaserReplayDriver {
    let script: LaserReplayScript
    let provider: ReplayBodyInput
    private var cursor = 0
    private var vaultCursor = 0
    private var actionCursor = 0
    private var contactFrame: UInt64 = 0
    private var contacts: LaserContactEntryTracker
    private var planner: LaserDiamondPlanner?
    private var vaultTargets: [UUID: LaserFullReplayPlan.VaultTarget] = [:]
    private var currentVault: UUID?

    init(script: LaserReplayScript) throws {
        self.script = script
        provider = try ReplayBodyInput(fixture: script.input)
        contacts = try LaserContactEntryTracker(lifetime: script.input.configuration.sessionGeneration, maximumContactAge: 0.5)
        planner = script.fullRound?.plannerAfterNormal
    }

    /// Compose outside the authoritative coordinator; App can inject its retained live provider instead.
    static func makeSession(script: LaserReplayScript) throws -> GameSessionCoordinator {
        let driver = try LaserReplayDriver(script: script)
        return GameSessionCoordinator(provider: driver.provider,
            inputConfiguration: script.input.configuration, configuration: script.configuration,
            encounters: script.encounters, replayDriver: driver)
    }

    func nextDeliveryTime(through time: Double) -> Double? {
        guard cursor < script.input.records.count,
              script.input.records[cursor].deliveredAt <= time else { return nil }
        return script.input.records[cursor].deliveredAt
    }

    func deliverNext() throws {
        try provider.advance(to: script.input.records[cursor].deliveredAt)
        cursor += 1
    }

    func nextActionTime(through time: Double) -> Double? {
        if let full = script.fullRound {
            return actionCursor < full.steps.count && full.steps[actionCursor].time <= time ? full.steps[actionCursor].time : nil
        }
        return vaultCursor < script.vaultActions.count && script.vaultActions[vaultCursor].time <= time
            ? script.vaultActions[vaultCursor].time : nil
    }

    func applyNextAction(clock: inout GameClock, game: inout LaserGame) throws {
        guard let full = script.fullRound else {
            let action = script.vaultActions[vaultCursor]
            try clock.advance(to: action.time)
            if let player = action.player, let button = action.button {
                try game.touchVault(id: script.vaultID, playerID: player, button: button, validity: .valid,
                    generation: script.input.configuration.sessionGeneration,
                    calibrationRevision: script.input.configuration.calibrations[player]!.revision,
                    at: clock.gameTime)
            } else { try game.openVault(id: script.vaultID, at: clock.gameTime) }
            vaultCursor += 1
            return
        }
        let step = full.steps[actionCursor]
        var nextClock = clock, nextGame = game, nextContacts = contacts, nextPlanner = planner
        var nextFrame = contactFrame
        var nextTargets = vaultTargets, nextVault = currentVault
        try nextClock.advance(to: step.time)
        try nextGame.advance(to: nextClock.gameTime)
        if nextGame.roundOutcome == nil {
            let generation = script.input.configuration.sessionGeneration
            let revisions = script.input.configuration.calibrations.mapValues(\.revision)
            func target(_ spawn: LaserDiamondSpawn) throws -> LaserContactTarget {
                guard let deadline = nextGame.diamonds[spawn.id]?.interactionDeadline else {
                    throw LaserDataError.invalidValue("missing replay diamond")
                }
                return try LaserContactTarget(id: spawn.id, eligiblePlayers: spawn.eligiblePlayers,
                                              activation: spawn.entry, deadline: deadline)
            }
            switch step.action {
            case .register(let id):
                guard let encounter = script.encounters.first(where: { $0.id == id }) else {
                    throw LaserDataError.invalidValue("missing replay encounter")
                }
                try nextGame.register(encounter)
            case .openVault(let id, let targets):
                try nextGame.openVault(id: id, at: nextClock.gameTime)
                nextVault = id
                nextTargets = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, $0) })
                try nextContacts.replaceTargets(targets.map {
                    try LaserContactTarget(id: $0.id, eligiblePlayers: [$0.player],
                        activation: nextClock.gameTime, deadline: nextClock.gameTime + script.configuration.vaultDuration)
                })
            case .normalDiamond(let spawn, let boundary):
                try nextGame.spawnNormalDiamonds([spawn], beforeVaultAt: boundary)
                try nextContacts.addTargets([target(spawn)])
            case .membership(let membership):
                nextFrame += 1
                let batch = try nextContacts.evaluate(lifetime: generation, frameID: nextFrame,
                    capturedAt: nextClock.gameTime, arrivedAt: nextClock.gameTime, locations: membership)
                if nextGame.roundPhase == .vault, let id = nextVault {
                    let commands = batch.compactMap { contact -> LaserVaultContact? in
                        guard let binding = nextTargets[contact.targetID], let revision = revisions[binding.player] else { return nil }
                        return LaserVaultContact(playerID: binding.player, button: binding.button, calibrationRevision: revision)
                    }
                    try nextGame.touchVaultBatch(id: id, contacts: commands, generation: generation, at: nextClock.gameTime)
                    if nextGame.roundPhase == .diamondTime {
                        let spawns = try nextPlanner!.bonusInitial(at: nextClock.gameTime, deadline: full.duration)
                        try nextGame.startDiamondTimeDiamonds(spawns)
                        try nextContacts.replaceTargets(spawns.map(target))
                    }
                } else {
                    let accepted = try nextGame.collectDiamonds(batch, generation: generation, calibrationRevisions: revisions,
                        capturedAt: nextClock.gameTime, arrivedAt: nextClock.gameTime)
                    nextContacts.removeTargets(Set(accepted.map(\.targetID)))
                }
            case .bonusOutside, .bonusCollect:
                let active = nextGame.activeDiamonds
                let isOutside: Bool = { if case .bonusOutside = step.action { true } else { false } }()
                var membership: [UUID: [LaserContactHand: LaserContactLocation]] = [:]
                var usedHands: Set<LaserContactHand> = []
                for spawn in active {
                    let eligible = LaserContactHand.ordered.filter { spawn.eligiblePlayers.contains($0.playerID) }
                    if isOutside {
                        membership[spawn.id] = Dictionary(uniqueKeysWithValues: eligible.map { ($0, .outside) })
                    } else if let hand = eligible.first(where: { !usedHands.contains($0) }) {
                        membership[spawn.id] = [hand: .inside]
                        usedHands.insert(hand)
                    }
                }
                nextFrame += 1
                let batch = try nextContacts.evaluate(lifetime: generation, frameID: nextFrame,
                    capturedAt: nextClock.gameTime, arrivedAt: nextClock.gameTime, locations: membership)
                if !batch.isEmpty {
                    let ids = Set(batch.map(\.targetID))
                    let spawns = try nextPlanner!.bonusReplacements(collected: active.filter { ids.contains($0.id) },
                        surviving: active.filter { !ids.contains($0.id) }, at: nextClock.gameTime, deadline: full.duration)
                    let accepted = try nextGame.collectDiamonds(batch, generation: generation, calibrationRevisions: revisions,
                        capturedAt: nextClock.gameTime, arrivedAt: nextClock.gameTime, replacements: spawns)
                    nextContacts.removeTargets(Set(accepted.map(\.targetID)))
                    try nextContacts.addTargets(spawns.map(target))
                }
            }
        }
        clock = nextClock; game = nextGame; contacts = nextContacts; planner = nextPlanner
        contactFrame = nextFrame; vaultTargets = nextTargets; currentVault = nextVault
        actionCursor += 1
    }

    func recordCoverage(through time: Double, game: inout LaserGame) throws {
        guard time >= script.trackedCoverage.lowerBound else { return }
        for player in PlayerID.allCases {
            try game.recordTrackedInterval(playerID: player, from: script.trackedCoverage.lowerBound,
                to: min(time, script.trackedCoverage.upperBound), observedAt: time)
        }
    }
}
