import Foundation

/// Explicit review inputs, never copied from replay tuning or used as production defaults.
nonisolated struct LaserLiveTimingPolicy: Equatable, Sendable {
    let settlingDuration: Double
    let maximumEvidenceAge: Double
    let countdownDuration: Double

    init(settlingDuration: Double, maximumEvidenceAge: Double, countdownDuration: Double) throws {
        try requireLaserValue(settlingDuration.isFinite && settlingDuration >= 0
            && maximumEvidenceAge.isFinite && maximumEvidenceAge > 0
            && countdownDuration.isFinite && countdownDuration > 0, "live timing policy")
        self.settlingDuration = settlingDuration
        self.maximumEvidenceAge = maximumEvidenceAge
        self.countdownDuration = countdownDuration
    }
}

nonisolated enum LaserLiveReadinessPhase: Equatable, Sendable {
    case blocked(LaserLiveReadinessBlocker), settling, ready, countdown, running, paused, restartRequired
}
nonisolated enum LaserLiveReadinessBlocker: Equatable, Sendable {
    case source, binding, calibration, measurements, staleEvidence, timingPolicy, manualPause, presentation
}

/// Bounded numeric J03 core. It consumes accepted values, never accepts calibration or judges lasers.
/// Source times are original Core Media host seconds. Countdown/pauses do not spend game time.
nonisolated struct LaserLiveReadiness: Sendable {
    let policy: LaserLiveTimingPolicy?
    private(set) var phase: LaserLiveReadinessPhase = .blocked(.source)
    private(set) var blocker: LaserLiveReadinessBlocker? = .source
    private(set) var countdownDeadline: Double?
    private var clock: GameClock?
    private var context: BodyInputContext?
    private var lastFrame: UInt64?
    private var lastCapture: Double?
    private var settlingStart: Double?
    private var distinctSamples = 0
    private var lastEvaluation = 0.0
    private var manualPause = false
    private var evidenceCutover: Double?
    var gameTime: Double { clock?.gameTime ?? 0 }
    var countdownRemaining: Double? {
        guard phase == .countdown, let countdownDeadline else { return nil }
        return max(0, countdownDeadline - lastEvaluation)
    }

    /// The players whose evidence admits the round: both, or P1 alone in a DEBUG Solo Test.
    let roster: [PlayerID]
    #if DEBUG
    /// DEBUG Solo Test only: once RUNNING, missing, invalid or stale body evidence (or a lost
    /// binding) no longer pauses the clock, so the tester can walk to the iPad. The evidence is
    /// still not admitted: the judge sees no sample and the lasers are UNAVAILABLE. Starting,
    /// the countdown and a manual pause keep the normal rules.
    var continuesWithoutEvidence = false
    #endif
    private var toleratesMissingEvidence: Bool {
        #if DEBUG
        continuesWithoutEvidence && phase == .running
        #else
        false
        #endif
    }

    init(policy: LaserLiveTimingPolicy? = nil, roster: [PlayerID] = PlayerID.allCases) {
        self.policy = policy; self.roster = roster
    }

    mutating func updateContext(_ value: BodyInputContext?, at time: Double) throws {
        try validateTime(time)
        guard phase != .restartRequired else { return }
        if context != value {
            if clock != nil { requireRestart(); return }
            resetEvidence()
            context = value
        }
        guard value?.isActive == true else { try block(.source, at: time); return }
        guard roster.allSatisfy({ value?.calibrationRevisions[$0] != nil }) else {
            try block(.calibration, at: time); return
        }
        try evaluate(at: time)
    }

    mutating func observe(_ packet: BodySnapshot, context value: BodyInputContext,
                          bindingConfirmed: Bool, at time: Double) throws {
        try updateContext(value, at: time)
        guard phase != .restartRequired else { return }
        guard value.isActive else { try block(.source, at: time); return }
        guard bindingConfirmed else { if !toleratesMissingEvidence { try block(.binding, at: time) }; return }
        guard roster.allSatisfy({ value.calibrationRevisions[$0] != nil }), value.accepts(packet) else {
            try block(.calibration, at: time); return
        }
        guard (try? packet.validate()) != nil else { try block(.measurements, at: time); return }
        // History may receive out-of-order captures. An older packet's measurement validity must
        // not replace current readiness (the same packet still reaches the domain evidence path).
        if let lastFrame, let lastCapture,
           packet.frameID <= lastFrame || packet.capturedAt <= lastCapture { return }
        guard roster.allSatisfy({ id in
            guard let sample = packet.players[id] else { return false }
            return sample.trackingStatus == .reliable
                && [sample.geometry.crownY, sample.geometry.leftWristY, sample.geometry.rightWristY,
                    sample.geometry.leftSoleY, sample.geometry.rightSoleY].allSatisfy { $0.validity == .valid }
                && sample.jumpState.validity == .valid
        }) else { if !toleratesMissingEvidence { try block(.measurements, at: time) }; return }
        guard let policy else { try block(.timingPolicy, at: time); return }
        guard packet.capturedAt <= time, time - packet.capturedAt < policy.maximumEvidenceAge else {
            if !toleratesMissingEvidence { try block(.staleEvidence, at: time) }; return
        }
        if let evidenceCutover, packet.capturedAt <= evidenceCutover { return }
        if manualPause { try block(.manualPause, at: time); return }
        if let lastCapture, packet.capturedAt - lastCapture >= policy.maximumEvidenceAge, !toleratesMissingEvidence {
            try block(.staleEvidence, at: time)
        }
        lastFrame = packet.frameID
        lastCapture = packet.capturedAt
        settlingStart = settlingStart ?? packet.capturedAt
        distinctSamples = min(2, distinctSamples + 1)
        blocker = nil
        if phase == .running || phase == .countdown { return }
        phase = distinctSamples >= 2 && packet.capturedAt - (settlingStart ?? packet.capturedAt) >= policy.settlingDuration
            ? .ready : .settling
    }

    /// Called by a source/host update signal, including when no new body frame arrives.
    mutating func evaluate(at time: Double) throws {
        try validateTime(time)
        guard phase != .restartRequired else { return }
        if manualPause { try block(.manualPause, at: time); return }
        guard let policy, let lastCapture else { return }
        guard time >= lastCapture, time - lastCapture < policy.maximumEvidenceAge || toleratesMissingEvidence else {
            try block(.staleEvidence, at: time); return
        }
        if phase == .countdown, let deadline = countdownDeadline, time >= deadline {
            if clock == nil { clock = try GameClock(sourceTime: time) }
            else { try clock?.resume(at: time) }
            countdownDeadline = nil
            phase = .running
        } else if phase == .running { try clock?.advance(to: time) }
    }

    /// Explicit initial/continue request. Production wiring still needs the approved plan/policy.
    mutating func beginCountdown(at time: Double) throws {
        try evaluate(at: time)
        guard phase == .ready, !manualPause, let policy else {
            throw LaserDataError.invalidValue("live input is not ready for countdown")
        }
        try requireLaserValue((time + policy.countdownDuration).isFinite, "countdown deadline")
        countdownDeadline = time + policy.countdownDuration
        phase = .countdown
    }

    mutating func setManualPause(_ paused: Bool, at time: Double) throws {
        try validateTime(time)
        guard phase != .restartRequired else { return }
        manualPause = paused
        if paused { try block(.manualPause, at: time) }
        else {
            evidenceCutover = max(evidenceCutover ?? time, time)
            blocker = .staleEvidence
            phase = clock == nil ? .blocked(.staleEvidence) : .paused
        }
    }

    mutating func invalidateBinding(at time: Double) throws {
        try validateTime(time)
        guard phase != .restartRequired else { return }
        try block(.binding, at: time)
    }

    mutating func invalidateMeasurements(at time: Double) throws {
        try validateTime(time)
        guard phase != .restartRequired else { return }
        try block(.measurements, at: time)
    }

    mutating func invalidatePresentation(at time: Double) throws {
        try validateTime(time)
        guard phase != .restartRequired else { return }
        try block(.presentation, at: time)
    }

    func capturedGameTime(for packet: BodySnapshot) -> Double? {
        guard phase == .running, context?.accepts(packet) == true else { return nil }
        return clock?.gameTime(forCaptureTime: packet.capturedAt)
    }

    mutating func requireRestart() {
        phase = .restartRequired
        blocker = .source
        countdownDeadline = nil
        resetEvidence()
    }

    private mutating func block(_ reason: LaserLiveReadinessBlocker, at time: Double) throws {
        if clock?.isRunning == true { try clock?.pause(at: time) }
        evidenceCutover = max(evidenceCutover ?? time, time)
        resetEvidence()
        countdownDeadline = nil
        blocker = reason
        phase = clock == nil ? .blocked(reason) : .paused
    }

    private mutating func resetEvidence() {
        lastFrame = nil; lastCapture = nil; settlingStart = nil; distinctSamples = 0
    }

    private mutating func validateTime(_ time: Double) throws {
        try requireLaserValue(time.isFinite && time >= lastEvaluation, "monotonic live host time")
        lastEvaluation = time
    }
}
