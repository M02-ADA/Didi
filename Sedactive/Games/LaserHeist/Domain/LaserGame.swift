//
//  LaserGame.swift
//  Sedactive
//
//  Created by Edward Geraldo Kristian on 25/10/26.
////gameplay progression


import Foundation

nonisolated enum LaserGameEventKind: Equatable, Sendable {
    case playerCleared(encounterID: UUID, playerID: PlayerID)
    case playerHit(encounterID: UUID, playerID: PlayerID)
    case coopGateSucceeded(gateID: UUID, progress: Int)
    case coopGateFailed(gateID: UUID)
    case teamDamaged(amount: Int, remainingHealth: Int)
    case warning(encounterID: UUID, playerID: PlayerID)
    case targetJudged(encounterID: UUID, playerID: PlayerID, judgement: Judgement)
    case attemptWithdrawn(encounterID: UUID, attemptID: UUID)
    case teamEffectsCommitted(encounterID: UUID, healthDelta: Int, scoreDelta: Int)
    case phaseChanged(LaserRoundPhase)
    case roundEnded(LaserRoundOutcome)
}

nonisolated struct GameEvent: Equatable, Sendable {
    let id: UUID
    let sessionGeneration: UUID
    /// Explicit sequence breaks same-time ties and supports consumer deduplication.
    let sequence: UInt64
    let gameTime: Double
    let kind: LaserGameEventKind
}

nonisolated struct LaserTargetKey: Hashable, Sendable {
    let encounterID: UUID
    let attemptID: UUID
    let playerID: PlayerID
}

