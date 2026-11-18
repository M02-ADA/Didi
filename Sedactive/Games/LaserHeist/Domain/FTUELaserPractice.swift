import Foundation

/// FTUE-only outcome authority: existing judges, no LaserGame effect commit, health or score.
/// All input is original CP1 snapshots from the already-owned session stream.
nonisolated struct FTUELaserPractice {
    enum Outcome: Equatable { case pending, clear, hit, unavailable }
    let generation: UUID
    let roster: [PlayerID]
    let configuration: LaserRoundConfiguration
    let input: BodyInputConfiguration
    let poseFirst: Bool
    private(set) var context: BodyInputContext
    private(set) var move: LaserMove = .jump
    private(set) var encounter: LaserEncounter!
    private(set) var elapsed = 0.0
    private(set) var verdicts: [PlayerID: Judgement] = [:]
    private(set) var outcome: Outcome = .pending
    private(set) var completed = false
    private(set) var attemptNumber = 0
    private var history: [LaserBodyEvidence] = []
    private var lastHost: Double?
    private var epochHost: Double?
    private var lastFrame: UInt64?
    private var lastCapture: Double?
    private var interrupted = false
    private var overflow = false

    init(input: BodyInputConfiguration, configuration: LaserRoundConfiguration,
         context: BodyInputContext, poseFirst: Bool) throws {
        generation = input.sessionGeneration; roster = input.roster
        self.input = input; self.configuration = configuration; self.context = context; self.poseFirst = poseFirst
        try requireLaserValue(context.isActive && context.sessionGeneration == generation, "FTUE context")
        try restart()
    }
    var crossing: Double { encounter.targets[0].crossingTime }
    var deadline: Double { configuration.evidenceTiming.finalizationTime(crossing: crossing) }
    var attemptID: UUID { encounter.attemptID }
    var state: LaserGameState {
        .init(sessionGeneration: generation, phase: .activity, gameTime: elapsed, activityProgress: 0,
            teamHealth: configuration.initialTeamHealth, teamScore: 0,
            encounters: [.init(encounter: encounter, judgements: verdicts, effectsCommitted: outcome != .pending)])
    }
    private mutating func restart() throws {
        let lead = roster.compactMap { configuration.scheduling?.players[$0]?.warningLead }.max() ?? 3
        let beat = LaserWaveBeat(id: UUID(), move: move, nominalCrossingTime: max(3, lead), segmentEnd: 60)
        let result = try LaserWaveDirector().schedule(script: [beat], calibrations: input.calibrations,
            layout: input.playerPlaneLayout, configuration: configuration, players: roster)
        guard let next = result.encounters.first else { throw LaserDataError.invalidValue("FTUE target scheduling") }
        encounter = next; attemptNumber += 1; elapsed = 0; verdicts = [:]; outcome = .pending
        history.removeAll(keepingCapacity: true); lastHost = nil; epochHost = nil; lastFrame = nil; lastCapture = nil
        interrupted = false; overflow = false
    }
    /// Existing frame host supplies time. A pause invalidates only the pending attempt; resume
    /// gives the roster a full new warning and original-source cutoff, not a hidden crossing.
    mutating func update(at now: Double, eligible: Bool, context current: BodyInputContext?) throws {
        guard !completed, now.isFinite, now >= 0 else { return }
        guard eligible, let current, current.isActive, current.sessionGeneration == generation else {
            if outcome == .pending { interrupted = true }
            lastHost = nil; return
        }
        if current != context {
            guard current.calibrationRevisions == context.calibrationRevisions,
                  current.cameraGeometryRevision == context.cameraGeometryRevision,
                  current.wristContact == context.wristContact else {
                interrupted = true; lastHost = nil; return // accepted-context replacement requires new setup
            }
            context = current
        }
        if interrupted || outcome == .unavailable { try restart() }
        if lastHost == nil { lastHost = now; if epochHost == nil { epochHost = now - elapsed }; return }
        guard let previous = lastHost, now >= previous else { return }
        lastHost = now
        guard now - previous <= 0.25 else { interrupted = outcome == .pending; return }
        elapsed += now - previous
        if outcome == .pending, elapsed >= deadline { try finalize() }
    }
    mutating func receive(_ packet: BodySnapshot, at host: Double, maximumAge: Double) throws {
        guard !completed, outcome == .pending, !interrupted, let epochHost, let lastHost,
              host >= lastHost, packet.capturedAt > epochHost, packet.capturedAt <= host,
              host - packet.capturedAt <= maximumAge, context.accepts(packet),
              (lastFrame.map({ packet.frameID > $0 }) ?? true),
              (lastCapture.map({ packet.capturedAt > $0 }) ?? true) else { return }
        try packet.validate()
        let capture = packet.capturedAt - epochHost, arrival = host - epochHost
        guard arrival <= deadline else { return }
        lastFrame = packet.frameID; lastCapture = packet.capturedAt
        let evidence = LaserBodyEvidence(snapshot: packet, capturedGameTime: capture, arrivedGameTime: arrival)
        // As in normal evidence history: keep only one stale predecessor before the capture
        // window, not the whole warning lead (which could overflow at a fast capture cadence).
        if capture < configuration.evidenceTiming.captureWindow(crossing: crossing).lowerBound {
            history = [evidence]; return
        }
        if history.count >= 120 { overflow = true; return }
        history.append(evidence)
    }
    private mutating func finalize() throws {
        let judge = LaserCollisionJudge(acceptsPresenceHeldEvidence: poseFirst)
        for target in encounter.targets {
            if overflow { verdicts[target.playerID] = .unavailable(.historyOverflow) }
            else if move == .jump, poseFirst {
                verdicts[target.playerID] = judge.judgeJumpEvent(target: target, history: history,
                    timing: configuration.evidenceTiming, context: context,
                    minimumFlight: PoseFirstCandidate.jumpMinimumFlight, tolerance: PoseFirstCandidate.jumpTimingTolerance)
            } else {
                verdicts[target.playerID] = try judge.judge(target: target,
                    selection: judge.select(target: target, history: history, timing: configuration.evidenceTiming, context: context),
                    clearanceMargin: configuration.clearanceMargin, context: context)
            }
        }
        // Same team feedback semantics: a committed HIT can resolve failure; unavailable alone
        // never becomes a hit or a success. No CLEAR survives into the next roster attempt.
        if verdicts.values.contains(where: { if case .hit = $0 { true } else { false } }) { outcome = .hit }
        else if verdicts.count == roster.count && verdicts.values.allSatisfy({ $0 == .clear }) { outcome = .clear }
        else { outcome = .unavailable }
    }
    mutating func feedbackFinished(attempt: UUID, generation: UUID) throws {
        guard self.generation == generation, attempt == attemptID, !completed, lastHost != nil else { return }
        if outcome == .hit { try restart() }
        else if outcome == .clear {
            if move == .jump { move = .duck; try restart() } else { completed = true }
        }
    }
}
