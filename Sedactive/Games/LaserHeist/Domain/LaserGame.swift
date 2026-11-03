//
//  LaserGame.swift
//  Sedactive
//
//  Created by Edward Geraldo Kristian on 25/10/26.
////gameplay progression


import Foundation

nonisolated enum LaserGameEventKind: Equatable, Sendable {
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

/// Owns bounded evidence and exactly-once target verdicts. Health/scoring remain separate work.
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
    private var clearPoints = 100
    private(set) var teamHealth = 5
    private(set) var teamScore = 0
    private(set) var gameTime = 0.0

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
    }

    var historyCount: Int { history.values.reduce(0) { $0 + $1.count } }
    var crossingCount: Int { crossings.count }

    mutating func register(_ encounter: LaserEncounter) throws {
        try requireLaserValue(!blocked && !exited, "inactive game")
        for target in encounter.targets {
            let key = LaserTargetKey(encounterID: encounter.id, attemptID: encounter.attemptID, playerID: target.playerID)
            try requireLaserValue(crossings[key] == nil, "duplicate crossing")
        }
        for target in encounter.targets {
            let key = LaserTargetKey(encounterID: encounter.id, attemptID: encounter.attemptID, playerID: target.playerID)
            crossings[key] = Crossing(target: target, result: .pending)
        }
    }

    mutating func receive(_ snapshot: BodySnapshot, capturedGameTime: Double, arrivedAt: Double) throws {
        try snapshot.validate()
        try requireLaserValue(arrivedAt.isFinite && arrivedAt >= gameTime && capturedGameTime.isFinite
                              && capturedGameTime >= 0 && capturedGameTime <= arrivedAt, "evidence timeline")
        guard !blocked && !exited else { return }
        // Earlier deadlines close before this delivery. Equal-time deliveries precede advance(to:).
        try finalize(at: arrivedAt, inclusive: false)
        gameTime = arrivedAt
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
        guard !blocked && !exited else { return }
        gameTime = time
        try finalize(at: time, inclusive: true)
        prune()
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
    mutating func exit() { withdraw(); exited = true }
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

    private mutating func withdraw() {
        for key in Array(crossings.keys) where crossings[key]?.result == .pending {
            crossings[key]?.result = .withdrawn
        }
        history.removeAll()
        lastPrunedCapture.removeAll()
    }

    private mutating func finalize(at time: Double, inclusive: Bool) throws {
        for key in Array(crossings.keys) {
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
        }
        // Minimal replay-slice aggregation: commit one pair of target results once per logical encounter.
        for id in Set(crossings.keys.map(\.encounterID)) where !effectEncounters.contains(id) {
            let pair = crossings.filter { $0.key.encounterID == id }
            guard pair.count == 2, pair.values.allSatisfy({ $0.result != .pending && $0.result != .withdrawn }),
                  pair.values.allSatisfy({ $0.judgement != nil }) else { continue }
            let values = pair.values.compactMap(\.judgement)
            effectEncounters.insert(id)
            if values.contains(where: { if case .unavailable = $0 { true } else { false } }) { continue }
            teamHealth = max(0, teamHealth - values.filter { if case .hit = $0 { true } else { false } }.count)
            teamScore += values.filter { $0 == .clear }.count * clearPoints
        }
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