/// Authoritative evidence, locked verdicts, team totals, mission progress and terminal events.
nonisolated struct LaserGame: Sendable {
    private struct Crossing: Sendable {
        let target: LaserTarget
        var result: LaserEvidenceSelection
        var historyOverflow = false
        var judgement: Judgement?
    }
    let timing: LaserEvidenceTiming
    private var context: BodyInputContext
    private let capacity: Int
    private let clearanceMargin: Double?
    private var history: [PlayerID: [LaserBodyEvidence]] = [:]
    /// At most one scalar per slot, so pruning does not erase the stale-vs-none reason.
    private var lastPrunedCapture: [PlayerID: Double] = [:]
    private var crossings: [LaserTargetKey: Crossing] = [:]
    private var blocked = false
    private var exited = false
    private var effectEncounters: Set<UUID> = []
    private var processedTargets: Set<LaserTargetKey> = []
    private var clearPoints = 100
    private(set) var teamHealth = 5
    private(set) var teamScore = 0
    private(set) var gameTime = 0.0
    private(set) var activityProgress = 0.0
    private(set) var missionProgress = 0
    private(set) var missionTarget = 5
    private(set) var roundPhase: LaserRoundPhase = .activity
    private(set) var roundOutcome: LaserRoundOutcome?
    private(set) var playerStats: [PlayerID: LaserPlayerTargetCounts] = [:]
    private(set) var vault: LaserVaultState?
    private var bonusDeadline: Double?
    private var consumedVaults: Set<UUID> = []
    private var events: [GameEvent] = []
    private var eventSequence: UInt64 = 0
    private var vaultDuration = 5.0
    private var bonusDuration = 15.0

    /// Nil margin preserves evidence-only LH-09 usage. Supply round configuration to enable verdicts.
    init(timing: LaserEvidenceTiming, context: BodyInputContext, historyCapacityPerPlayer: Int,
         clearanceMargin: Double? = nil) throws {
        try requireLaserValue(historyCapacityPerPlayer > 0 && context.isActive, "history capacity/context")
        try requireLaserValue(clearanceMargin.map { $0.isFinite && $0 >= 0 } ?? true, "clearance margin")
        self.timing = timing
        self.context = context
        capacity = historyCapacityPerPlayer
        self.clearanceMargin = clearanceMargin
    }

    init(configuration: LaserRoundConfiguration, context: BodyInputContext, historyCapacityPerPlayer: Int) throws {
        try self.init(timing: configuration.evidenceTiming, context: context,
                      historyCapacityPerPlayer: historyCapacityPerPlayer, clearanceMargin: configuration.clearanceMargin)
        teamHealth = configuration.initialTeamHealth
        clearPoints = configuration.clearTargetPoints
        missionTarget = configuration.missionGateTarget
        vaultDuration = configuration.vaultDuration
        bonusDuration = configuration.diamondTimeDuration
    }

    var historyCount: Int { history.values.reduce(0) { $0 + $1.count } }
    var crossingCount: Int { crossings.count }

    mutating func register(_ encounter: LaserEncounter) throws {
        try requireLaserValue(!blocked && !exited && roundOutcome == nil && roundPhase == .activity
            && !effectEncounters.contains(encounter.id), "inactive/consumed encounter")
        try requireLaserValue(!crossings.contains { $0.key.encounterID == encounter.id && $0.value.result == .pending },
                              "previous attempt still pending")
        for target in encounter.targets {
            let key = LaserTargetKey(encounterID: encounter.id, attemptID: encounter.attemptID, playerID: target.playerID)
            try requireLaserValue(crossings[key] == nil && !processedTargets.contains(key), "duplicate crossing")
        }
        for target in encounter.targets {
            let key = LaserTargetKey(encounterID: encounter.id, attemptID: encounter.attemptID, playerID: target.playerID)
            crossings[key] = Crossing(target: target, result: .pending)
            let old = playerStats[target.playerID] ?? LaserPlayerTargetCounts(playerID: target.playerID, scheduled: 0, cleared: 0, hit: 0, unavailable: 0)
            playerStats[target.playerID] = LaserPlayerTargetCounts(playerID: target.playerID, scheduled: old.scheduled + 1,
                cleared: old.cleared, hit: old.hit, unavailable: old.unavailable)
        }
    }

    mutating func receive(_ snapshot: BodySnapshot, capturedGameTime: Double, arrivedAt: Double) throws {
        try snapshot.validate()
        try requireLaserValue(arrivedAt.isFinite && arrivedAt >= gameTime && capturedGameTime.isFinite
                              && capturedGameTime >= 0 && capturedGameTime <= arrivedAt, "evidence timeline")
        guard !blocked && !exited && roundOutcome == nil else { return }
        // Earlier deadlines close before this delivery. Equal-time deliveries precede advance(to:).
        try finalize(at: arrivedAt, inclusive: false)
        guard roundOutcome == nil else { return }
        moveTime(to: arrivedAt)
        guard snapshot.sessionGeneration == context.sessionGeneration,
              snapshot.cameraGeometryRevision == context.cameraGeometryRevision else { prune(); return }
        let evidence = LaserBodyEvidence(snapshot: snapshot, capturedGameTime: capturedGameTime, arrivedGameTime: arrivedAt)
        for id in PlayerID.allCases {
            var samples = history[id, default: []]
            if let previous = samples.first(where: { $0.snapshot.frameID == snapshot.frameID }) {
                try requireLaserValue(previous.snapshot == snapshot && previous.capturedGameTime == capturedGameTime,
                                      "conflicting duplicate frame")
                continue // Keep the original arrival time.
            }
            if samples.count == capacity {
                // Overload must never fabricate clearance or player damage from an incomplete window.
                for key in Array(crossings.keys) where key.playerID == id {
                    if crossings[key]?.result == .pending { crossings[key]?.historyOverflow = true }
                }
                samples.removeFirst()
            }
            samples.append(evidence)
            history[id] = samples
        }
        prune()
    }

    mutating func advance(to time: Double) throws {
        try requireLaserValue(time.isFinite && time >= gameTime, "game time must be monotonic")
        guard !blocked && !exited && roundOutcome == nil else { return }
        try finalize(at: time, inclusive: true)
        guard roundOutcome == nil else { return }
        prune()
        if let vault, !vault.opened, time >= vault.deadline {
            emit(.coopGateFailed(gateID: vault.id), at: vault.deadline)
            consumedVaults.insert(vault.id)
            end(.vaultFailed, at: vault.deadline)
        }
        if let bonusDeadline, time >= bonusDeadline { end(.completed, at: bonusDeadline) }
        if roundOutcome == nil { moveTime(to: time); prune() }
    }

    func selection(for key: LaserTargetKey) -> LaserEvidenceSelection? {
        guard !blocked && !exited else { return .withdrawn }
        return crossings[key]?.result
    }

    func judgement(for key: LaserTargetKey) -> Judgement? {
        guard !blocked && !exited, clearanceMargin != nil, let crossing = crossings[key] else { return nil }
        if crossing.result == .pending { return .pending(.awaitingFinalization) }
        return crossing.judgement
    }

    mutating func pause() { withdraw(); blocked = true }
    mutating func exit(outcome: LaserRoundOutcome = .aborted) { withdraw(); exited = true; end(outcome, at: gameTime) }
    mutating func resume() { if !exited && context.isActive { blocked = false } }
    /// Coordinator rechecks the producer context after suspension and before receive/advance.
    mutating func updateContext(_ value: BodyInputContext) {
        guard value != context else { return }
        withdraw()
        context = value
        blocked = true // Fresh readiness/countdown and attempt IDs are required after cutover.
    }
    /// Caller releases consumed results; attempts must use a fresh ID when retried.
    mutating func remove(_ key: LaserTargetKey) { crossings.removeValue(forKey: key) }

    mutating func drainEvents() -> [GameEvent] {
        let output = events
        events.removeAll(keepingCapacity: true)
        return output
    }

    mutating func openVault(id: UUID, at time: Double) throws {
        try advance(to: time)
        try requireLaserValue(!blocked && !exited && roundOutcome == nil && roundPhase == .activity
            && !consumedVaults.contains(id) && (vault == nil || vault?.opened == true), "vault lifecycle")
        withdraw()
        vault = LaserVaultState(id: id, deadline: time + vaultDuration, buttons: [.player1: [], .player2: []])
        roundPhase = .vault
        emit(.phaseChanged(.vault), at: time)
    }

    /// A verified wrist-contact result, not a hand detector. Replay supplies synthetic contacts.
    @discardableResult
    mutating func touchVault(id: UUID, playerID: PlayerID, button: LaserVaultButton,
                             validity: EvidenceValidity, generation: UUID, calibrationRevision: UInt64,
                             at time: Double) throws -> Bool {
        guard !blocked && !exited && roundOutcome == nil, validity == .valid,
              generation == context.sessionGeneration, context.calibrationRevisions[playerID] == calibrationRevision,
              context.isActive, vault?.id == id, vault?.opened == false else { return false }
        try advance(to: time) // At the exact deadline, timeout wins.
        guard roundOutcome == nil, var current = vault else { return false }
        guard current.buttons[playerID, default: []].insert(button).inserted else { return false }
        vault = current
        let verdicts = Dictionary(uniqueKeysWithValues: PlayerID.allCases.map {
            ($0, current.buttons[$0]?.count == 3 ? Judgement.clear : .pending(.awaitingFinalization))
        })
        if LaserCoopDecision.evaluate(verdicts) == .succeeded {
            current.opened = true
            vault = current
            consumedVaults.insert(id)
            missionProgress = min(missionTarget, missionProgress + 1)
            emit(.coopGateSucceeded(gateID: id, progress: missionProgress), at: time)
            if missionProgress == missionTarget {
                roundPhase = .diamondTime
                bonusDeadline = time + bonusDuration
            } else { roundPhase = .activity }
            emit(.phaseChanged(roundPhase), at: time)
        }
        return true
    }

    private mutating func end(_ outcome: LaserRoundOutcome, at time: Double) {
        guard roundOutcome == nil else { return }
        roundOutcome = outcome
        moveTime(to: time)
        roundPhase = .ended(outcome)
        emit(.roundEnded(outcome), at: time)
        for key in Array(crossings.keys) where crossings[key]?.result == .pending { crossings[key]?.result = .withdrawn }
        history.removeAll()
    }

    private mutating func emit(_ kind: LaserGameEventKind, at time: Double) {
        eventSequence += 1
        let id = UUID(uuidString: String(format: "16000000-0000-4000-8000-%012llu", eventSequence))!
        events.append(GameEvent(id: id, sessionGeneration: context.sessionGeneration,
                                sequence: eventSequence, gameTime: time, kind: kind))
    }

    private mutating func moveTime(to time: Double) {
        if roundPhase != .vault { activityProgress += max(0, time - gameTime) }
        gameTime = time
    }

    private mutating func withdraw() {
        for key in Array(crossings.keys) where crossings[key]?.result == .pending {
            crossings[key]?.result = .withdrawn
        }
        history.removeAll()
        lastPrunedCapture.removeAll()
    }

    private mutating func finalize(at time: Double, inclusive: Bool) throws {
        let ordered = crossings.keys.sorted { left, right in
            let a = timing.finalizationTime(crossing: crossings[left]!.target.crossingTime)
            let b = timing.finalizationTime(crossing: crossings[right]!.target.crossingTime)
            if a != b { return a < b }
            if left.encounterID != right.encounterID { return left.encounterID.uuidString < right.encounterID.uuidString }
            return left.playerID.rawValue < right.playerID.rawValue
        }
        for key in ordered {
            guard roundOutcome == nil else { break }
            guard let crossing = crossings[key], crossing.result == .pending else { continue }
            let deadline = timing.finalizationTime(crossing: crossing.target.crossingTime)
            guard inclusive ? deadline <= time : deadline < time else { continue }
            var result: LaserEvidenceSelection = crossing.historyOverflow ? .unavailable(.historyOverflow)
                : LaserCollisionJudge().select(target: crossing.target,
                    history: history[key.playerID, default: []], timing: timing, context: context)
            if result == .unavailable(.noSample), let pruned = lastPrunedCapture[key.playerID],
               pruned < timing.captureWindow(crossing: crossing.target.crossingTime).lowerBound {
                result = .unavailable(.stale)
            }
            let verdict: Judgement?
            if let clearanceMargin {
                verdict = try LaserCollisionJudge().judge(target: crossing.target, selection: result,
                                                         clearanceMargin: clearanceMargin, context: context)
            } else { verdict = nil }
            crossings[key]?.result = result
            crossings[key]?.judgement = verdict
            commitEncounter(for: key)
        }
    }

    private mutating func commitEncounter(for key: LaserTargetKey) {
        guard !effectEncounters.contains(key.encounterID) && !processedTargets.contains(key) else { return }
        let pair = crossings.filter { $0.key.encounterID == key.encounterID && $0.key.attemptID == key.attemptID }
        guard pair.count == 2, pair.values.allSatisfy({ $0.judgement != nil }) else { return }
        let time = pair.values.map { timing.finalizationTime(crossing: $0.target.crossingTime) }.max()!
        let values = pair.values.compactMap(\.judgement)
        processedTargets.formUnion(pair.keys)
        for player in PlayerID.allCases {
            let value = pair.first { $0.key.playerID == player }!.value.judgement!
            let old = playerStats[player]!
            var clear = 0, hit = 0, unavailable = 0
            emit(.targetJudged(encounterID: key.encounterID, playerID: player, judgement: value), at: time)
            switch value {
            case .clear: clear = 1; emit(.playerCleared(encounterID: key.encounterID, playerID: player), at: time)
            case .hit: hit = 1; emit(.playerHit(encounterID: key.encounterID, playerID: player), at: time)
            case .unavailable: unavailable = 1
            case .pending: break
            }
            playerStats[player] = LaserPlayerTargetCounts(playerID: player, scheduled: old.scheduled,
                cleared: old.cleared + clear, hit: old.hit + hit, unavailable: old.unavailable + unavailable)
        }
        let technical = values.contains { if case .unavailable = $0 { true } else { false } }
        if !technical { effectEncounters.insert(key.encounterID) }
        let damage = technical ? 0 : values.filter { if case .hit = $0 { true } else { false } }.count
        let score = technical ? 0 : values.filter { $0 == .clear }.count * clearPoints
        let actualDamage = min(teamHealth, damage)
        teamHealth -= actualDamage
        teamScore += score
        emit(.teamEffectsCommitted(encounterID: key.encounterID, healthDelta: -actualDamage, scoreDelta: score), at: time)
        if actualDamage > 0 { emit(.teamDamaged(amount: actualDamage, remainingHealth: teamHealth), at: time) }
        if teamHealth == 0 { end(.healthDepleted, at: time) }
    }

    private mutating func prune() {
        let cutoff = gameTime - (timing.windowBefore + timing.windowAfter + timing.deliveryAllowance)
        for id in PlayerID.allCases {
            if let removed = history[id]?.filter({ $0.capturedGameTime < cutoff }).map(\.capturedGameTime).max() {
                lastPrunedCapture[id] = max(lastPrunedCapture[id] ?? removed, removed)
            }
            history[id]?.removeAll { $0.capturedGameTime < cutoff }
        }
    }
}
