import Foundation

/// Where a player's wrist must enter to press one vault button: a circle in that
/// player's upright, UNMIRRORED player plane (game units, Y up from the floor).
nonisolated struct LaserVaultZone: Equatable, Sendable {
    let targetID: UUID
    let playerID: PlayerID
    let button: LaserVaultButton
    let position: LaserDiamondPosition
    let radius: Double
}

/// Live interaction geometry, scaled to each player's ACCEPTED standing height so the same
/// reach works for a child and an adult. Owner-approved for the first device rounds
/// (11 November 2026); physical comfort/reach acceptance is still pending device testing.
///
/// - Diamonds: four per player beside the body, at chest and shoulder height, out of the
///   resting-hand position so idle hands do not collect them.
/// - Vault buttons: three on the player's OUTER side (toward their own corridor wall): high,
///   level and low reaches of one arm. Live rounds draw each button exactly on its zone, with
///   the mascot's own mirror and height scale (`GameWorldMapping.mascotPoint`), and the player's
///   wrists as reach cursors through the same mapping: cursor on a button = wrist in its zone.
nonisolated enum LaserLiveRoundGeometryV1 {
    static let version = "LaserLiveRoundGeometryV1"
    /// Diamond placements: (sideways, height) as shares of standing height.
    static let diamondShares: [(x: Double, y: Double)] = [(-0.2, 0.6), (0.2, 0.6), (-0.2, 0.85), (0.2, 0.85)]
    /// DEBUG solo practice: the diamond planner needs at least five places, so one player gets two more.
    static let soloExtraDiamondShares: [(x: Double, y: Double)] = [(-0.3, 0.72), (0.3, 0.72)]
    static let diamondRadiusShare = 0.08
    /// Vault buttons, outward from the lane centre: (outward, height) shares of each player's
    /// own standing height, so shorter players get lower, closer buttons. One vertical stack
    /// beside the player at body-relative reaching heights (owner request 11 November 2026):
    /// HIGH at head level (0.95 h), MIDDLE at chest (0.70 h), LOW at the upper thigh (0.45 h,
    /// above the knee ~0.28 h, below the hip ~0.53 h). Neighbours are 0.25 h apart (the gap
    /// between buttons doubled; more than two radii: no overlap). HIGH and MIDDLE are about 83 %
    /// of an arm (0.44 h) from the outer shoulder standing upright; LOW asks for a downward reach
    /// with a slight knee bend and lean (0.1 h and 0.05 h: 90 % of an arm), never a deep squat.
    /// The column (0.47 h out) stays clear of the leaning mascot's head, and a resting hand
    /// (~0.16 h out, ~0.44 h up) is outside every zone even with the hips 0.1 h toward the wall.
    static let vaultShares: [LaserVaultButton: (out: Double, y: Double)] = [
        .top: (0.47, 0.95), .middle: (0.47, 0.70), .bottom: (0.47, 0.45)]
    static let vaultRadiusShare = 0.105
    /// The human reference these shares assume (anthropometric averages): the shoulder joint
    /// (outward, height) and the shoulder→wrist arm length, as shares of standing height.
    static let humanShoulderShare: (out: Double, y: Double) = (0.13, 0.82)
    static let humanArmShare = 0.44

    /// The standing height a vault zone was sized from (its radius is `vaultRadiusShare` of it).
    static func standingHeight(fromVaultRadius radius: Double) -> Double { radius / vaultRadiusShare }

    /// Standing height in game units from the accepted reference (crown above the floor).
    static func standingHeight(_ calibration: PlayerCalibration, layout: PlayerPlaneLayout) -> Double {
        calibration.mapping.gameY(imageY: calibration.standingCrownImageY, layout: layout)
    }

    /// The player's outer side in the unmirrored plane. Display mirrors each lane about its
    /// centre (`GameWorldMapping`), so P1's outer (left) wall is plane +X and P2's is −X.
    static func outward(_ player: PlayerID) -> Double { player == .player1 ? 1 : -1 }
}

