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
    private var bonusDuration = LaserRoundConfiguration.defaultDiamondTimeDuration
    private(set) var summary: RoundSummary?
    private var primaryPlayerID: PlayerID?
    private var cueLeads: [PlayerID: Double] = [:]
    private var avoidanceCounts: [PlayerID: [LaserMove: Int]] = [:]
    private var coopResults: [LaserCoopRoundResult] = []
    private var actionWindows: [LaserTargetKey: (start: Double, end: Double)] = [:]
    private var trackedCoverage: [PlayerID: [ClosedRange<Double>]] = [:]
    private var withdrawnAttemptIDs: Set<UUID> = []
    private var diamondPoints: Int?
    private var diamondField = LaserDiamondField()
    private var bonusDiamondsStarted = false
    /// Targets each registered attempt carries; its effects commit when all are judged.
    private var targetCounts: [UUID: Int] = [:]
    #if DEBUG
    /// DEBUG Solo Test only: this one player's three presses open a vault (there is no second
    /// player to press theirs). Nil in every co-op round, where both sides are always required.
    var soloPracticePlayer: PlayerID?
    #endif

    var diamonds: [UUID: LaserDiamondState] { diamondField.states }
    var activeDiamonds: [LaserDiamondSpawn] { diamondField.active }
    var diamondsCollected: Int { diamondField.collectedCount }

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
        primaryPlayerID = configuration.primaryPlayerID
        diamondPoints = configuration.diamondPoints
        for player in PlayerID.allCases {
            cueLeads[player] = configuration.scheduling?.players[player]?.cueLead ?? configuration.actionCueLead
        }
    }

    var historyCount: Int { history.values.reduce(0) { $0 + $1.count } }
    /// Registered laser targets still waiting for their verdict.
    var pendingCrossingCount: Int { crossings.values.filter { $0.result == .pending }.count }
    var hasStartedDiamondTimeDiamonds: Bool { bonusDiamondsStarted }
    var crossingCount: Int { crossings.count }
    var isPaused: Bool { blocked && !exited && roundOutcome == nil }
    func hasUsedAttempt(_ id: UUID) -> Bool {
        withdrawnAttemptIDs.contains(id) || crossings.keys.contains { $0.attemptID == id }
            || processedTargets.contains { $0.attemptID == id }
    }

    mutating func register(_ encounter: LaserEncounter) throws {
        try requireLaserValue(!blocked && !exited && roundOutcome == nil && roundPhase == .activity
            && !effectEncounters.contains(encounter.id) && !withdrawnAttemptIDs.contains(encounter.attemptID),
                              "inactive/consumed encounter")
        try requireLaserValue(!hasUsedAttempt(encounter.attemptID), "attempt identity already used in round")
        try requireLaserValue(!crossings.contains { $0.key.encounterID == encounter.id && $0.value.result == .pending },
                              "previous attempt still pending")
        for target in encounter.targets {
            let key = LaserTargetKey(encounterID: encounter.id, attemptID: encounter.attemptID, playerID: target.playerID)
            try requireLaserValue(crossings[key] == nil && !processedTargets.contains(key), "duplicate crossing")
        }
        targetCounts[encounter.attemptID] = encounter.targets.count
        for target in encounter.targets {
            let key = LaserTargetKey(encounterID: encounter.id, attemptID: encounter.attemptID, playerID: target.playerID)
            crossings[key] = Crossing(target: target, result: .pending)
            if let lead = cueLeads[target.playerID] {
                actionWindows[key] = (max(gameTime, target.warningTime, target.crossingTime - lead), target.crossingTime)
            }
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
        // Diamond Time ends on arrival deadline, before this packet can add active time or score.
        if let bonusDeadline, arrivedAt >= bonusDeadline {
            try advance(to: max(gameTime, bonusDeadline))
            return
        }
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
        let phaseEnd = min(bonusDeadline ?? time, vault.flatMap { $0.opened ? nil : $0.deadline } ?? time)
        diamondField.advance(to: min(time, phaseEnd))
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
    /// Freeze at the session's GameClock time without finalizing pending evidence while unavailable.
    mutating func pause(at time: Double) throws {
        try requireLaserValue(time.isFinite && time >= gameTime, "pause timeline")
        guard !blocked && !exited && roundOutcome == nil else { return }
        moveTime(to: time)
        pause()
    }
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

    /// Explicit tracking coverage in active game time; not inferred from pose phase or cached frames.
    mutating func recordTrackedInterval(playerID: PlayerID, from start: Double, to end: Double, observedAt time: Double) throws {
        guard roundOutcome == nil && !exited && !blocked else { return }
        try requireLaserValue([start, end, time].allSatisfy { $0.isFinite && $0 >= 0 }
                              && start <= end && end <= time, "tracked coverage")
        trackedCoverage[playerID] = union((trackedCoverage[playerID] ?? []) + [start...end])
    }

    private func union(_ ranges: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        var output: [ClosedRange<Double>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = output.last, range.lowerBound <= last.upperBound {
                output[output.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else { output.append(range) }
        }
        return output
    }

    private func challengeSeconds(for player: PlayerID, endingAt end: Double) -> Double? {
        guard cueLeads[player] != nil, let coverage = trackedCoverage[player] else { return nil }
        let windows = union(actionWindows.filter { $0.key.playerID == player }.values.compactMap { window in
            let last = min(end, window.end)
            return last >= window.start ? window.start...last : nil
        })
        return windows.reduce(0) { sum, window in
            sum + coverage.reduce(0) { $0 + max(0, min(window.upperBound, $1.upperBound) - max(window.lowerBound, $1.lowerBound)) }
        }
    }

    mutating func openVault(id: UUID, at time: Double) throws {
        try advance(to: time)
        try requireLaserValue(!blocked && !exited && roundOutcome == nil && roundPhase == .activity
            && !consumedVaults.contains(id) && (vault == nil || vault?.opened == true), "vault lifecycle")
        try requireLaserValue(activeDiamonds.isEmpty, "normal diamonds must finish before vault")
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
        guard validity == .valid else { return false }
        return try touchVaultBatch(id: id,
            contacts: [LaserVaultContact(playerID: playerID, button: button, calibrationRevision: calibrationRevision)],
            generation: generation, at: time) > 0
    }

    /// Apply one admitted same-frame batch, then transition once. Input/entry and
    /// capture/arrival eligibility are checked before these verified commands.
    @discardableResult
    mutating func touchVaultBatch(id: UUID, contacts: [LaserVaultContact], generation: UUID,
                                  at time: Double) throws -> Int {
        guard !blocked && !exited && roundOutcome == nil, generation == context.sessionGeneration,
              context.isActive, vault?.id == id, vault?.opened == false else { return 0 }
        let eligible = Set(contacts.filter { context.calibrationRevisions[$0.playerID] == $0.calibrationRevision })
        guard !eligible.isEmpty else { return 0 }
        try advance(to: time) // At the exact deadline, timeout wins.
        guard roundOutcome == nil, var current = vault else { return 0 }
        var activated = 0
        for player in PlayerID.allCases {
            for button in LaserVaultButton.allCases where eligible.contains(where: {
                $0.playerID == player && $0.button == button
            }) {
                if current.buttons[player, default: []].insert(button).inserted { activated += 1 }
            }
        }
        vault = current
        guard activated > 0 else { return 0 }
        let verdicts = Dictionary(uniqueKeysWithValues: PlayerID.allCases.map {
            ($0, current.buttons[$0]?.count == 3 ? Judgement.clear : .pending(.awaitingFinalization))
        })
        var succeeded = LaserCoopDecision.evaluate(verdicts) == .succeeded
        #if DEBUG
        if let solo = soloPracticePlayer { succeeded = current.buttons[solo]?.count == LaserVaultButton.allCases.count }
        #endif
        if succeeded {
            current.opened = true
            vault = current
            consumedVaults.insert(id)
            coopResults.append(LaserCoopRoundResult(gateID: id, outcome: .opened, gameTime: time))
            missionProgress = min(missionTarget, missionProgress + 1)
            emit(.coopGateSucceeded(gateID: id, progress: missionProgress), at: time)
            if missionProgress == missionTarget {
                roundPhase = .diamondTime
                bonusDeadline = time + bonusDuration
            } else { roundPhase = .activity }
            emit(.phaseChanged(roundPhase), at: time)
        }
        return activated
    }

    #if DEBUG
    /// DEBUG only, Solo Test or co-op test round ("Skip to Diamond Time"): enters the REAL Diamond Time now, with its
    /// own deadline, so its diamonds, collection, scoring, end and summary run as in a round.
    /// Lasers still in flight are withdrawn (never judged: no CLEAR, score or damage), normal
    /// diamonds on screen close, and an open vault closes unopened. `missionProgress` (vaults
    /// opened) is not raised: no skipped vault is credited. Nil, changing nothing, outside a
    /// round's activity or vault (so repeated taps are harmless).
    @discardableResult
    mutating func debugSkipToDiamondTime(at time: Double) throws -> (withdrawnTargets: Int, closedDiamonds: Int)? {
        guard diamondPoints != nil, !blocked, !exited, roundOutcome == nil,
              roundPhase == .activity || roundPhase == .vault else { return nil }
        try advance(to: time)
        guard roundOutcome == nil, roundPhase == .activity || roundPhase == .vault else { return nil }
        let withdrawn = pendingCrossingCount, closed = activeDiamonds.count
        withdraw()
        diamondField.close()
        if let open = vault, !open.opened { consumedVaults.insert(open.id); vault = nil }
        roundPhase = .diamondTime
        bonusDeadline = gameTime + bonusDuration
        emit(.phaseChanged(.diamondTime), at: gameTime)
        return (withdrawn, closed)
    }
    #endif

    /// Explicit synthetic/domain plans now; live placement/reach and E08 admission are pending.
    mutating func spawnNormalDiamonds(_ spawns: [LaserDiamondSpawn], beforeVaultAt boundary: Double) throws {
        try requireLaserValue(!blocked && !exited && roundOutcome == nil && roundPhase == .activity
                              && diamondPoints != nil, "normal diamond lifecycle/configuration")
        try diamondField.spawn(spawns, at: gameTime, before: boundary)
    }

    mutating func startDiamondTimeDiamonds(_ spawns: [LaserDiamondSpawn]) throws {
        try requireLaserValue(!blocked && !exited && roundOutcome == nil && roundPhase == .diamondTime
            && !bonusDiamondsStarted && diamondPoints != nil
            && spawns.count == LaserRoundConfiguration.initialBonusDiamondCount
            && bonusDeadline == gameTime + bonusDuration, "initial bonus diamond plan")
        guard let bonusDeadline else { throw LaserDataError.invalidValue("missing bonus deadline") }
        try diamondField.spawn(spawns, at: gameTime, before: bonusDeadline, maximumActive: 4,
                               bonusDeadline: bonusDeadline)
        bonusDiamondsStarted = true
    }

    /// Contact tracker output after producer/context admission, not raw wrist input.
    /// Replacements are paired with accepted collections in stable target-ID order.
    @discardableResult
    mutating func collectDiamonds(_ contacts: [LaserContactActivation], generation: UUID,
                                  calibrationRevisions: [PlayerID: UInt64], capturedAt: Double,
                                  arrivedAt: Double, replacements: [LaserDiamondSpawn] = [],
                                  bodyContacts: [UUID: Set<PlayerID>] = [:]) throws
        -> [LaserContactActivation] {
        guard !blocked && !exited && roundOutcome == nil && context.isActive,
              generation == context.sessionGeneration, let diamondPoints else { return [] }
        try requireLaserValue(capturedAt.isFinite && arrivedAt.isFinite && capturedAt >= 0
                              && capturedAt <= arrivedAt && arrivedAt >= gameTime, "diamond contact timeline")
        // Roll back plan errors, including score and phase state, as one domain operation.
        var next = self
        try next.advance(to: arrivedAt)
        guard next.roundOutcome == nil, next.roundPhase != .vault else { self = next; return [] }
        let eligible = contacts.filter {
            if let revision = calibrationRevisions[$0.hand.playerID], revision > 0 {
                return revision == context.calibrationRevisions[$0.hand.playerID]
            }
            return false
        }
        let eligibleBodies = bodyContacts.mapValues { players in players.filter {
            guard let revision = calibrationRevisions[$0], revision > 0 else { return false }
            return revision == context.calibrationRevisions[$0]
        } }
        let accepted = try next.diamondField.collect(eligible, capturedAt: capturedAt, arrivedAt: arrivedAt,
            replacements: replacements, bonusDeadline: next.roundPhase == .diamondTime ? next.bonusDeadline : nil,
            bodyContacts: eligibleBodies)
        let (points, multipliedOverflow) = diamondPoints.multipliedReportingOverflow(by: next.diamondsCollected - diamondsCollected)
        let (score, scoreOverflow) = next.teamScore.addingReportingOverflow(points)
        try requireLaserValue(!multipliedOverflow && !scoreOverflow, "diamond score overflow")
        next.teamScore = score
        self = next
        return accepted
    }

    private mutating func end(_ outcome: LaserRoundOutcome, at time: Double) {
        guard roundOutcome == nil else { return }
        roundOutcome = outcome
        moveTime(to: time)
        roundPhase = .ended(outcome)
        if let vault, !vault.opened {
            coopResults.append(LaserCoopRoundResult(gateID: vault.id,
                outcome: outcome == .vaultFailed ? .timedOut : .interrupted, gameTime: time))
        }
        withdraw()
        diamondField.advance(to: time)
        diamondField.close()
        emit(.roundEnded(outcome), at: time)
        summary = RoundSummary(sessionGeneration: context.sessionGeneration, outcome: outcome,
            gameDuration: gameTime, activityDuration: activityProgress, remainingTeamHealth: teamHealth,
            teamScore: teamScore, targets: PlayerID.allCases.compactMap { playerStats[$0] },
            diamondsCollected: diamondsCollected, vaultsOpened: missionProgress, withdrawnAttempts: withdrawnAttemptIDs.count,
            playerResults: PlayerID.allCases.map { player in
                LaserPlayerRoundResult(playerID: player, successfulHighAvoidances: avoidanceCounts[player]?[.duck] ?? 0,
                    successfulLowAvoidances: avoidanceCounts[player]?[.jump] ?? 0,
                    validatedJumpCycles: nil, movementChallengeSeconds: challengeSeconds(for: player, endingAt: time))
            }, coopResults: coopResults, missionProgress: missionProgress, missionTarget: missionTarget,
            primaryPlayerID: primaryPlayerID)
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
        let pending = crossings.keys.filter { crossings[$0]?.result == .pending }.sorted {
            if $0.encounterID != $1.encounterID { return $0.encounterID.uuidString < $1.encounterID.uuidString }
            if $0.attemptID != $1.attemptID { return $0.attemptID.uuidString < $1.attemptID.uuidString }
            return $0.playerID.rawValue < $1.playerID.rawValue
        }
        for key in pending {
            if withdrawnAttemptIDs.insert(key.attemptID).inserted {
                emit(.attemptWithdrawn(encounterID: key.encounterID, attemptID: key.attemptID), at: gameTime)
            }
            if let window = actionWindows[key] { actionWindows[key] = (window.start, min(window.end, gameTime)) }
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
        // Every target the encounter registered (two in co-op; one in a DEBUG solo practice).
        guard pair.count == targetCounts[key.attemptID], pair.values.allSatisfy({ $0.judgement != nil }) else { return }
        let time = pair.values.map { timing.finalizationTime(crossing: $0.target.crossingTime) }.max()!
        let values = pair.values.compactMap(\.judgement)
        processedTargets.formUnion(pair.keys)
        for player in PlayerID.allCases where pair.contains(where: { $0.key.playerID == player }) {
            let value = pair.first { $0.key.playerID == player }!.value.judgement!
            let old = playerStats[player]!
            var clear = 0, hit = 0, unavailable = 0
            emit(.targetJudged(encounterID: key.encounterID, playerID: player, judgement: value), at: time)
            switch value {
            case .clear:
                clear = 1
                let move = pair.first { $0.key.playerID == player }!.value.target.requiredMove
                avoidanceCounts[player, default: [:]][move, default: 0] += 1
                emit(.playerCleared(encounterID: key.encounterID, playerID: player), at: time)
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
