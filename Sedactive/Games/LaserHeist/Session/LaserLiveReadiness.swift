import Foundation

/// Explicit review inputs, never copied from replay tuning or used as production defaults.
nonisolated struct LaserLiveTimingPolicy: Equatable, Sendable {
    let settlingDuration: Double
    let maximumEvidenceAge: Double
    let countdownDuration: Double
    /// How long admitted evidence may be missing (a pose dropout during a jump, one landmark
    /// below confidence, a player briefly unconfirmed) before readiness blocks: while RUNNING,
    /// this grace; while settling, ready or counting down, `maximumEvidenceAge`. Such a frame is
    /// simply not admitted (the judge sees no sample, so a crossing then is UNAVAILABLE, never
    /// CLEAR); it no longer resets settling or aborts the countdown. 0: the strict rule (any such
    /// frame blocks at once).
    let trackingGrace: Double
    let preservesCountdownOnTrackingFlicker: Bool

    init(settlingDuration: Double, maximumEvidenceAge: Double, countdownDuration: Double,
         trackingGrace: Double = 0, preservesCountdownOnTrackingFlicker: Bool? = nil) throws {
        try requireLaserValue(settlingDuration.isFinite && settlingDuration >= 0
            && maximumEvidenceAge.isFinite && maximumEvidenceAge > 0
            && countdownDuration.isFinite && countdownDuration > 0
            && trackingGrace.isFinite && trackingGrace >= 0, "live timing policy")
        self.settlingDuration = settlingDuration
        self.maximumEvidenceAge = maximumEvidenceAge
        self.countdownDuration = countdownDuration
        self.trackingGrace = trackingGrace
        self.preservesCountdownOnTrackingFlicker = preservesCountdownOnTrackingFlicker ?? (trackingGrace > 0)
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
    /// The session holds the clock still while RUNNING for a scripted scene (the final vault
    /// entry). Any block or pause ends the hold; the session holds again once running.
    private(set) var isClockHeld = false
    /// Frames not admitted but tolerated (a flicker), not a blocker (diagnostics).
    private(set) var skippedFrames = 0
    var gameTime: Double { clock?.gameTime ?? 0 }
    var countdownRemaining: Double? {
        guard phase == .countdown, let countdownDeadline else { return nil }
        return max(0, countdownDeadline - lastEvaluation)
    }

    /// The players whose evidence admits the round: both, or P1 alone in a DEBUG Solo Test.
    let roster: [PlayerID]
    /// Whether a frame that cannot be admitted (missing or invalid measurement, unconfirmed pair)
    /// is skipped rather than blocking at `time`: within the tracking grace of the last admitted
    /// capture while RUNNING, within `maximumEvidenceAge` while settling, ready or counting down
    /// (iPad, 12 November 2026: in co-op twelve measurements must all be valid in one frame, and
    /// single-frame flickers kept restarting settling and aborting the countdown). Sustained loss
    /// still blocks, as stale evidence.
    private func toleratesMissingEvidence(at time: Double) -> Bool {
        guard let policy, let lastCapture else { return false }
        switch phase {
        case .running: return time - lastCapture < policy.trackingGrace
        case .settling, .ready, .countdown:
            return policy.preservesCountdownOnTrackingFlicker && time - lastCapture < policy.maximumEvidenceAge
        default: return false
        }
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
        guard bindingConfirmed else {
            if toleratesMissingEvidence(at: time) { skippedFrames += 1 } else { try block(.binding, at: time) }
            return
        }
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
            // WRISTS ARE ACTION EVIDENCE (PROPOSED by Kevin, 13 Nov 2026 — needs Jevon's review): a
            // hidden wrist (a duck with the hands behind the body) no longer pauses the round. The
            // DUCK judge still needs both wrists (UNAVAILABLE without them, never a free CLEAR) and
            // the wall consoles and diamonds still need their own fresh wrists (no press). Readiness
            // keeps reliable tracking, the head, both soles and the jump state.
            return sample.trackingStatus == .reliable
                && [sample.geometry.crownY, sample.geometry.leftSoleY, sample.geometry.rightSoleY]
                    .allSatisfy { $0.validity == .valid }
                && sample.jumpState.validity == .valid
        }) else {
            if toleratesMissingEvidence(at: time) { skippedFrames += 1 } else { try block(.measurements, at: time) }
            return
        }
        guard let policy else { try block(.timingPolicy, at: time); return }
        guard packet.capturedAt <= time, time - packet.capturedAt < policy.maximumEvidenceAge else {
            if !toleratesMissingEvidence(at: time) { try block(.staleEvidence, at: time) }; return
        }
        if let evidenceCutover, packet.capturedAt <= evidenceCutover { return }
        if manualPause { try block(.manualPause, at: time); return }
        if let lastCapture, packet.capturedAt - lastCapture >= policy.maximumEvidenceAge, !toleratesMissingEvidence(at: time) {
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
        guard time >= lastCapture, time - lastCapture < policy.maximumEvidenceAge || toleratesMissingEvidence(at: time) else {
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

    /// The pair is not confirmed now. A RUNNING round keeps running through the tracking grace
    /// (nothing is admitted meanwhile; the grace then runs out as stale evidence).
    mutating func invalidateBinding(at time: Double) throws {
        try validateTime(time)
        guard phase != .restartRequired, !toleratesMissingEvidence(at: time) else { return }
        try block(.binding, at: time)
    }

    /// The tracker can no longer vouch for a player's identity: pause at once (no grace), keeping
    /// the round. Resumes only through fresh confirmed evidence, settling and the countdown.
    mutating func requireIdentityRecovery(at time: Double) throws {
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

    /// Stops game time at the last evaluated host time while staying RUNNING: evidence rules
    /// still apply, but no capture maps to game time until `releaseClock` starts a new epoch.
    mutating func holdClock() throws {
        guard phase == .running, !isClockHeld, clock?.isRunning == true else { return }
        try clock?.pause(at: lastEvaluation)
        isClockHeld = true
    }

    /// Ends a hold: game time continues from where it stopped; captures from before `time` never count.
    mutating func releaseClock(at time: Double) throws {
        try validateTime(time)
        guard phase == .running, isClockHeld else { return }
        try clock?.resume(at: time)
        isClockHeld = false
    }

    func capturedGameTime(for packet: BodySnapshot) -> Double? {
        guard phase == .running, context?.accepts(packet) == true else { return nil }
        return clock?.gameTime(forCaptureTime: packet.capturedAt)
    }

    mutating func requireRestart() {
        phase = .restartRequired
        isClockHeld = false
        blocker = .source
        countdownDeadline = nil
        resetEvidence()
    }

    private mutating func block(_ reason: LaserLiveReadinessBlocker, at time: Double) throws {
        if clock?.isRunning == true { try clock?.pause(at: time) }
        isClockHeld = false
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