/// The live round's encounter director: the complete replay's five-minute wave script,
/// diamond planner and one-vault-per-minute rule, run on the ONE live GameClock.
///
/// It decides only WHEN planned work becomes due. Players' actions, evidence, verdicts,
/// contacts, health, score and phase stay with `LaserGame` and the live CP1 stream; nothing
/// here creates evidence or a verdict. Each minute's plan is rebased onto the game time at
/// which that minute actually starts, because a live vault lasts as long as the players take
/// (up to its 5 s limit) and a pause shifts the rest of the minute.
nonisolated struct LaserLiveRoundDirector: Sendable {
    enum Action: Equatable, Sendable {
        /// Register at its (rebased) warning time.
        case register(LaserEncounter)
        /// Spawn exactly at `spawn.spawnedAt`, before the minute's vault.
        case normalDiamond(LaserDiamondSpawn, boundary: Double)
        case openVault(UUID, zones: [LaserVaultZone])
    }

    let configuration: LaserRoundConfiguration
    let layout: PlayerPlaneLayout
    /// Seconds of activity per vault segment: 60 in a real round.
    let segmentLength: Double
    /// Every encounter of the whole round at its base (replay-script) times, for display sizing.
    let baseEncounters: [LaserEncounter]
    let diamondRadius: Double
    /// Both players, or P1 alone in a DEBUG Solo Test practice (P1's lasers, diamonds and vault
    /// buttons only; `LaserGame.soloPracticePlayer` opens a solo vault on P1's three presses).
    let roster: [PlayerID]
    var isSolo: Bool { roster.count == 1 }
    private let minutes: [[LaserEncounter]]
    private let vaultZones: [PlayerID: [LaserVaultButton: (position: LaserDiamondPosition, radius: Double)]]
    private(set) var planner: LaserDiamondPlanner
    private(set) var minute = 0
    /// Game time at which the current minute began, or nil before it begins.
    private(set) var minuteStart: Double?
    private var pending: [(time: Double, action: Action)] = []
    private var vaultOpened = false
    private var attemptSerial: UInt64 = 0

    /// The current minute's vault time, once the minute has begun.
    var vaultBoundary: Double? { minuteStart.map { $0 + segmentLength } }
    var isFinishedPlanning: Bool { minute >= minutes.count }

    /// - Parameters:
    ///   - calibrations: the producer's ACCEPTED references (both players), never defaults.
    ///   - segmentLength: 60 for the real round. DEBUG may pass less to play the first
    ///     seconds of every minute from the SAME script (`liveShortRound`).
    init(calibrations: [PlayerID: PlayerCalibration], layout: PlayerPlaneLayout,
         configuration: LaserRoundConfiguration, seed: UInt64, segmentLength: Double = 60,
         roster: [PlayerID] = PlayerID.allCases) throws {
        try layout.validate()
        #if DEBUG
        try requireLaserValue(roster == PlayerID.allCases || roster == [.player1], "co-op or solo P1 round")
        #else
        try requireLaserValue(roster == PlayerID.allCases, "co-op round")
        #endif
        self.roster = roster
        try requireLaserValue(Set(calibrations.keys) == Set(roster)
            && segmentLength.isFinite && segmentLength >= 10 && segmentLength <= 60, "live director inputs")
        let wave = try LaserWaveDirector().schedule(script: LaserWaveBeat.fiveMinuteScript(),
            calibrations: calibrations, layout: layout, configuration: configuration, players: roster)
        try requireLaserValue(wave.deferred.isEmpty && !wave.encounters.isEmpty, "live wave plan")
        let timing = configuration.evidenceTiming
        var minutes: [[LaserEncounter]] = Array(repeating: [], count: 5)
        for encounter in wave.encounters {
            let crossing = encounter.targets[0].crossingTime
            let index = Int(crossing / 60)
            guard (0..<5).contains(index) else { continue }
            // Keep encounters judged before the segment's vault (always true for 60 s).
            guard timing.finalizationTime(crossing: crossing - Double(index) * 60) < segmentLength else { continue }
            minutes[index].append(encounter)
        }
        self.minutes = minutes.map { $0.sorted { $0.targets[0].warningTime < $1.targets[0].warningTime } }
        try requireLaserValue(self.minutes.allSatisfy { !$0.isEmpty }, "every minute has encounters")
        self.configuration = configuration; self.layout = layout; self.segmentLength = segmentLength
        baseEncounters = self.minutes.flatMap { $0 }
        var heights: [PlayerID: Double] = [:]
        var placements: [LaserDiamondPlacement] = []
        var zones: [PlayerID: [LaserVaultButton: (LaserDiamondPosition, Double)]] = [:]
        for player in roster {
            let h = LaserLiveRoundGeometryV1.standingHeight(calibrations[player]!, layout: layout)
            try requireLaserValue(h.isFinite && h > 0, "accepted standing height")
            heights[player] = h
            let lane = layout.centerX(for: player)
            let shares = LaserLiveRoundGeometryV1.diamondShares
                + (roster.count == 1 ? LaserLiveRoundGeometryV1.soloExtraDiamondShares : [])
            for share in shares {
                placements.append(try LaserDiamondPlacement(position: .init(x: lane + share.x * h, y: share.y * h),
                                                            eligiblePlayers: [player]))
            }
            for (button, share) in LaserLiveRoundGeometryV1.vaultShares {
                let x = lane + LaserLiveRoundGeometryV1.outward(player) * share.out * h
                zones[player, default: [:]][button] = (try .init(x: x, y: share.y * h),
                                                       LaserLiveRoundGeometryV1.vaultRadiusShare * h)
            }
        }
        vaultZones = zones
        // One radius for the round's diamonds: the shorter player's, so neither gets a bigger target.
        diamondRadius = LaserLiveRoundGeometryV1.diamondRadiusShare * (heights.values.min() ?? 0)
        planner = try LaserDiamondPlanner(seed: seed, placements: placements, approachLead: 0.5, passageDuration: 1)
    }

    /// Fresh, round-unique attempt identities for rebased or recovered encounters.
    private mutating func nextAttempt() -> UUID {
        attemptSerial += 1
        return UUID(uuidString: String(format: "1A770000-0000-4000-8000-%012llX", attemptSerial))!
    }

    private func shifted(_ encounter: LaserEncounter, by delta: Double, attempt: UUID) throws -> LaserEncounter {
        try LaserEncounter(id: encounter.id, attemptID: attempt, targets: encounter.targets.map {
            try LaserTarget(playerID: $0.playerID, calibrationRevision: $0.calibrationRevision,
                            requiredMove: $0.requiredMove, beam: $0.beam,
                            warningTime: $0.warningTime + delta, crossingTime: $0.crossingTime + delta)
        }, roster: Set(encounter.targets.map(\.playerID)))
    }

    /// Begins the current minute at `time`: rebases its encounters and plans its diamonds.
    private mutating func beginMinute(at time: Double) throws {
        let base = Double(minute) * 60
        var planned: [(Double, Action)] = []
        for encounter in minutes[minute] {
            let moved = try shifted(encounter, by: time - base, attempt: nextAttempt())
            planned.append((moved.targets[0].warningTime, .register(moved)))
        }
        let boundary = time + segmentLength
        for spawn in try planner.normalMinute(minute, from: time, until: boundary) {
            planned.append((spawn.spawnedAt, .normalDiamond(spawn, boundary: boundary)))
        }
        pending = planned.enumerated().sorted {
            $0.element.0 == $1.element.0 ? $0.offset < $1.offset : $0.element.0 < $1.element.0
        }.map { (time: $0.element.0, action: $0.element.1) }
        minuteStart = time
        vaultOpened = false
    }

    /// The next action due at or before `time`, given the authoritative game. Call repeatedly
    /// (advancing the game to each returned time first) until it returns nil.
    mutating func nextDue(through time: Double, game: LaserGame) throws -> (time: Double, action: Action)? {
        guard game.roundOutcome == nil, !isFinishedPlanning else { return nil }
        switch game.roundPhase {
        case .activity:
            if minuteStart == nil || vaultOpened {
                // A vault just opened successfully (or the round began): the next minute starts now.
                if vaultOpened { minute += 1; minuteStart = nil; guard !isFinishedPlanning else { return nil } }
                try beginMinute(at: game.gameTime)
            }
            if let first = pending.first, first.time <= time {
                pending.removeFirst()
                return first
            }
            guard pending.isEmpty, let boundary = vaultBoundary, boundary <= time,
                  game.activeDiamonds.isEmpty, game.isEveryRegisteredEncounterSettled else { return nil }
            // The vault waits for every registered laser to be judged; it never withdraws one.
            // A DEBUG Solo Test vault has the roster's (P1's) three buttons only.
            vaultOpened = true
            let id = UUID(uuidString: String(format: "D1B00000-0000-4000-8000-%012d", minute + 1))!
            var zones: [LaserVaultZone] = []
            for (playerIndex, player) in PlayerID.allCases.enumerated() where roster.contains(player) {
                for (buttonIndex, button) in LaserVaultButton.allCases.enumerated() {
                    let zone = vaultZones[player]![button]!
                    let target = UUID(uuidString: String(format: "D1C00000-0000-4000-8000-%012d",
                        1 + minute * 6 + playerIndex * 3 + buttonIndex))!
                    zones.append(LaserVaultZone(targetID: target, playerID: player, button: button,
                                                position: zone.position, radius: zone.radius))
                }
            }
            return (max(boundary, game.gameTime), .openVault(id, zones: zones))
        default:
            return nil
        }
    }

    #if DEBUG
    /// DEBUG Solo Test "Skip to Next Gate": game seconds between the skip and the vault.
    static let debugSkipLead = 5.0

    /// DEBUG Solo Test only: ends the current minute early so its vault comes due
    /// `debugSkipLead` game seconds from now. No clock moves: the minute is shortened. Its
    /// not-yet-registered lasers and diamonds are dropped (never registered, judged or scored);
    /// lasers already registered are still judged before the vault opens, as always.
    /// Nil (nothing changed) outside the activity of a begun minute, or when its vault is
    /// already that close, so repeated taps are harmless.
    mutating func debugSkipToVault(game: LaserGame) -> (droppedLasers: Int, droppedDiamonds: Int, vaultAt: Double)? {
        guard isSolo, game.roundOutcome == nil, game.roundPhase == .activity, !isFinishedPlanning,
              !vaultOpened, minuteStart != nil, let boundary = vaultBoundary else { return nil }
        let target = game.gameTime + Self.debugSkipLead
        guard boundary > target else { return nil }
        var lasers = 0, diamonds = 0
        for item in pending {
            switch item.action {
            case .register: lasers += 1
            case .normalDiamond: diamonds += 1
            case .openVault: break
            }
        }
        pending = []
        minuteStart = target - segmentLength
        return (lasers, diamonds, target)
    }
    /// Index (0-based) of the vault the current minute leads to.
    var currentVaultIndex: Int { minute }
    #endif

    /// Bonus targets for Diamond Time, from the same planner the normal minutes used.
    mutating func diamondTimeSpawns(at time: Double, deadline: Double) throws -> [LaserDiamondSpawn] {
        try planner.bonusInitial(at: time, deadline: deadline)
    }

    /// Recovery after a pause withdrew in-flight lasers: the same encounters (same move and
    /// beam, full warning) with fresh attempts, and the rest of the minute moved by the same
    /// delay so ordering and spacing are kept. Never re-judges or drops a laser.
    mutating func recover(_ request: LaserLiveRecoveryRequest) throws -> [LaserEncounter] {
        guard let earliest = request.withdrawn.map({ $0.targets.map(\.warningTime).min()! }).min() else { return [] }
        let delta = max(0, request.gameTime + Self.recoveryLead - earliest)
        var replacements: [LaserEncounter] = []
        for encounter in request.withdrawn.sorted(by: { $0.targets[0].warningTime < $1.targets[0].warningTime }) {
            replacements.append(try shifted(encounter, by: delta, attempt: nextAttempt()))
        }
        if delta > 0 {
            minuteStart = minuteStart.map { $0 + delta }
            var moved: [(time: Double, action: Action)] = []
            for item in pending {
                switch item.action {
                case .register(let encounter):
                    let next = try shifted(encounter, by: delta, attempt: encounter.attemptID)
                    moved.append((item.time + delta, .register(next)))
                case .normalDiamond(let spawn, let boundary):
                    let next = try LaserDiamondSpawn(id: spawn.id, position: spawn.position,
                        eligiblePlayers: spawn.eligiblePlayers, spawnedAt: spawn.spawnedAt + delta,
                        entry: spawn.entry + delta, exit: spawn.exit + delta)
                    moved.append((item.time + delta, .normalDiamond(next, boundary: boundary + delta)))
                case .openVault:
                    moved.append(item)
                }
            }
            pending = moved
        }
        return replacements
    }

    /// Seconds between resuming and the first recovered warning.
    static let recoveryLead = 0.5
}

extension LaserGame {
    /// No registered laser is still waiting for its verdict.
    nonisolated var isEveryRegisteredEncounterSettled: Bool { pendingCrossingCount == 0 }
}
