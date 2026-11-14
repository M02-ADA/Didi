import Foundation
import Testing
@testable import Sedactive

/// POSE-FIRST CANDIDATE (Kevin, 14 November 2026; DEBUG `-trackingCandidate`). Each test runs the
/// candidate next to today's production rule, so the difference is explicit. Synthetic only: real
/// accuracy needs the iPad.
nonisolated struct PoseFirstCandidateTests {
    typealias E = LiveBodyEstimateTests
    typealias F = TrackingFixtures

    // MARK: Producer — presence-held measurement and the conservative crown

    /// A body with shoulders (y), nose, wrists and ankles; hips optional (hidden in a deep squat).
    static func body(nose: Double, shoulders: Double, hips: Double? = 0.5, wrists: Double = 0.5,
                     wristConfidence: Double = 0.9) -> PoseCandidate {
        var j: [BodyJoint: PoseJoint] = [
            .nose: .init(x: 0.5, y: nose, confidence: 0.9),
            .leftShoulder: .init(x: 0.44, y: shoulders, confidence: 0.9), .rightShoulder: .init(x: 0.56, y: shoulders, confidence: 0.9),
            .leftWrist: .init(x: 0.42, y: wrists, confidence: wristConfidence), .rightWrist: .init(x: 0.58, y: wrists, confidence: wristConfidence),
            .leftAnkle: .init(x: 0.46, y: 0.13, confidence: 0.9), .rightAnkle: .init(x: 0.54, y: 0.13, confidence: 0.9)]
        if let hips {
            j[.leftHip] = .init(x: 0.47, y: hips, confidence: 0.9); j[.rightHip] = .init(x: 0.53, y: hips, confidence: 0.9)
        }
        return PoseCandidate(candidateID: 10, joints: j, maskTopImageY: nil, maskBottomImageY: nil,
                             leftFootBottomImageY: nil, rightFootBottomImageY: nil, maskAssociation: .unavailable)
    }
    static let presenceHeld = PlayerTrackingSlotResult(state: .uncertain, reason: .missingOrWeak, candidateID: nil,
        cost: nil, requiresRebind: false, lastConfirmedAt: 0, presentCandidateID: 10)

    @Test func aHiddenHipsSquatIsMeasuredFromThePresenceHeldBodyOnlyInTheCandidate() throws {
        let c = try E.calibration()
        let squat = Self.body(nose: 0.55, shoulders: 0.45, hips: nil)
        // Production: an uncertain slot blanks everything, although nose, wrists and ankles were seen.
        let today = BodyMeasurementExtractor.sample(id: .player1, candidate: squat, slot: Self.presenceHeld,
                                                    calibration: c, layout: E.layout)
        #expect(today.geometry.crownY.validity == .identityUncertain && today.trackingStatus == .uncertain)
        // Candidate: measured, marked presence-held, each landmark on its own; hips stay missing.
        var head = HeadHeightReference()
        let s = BodyMeasurementExtractor.candidateSample(id: .player1, candidates: [squat], slot: Self.presenceHeld,
                                                         calibration: c, layout: E.layout, head: &head)
        try s.validate()
        #expect(s.trackingStatus == .uncertain && s.isPresenceHeld && s.isPresent)
        #expect(abs((s.geometry.crownY.value ?? 0) - (0.55 + 0.1 - 0.1) * 2) < 1e-9)
        #expect(s.geometry.leftWristY.validity == .valid && s.geometry.leftSoleY.validity == .valid)
        #expect(s.geometry.centerX.validity != .valid, "hips are not invented")
        // Never for a player whose identity is lost, ambiguous, or not held by presence.
        for slot in [PlayerTrackingSlotResult(state: .uncertain, reason: .missingOrWeak, candidateID: nil, cost: nil,
                                              requiresRebind: false, lastConfirmedAt: 0),
                     PlayerTrackingSlotResult(state: .uncertain, reason: .ambiguous, candidateID: nil, cost: nil,
                                              requiresRebind: true, lastConfirmedAt: 0, presentCandidateID: 10),
                     PlayerTrackingSlotResult(state: .lost, reason: .expired, candidateID: nil, cost: nil,
                                              requiresRebind: true, lastConfirmedAt: 0)] {
            var h = HeadHeightReference()
            let blocked = BodyMeasurementExtractor.candidateSample(id: .player1, candidates: [squat], slot: slot,
                                                                   calibration: c, layout: E.layout, head: &h)
            #expect(!blocked.isPresent && blocked.geometry.crownY.validity != .valid, "\(slot)")
        }
        // An uncertain sample can never carry valid measurements unless presence-held.
        var forged = s; forged.presenceOnly = nil
        #expect(throws: (any Error).self) { try forged.validate() }
    }

    @Test func aHeadBowCannotLowerTheCandidateCrownButASquatDoes() throws {
        let c = try E.calibration()
        var head = HeadHeightReference()
        func crown(nose: Double, shoulders: Double) -> Double? {
            BodyMeasurementExtractor.candidateSample(id: .player1, candidates: [Self.body(nose: nose, shoulders: shoulders)],
                slot: E.tracking, calibration: c, layout: E.layout, head: &head).geometry.crownY.value
        }
        for _ in 0..<30 { _ = crown(nose: 0.8, shoulders: 0.7) } // upright: learns shoulder→nose 0.1 (0.2 game units)
        // Standing crown: (0.9 − 0.1) × 2 = 1.6 game units.
        #expect(abs((crown(nose: 0.8, shoulders: 0.7) ?? 0) - 1.6) < 1e-9)
        // Head bow: the nose drops 0.15, the shoulders do not. Production would read 1.3.
        let today = BodyMeasurementExtractor.sample(id: .player1, candidate: Self.body(nose: 0.65, shoulders: 0.7),
                                                    slot: E.tracking, calibration: c, layout: E.layout)
        #expect(abs((today.geometry.crownY.value ?? 0) - 1.3) < 1e-9)
        #expect(abs((crown(nose: 0.65, shoulders: 0.7) ?? 0) - 1.6) < 1e-9, "the shoulders keep the crown up")
        // A real squat lowers nose and shoulders together: the crown drops in both estimates.
        #expect(abs((crown(nose: 0.55, shoulders: 0.45) ?? 0) - 1.1) < 1e-9)
        // Bowed frames never teach the reference (it stays the upright 0.2).
        for _ in 0..<200 { _ = crown(nose: 0.65, shoulders: 0.7) }
        #expect(abs((crown(nose: 0.65, shoulders: 0.7) ?? 0) - 1.6) < 1e-9)
    }

    // MARK: Judge — presence-held evidence, same geometry

    @Test func onlyTheCandidateJudgesAPresenceHeldSampleWithTheSameRule() throws {
        let scenario = try LaserReplayScenarios.make()[0]
        let target = try LaserTarget(playerID: .player1, calibrationRevision: 1, requiredMove: .duck,
                                     beam: LaserBeamBand(lowerY: 1, upperY: 1.25), warningTime: 7, crossingTime: 10)
        func v(_ x: Double) throws -> EstimatedScalar { try EstimatedScalar(value: x, validity: .valid) }
        func held(crown: Double) throws -> BodySnapshot {
            var sample = try PlayerBodySample(playerID: .player1, calibrationRevision: 1, trackingStatus: .uncertain,
                geometry: BodyGeometry(crownY: v(crown), leftWristY: v(0.4), rightWristY: v(0.4), leftSoleY: v(0),
                                       rightSoleY: v(0), centerX: EstimatedScalar(value: nil, validity: .missingLandmarks)),
                jumpState: JumpState(phase: .grounded, validity: .valid))
            sample.presenceOnly = true
            var players = scenario.input.records.first?.snapshot?.players ?? [:]
            players[.player1] = sample
            return BodySnapshot(sessionGeneration: scenario.input.configuration.sessionGeneration, frameID: 1,
                                capturedAt: 110, cameraGeometryRevision: 1, players: players)
        }
        let context = BodyInputContext(sessionGeneration: scenario.input.configuration.sessionGeneration,
            cameraGeometryRevision: 1, calibrationRevisions: [.player1: 1, .player2: 1], cutovers: [:], isActive: true)
        func judge(_ crown: Double, candidate: Bool) throws -> Judgement? {
            try LaserCollisionJudge(acceptsPresenceHeldEvidence: candidate).judge(target: target,
                selection: .selected(LaserBodyEvidence(snapshot: held(crown: crown), capturedGameTime: 10, arrivedGameTime: 10.1)),
                clearanceMargin: 0.125, context: context)
        }
        #expect(try judge(0.5, candidate: false) == .unavailable(.invalidEvidence(.crown, .identityUncertain)), "production")
        #expect(try judge(0.5, candidate: true) == .clear)
        #expect(try judge(0.9, candidate: true) == .hit(.insufficientClearance), "same margin, same geometry")
    }

    // MARK: Tracker — identity safety is unchanged

    private func presence(_ hidden: [PoseCandidate]) throws -> PlayerTrackingSnapshot {
        var tracker = try F.tracker(policy: B2bExperimentalPolicyV1.value)
        var t = 1.0, frame: UInt64 = 0
        for _ in 0..<10 { frame += 1; t += 1.0 / 30; _ = try tracker.process(F.input(frame, t, F.pair)) }
        var during = tracker.snapshot
        for _ in 0..<45 { frame += 1; t += 1.0 / 30; during = try tracker.process(F.input(frame, t, hidden)) }
        return during
    }

    @Test func onlyAnUnambiguousPartialBodyIsReportedAsPresent() throws {
        let squat = F.candidate(10, x: 0.75, y: 0.4, missing: [.leftHip, .rightHip])
        let held = try presence([squat, F.candidate(20, x: 0.25)])
        #expect(held.player1.state == .uncertain && held.player1.presentCandidateID == 10 && !held.player1.requiresRebind)
        #expect(held.player2.presentCandidateID == nil, "a tracked player has a match, not presence")
        // Two partial bodies near P1: ambiguous presence is no presence.
        let twin = F.candidate(11, x: 0.78, y: 0.4, missing: [.leftHip, .rightHip])
        #expect(try presence([squat, twin, F.candidate(20, x: 0.25)]).player1.presentCandidateID == nil)
        // P1 gone: nothing present.
        #expect(try presence([F.candidate(20, x: 0.25)]).player1.presentCandidateID == nil)
        // A partial body at the other player's place is never P1.
        let other = F.candidate(30, x: 0.27, y: 0.4, missing: [.leftHip, .rightHip])
        #expect(try presence([other, F.candidate(20, x: 0.25)]).player1.presentCandidateID == nil)
    }

    // MARK: JUMP estimator — take-off needs the hips, a held rise is not a flight

    /// Steps the estimator on a 30 fps track of (sole lift, hip height) in game units; returns the
    /// airborne frames' times. Standing height 1.6, floor 0.
    private func airborne(_ track: [(t: Double, sole: Double, hip: Double)], candidate: Bool, height: Double = 1.6) -> [Double] {
        estimate(track, candidate: candidate, height: height).airborne
    }
    /// Standing hip 0.8 over a floor at 0 (standing leg 0.8). Returns the airborne capture times and the final floor.
    private func estimate(_ track: [(t: Double, sole: Double, hip: Double)], candidate: Bool,
                          height: Double = 1.6) -> (airborne: [Double], baseline: Double) {
        var estimator = LiveJumpEstimator()
        var frame: UInt64 = 0, out: [Double] = []
        for p in track {
            frame += 1
            let state = estimator.step(frameID: frame, capturedAt: p.t, leftSole: p.sole, rightSole: p.sole,
                standingLeftSole: 0, standingRightSole: 0, standingHeight: height, calibrationRevision: 1,
                hipY: p.hip, standingHip: 0.8, candidateRules: candidate)
            if state.phase == .airborne { out.append(p.t) }
        }
        return (out, estimator.baseline)
    }
    private func track(_ seconds: Double, _ f: (Double) -> (sole: Double, hip: Double)) -> [(t: Double, sole: Double, hip: Double)] {
        (0..<Int(seconds * 30)).map { i in let t = Double(i) / 30; let v = f(t); return (t, v.sole, v.hip) }
    }
    /// 1 s standing, then a profile from t = 1.
    private func after(_ t: Double, _ rest: (Double) -> (sole: Double, hip: Double)) -> (sole: Double, hip: Double) {
        t < 1 ? (0, 0.8) : rest(t - 1)
    }
    /// A hop of `height` lasting `flight` s, hips moving with the soles (no dip needed any more).
    static func hop(_ u: Double, height: Double = 0.15, flight: Double = 0.5) -> (sole: Double, hip: Double) {
        let h = u < flight ? max(0, height * sin(.pi * u / flight)) : 0
        return (h, 0.8 + h)
    }

    @Test(arguments: [(0.07, 0.3), (0.15, 0.5)])
    func smallAndNormalJumpsAreAirborneInBoth(height: Double, flight: Double) {
        // iPad logs: the smallest real jumps peaked ~0.07–0.09 and stayed above the take-off line ~0.2 s.
        let jump = track(3) { t in self.after(t) { Self.hop($0, height: height, flight: flight) } }
        #expect(!airborne(jump, candidate: false).isEmpty)
        #expect(!airborne(jump, candidate: true).isEmpty, "no dip is required any more")
    }

    @Test func aJumpOutOfAHeldSquatIsAirborne() {
        let jump = track(4) { t in
            if t < 1 { return (0, 0.8) }
            if t < 3 { return (0, 0.55) }
            let u = t - 3
            if u < 0.2 { return (0, 0.55 + 0.25 * u / 0.2) }
            return Self.hop(u - 0.2)
        }
        #expect(!airborne(jump, candidate: true).isEmpty)
    }

    @Test func aHeldTiptoeStopsBeingAirborneOnlyInTheCandidate() {
        // A quick 8 cm rise (above the 3 % entry) held for 2 s, hips rising with it.
        let tiptoe = track(4) { t in self.after(t) { u in let h = min(0.08, 0.8 * u); return (h, 0.8 + h) } }
        let today = airborne(tiptoe, candidate: false), candidate = airborne(tiptoe, candidate: true)
        #expect((today.last ?? 0) > 3.5, "production: still 'airborne' after holding for 2.5 s")
        #expect(!candidate.isEmpty && (candidate.last ?? 0) - (candidate.first ?? 0) <= LiveJumpEstimator.maximumFlight + 0.04,
                "candidate: the airborne state ends after a credible flight")
    }

    @Test func aLandingOnAShiftedFootPositionEndsTheFlight() {
        // iPad, 14 Nov 2026 (an "early" jump): a 0.18 hop that landed with the ankles settling
        // 0.03 above the old floor, above the 1.5 % exit line, stayed "airborne" 0.4 s after
        // touching down, so its run reached the crossing. Coming down, the flight now ends below
        // the take-off line (3 % = 0.048 here).
        let jump = track(3) { t in self.after(t) { u in
            if u < 0.4 { let h = 0.18 * sin(.pi * u / 0.4); return (max(h, u > 0.2 ? 0.03 : 0), 0.8 + h) }
            return (0.03, 0.83)
        } }
        let today = airborne(jump, candidate: false), candidate = airborne(jump, candidate: true)
        #expect((today.last ?? 0) > 1.6, "production: still 'airborne' on the new floor")
        #expect(!candidate.isEmpty && (candidate.last ?? 9) < 1.6, "candidate: the still landing ends the flight within 0.15 s")
    }

    @Test func aQuickTiptoeLooksLikeASmallHopKnownLimit() {
        // iPad, 14 Nov 2026: quick tiptoes (0.08–0.12, 8–11 frames above the line) overlapped real
        // small jumps. Recorded as the rule's known limit, not a pass.
        let tiptoe = track(3) { t in self.after(t) { Self.hop($0, height: 0.09, flight: 0.35) } }
        #expect(!airborne(tiptoe, candidate: true).isEmpty)
    }

    @Test func anAnkleOnlyRiseWithStillHipsIsNoTakeoffInTheCandidate() {
        let jitter = track(3) { t in self.after(t) { u in (u < 0.3 ? min(0.08, 0.8 * u) : 0, 0.8) } }
        #expect(!airborne(jitter, candidate: false).isEmpty, "production accepts the ankles alone")
        #expect(airborne(jitter, candidate: true).isEmpty)
    }

    @Test func aSquatRecoveryIsNeverAJump() {
        let recovery = track(3) { t in self.after(t) { u in (0, 0.5 + min(0.3, u)) } }
        #expect(airborne(recovery, candidate: false).isEmpty && airborne(recovery, candidate: true).isEmpty)
    }

    // MARK: Floor re-anchoring (reproductions of the iPad retest, 14 Nov 2026)

    /// 1 s standing, a 2.5 s squat with the soles reading 0.15 low (as the logs imply), 1.2 s
    /// standing, then `jump` (raw sole heights at 30 fps, hips following them), then still.
    private func afterASquat(_ jump: [Double], still: Double = 0.002, standing: Double = 1.2) -> [(t: Double, sole: Double, hip: Double)] {
        var values: [(Double, Double)] = []
        for _ in 0..<30 { values.append((0, 0.8)) }
        // Down and up over 0.3 s each, as people squat (a one-frame squat would read as jitter).
        for i in 1...9 { let s = Double(i) / 9; values.append((-0.15 * s, 0.8 - 0.3 * s)) }
        for _ in 0..<57 { values.append((-0.15, 0.5)) }
        for i in 1...9 { let s = 1 - Double(i) / 9; values.append((-0.15 * s, 0.8 - 0.3 * s)) }
        for _ in 0..<Int(standing * 30) { values.append((0, 0.8)) }
        for r in jump { values.append((r, 0.8 + max(0, r))) }
        for _ in 0..<30 { values.append((still, 0.8)) }
        return values.enumerated().map { (Double($0.offset) / 30, $0.element.0, $0.element.1) }
    }
    /// The logged raw sole heights (relative to the calibrated floor) of the two retest failures.
    static let loggedEarlyJump = [0.062, 0.102, 0.118, 0.129, 0.120, 0.101, 0.067, 0.039, 0.017, -0.003, 0.000, 0.003, 0.000]
    static let loggedSmallJump = [0.000, -0.002, -0.002, -0.002, -0.001, -0.001, 0.000, 0.000, 0.002, 0.001, 0.003, 0.004, 0.003,
                                  0.009, 0.026, 0.033, 0.040, 0.043, 0.047, 0.032, 0.030, 0.015, 0.003, -0.003, 0.000]

    @Test func anEarlyJumpLandingOnTheRealFloorAfterASquatEndsAtTheLanding() {
        // iPad: the floor followed the squat down; the landing back on the real floor read 0.097
        // "airborne" for 0.4 s and an early jump scored CLEAR.
        let track = afterASquat(Self.loggedEarlyJump)
        let jumpStart = (30 + 75 + 36) / 30.0, landing = jumpStart + 9.0 / 30 // raw back to −0.003
        let today = airborne(track, candidate: false, height: 1.4)
        let candidate = estimate(track, candidate: true, height: 1.4)
        #expect((today.last ?? 0) > landing + 0.4, "production: still 'airborne' long after landing")
        #expect(!candidate.airborne.isEmpty && (candidate.airborne.last ?? 9) <= landing + 0.05, "candidate: ends at the landing")
        #expect(abs(candidate.baseline) < 0.01, "the floor is the real one")
    }

    @Test func theLoggedSmallJumpNowTakesOffButStaysTooBriefKnownLimit() {
        // iPad: standing on the real floor read 0.07 "lifted"; a 4.7 cm jump (3.4 % of height) rose
        // only ~0.03 above it and never took off. On the real floor it takes off, but it is above
        // the 3 % take-off line for one frame: its airborne run (~0.067 s) is shorter than the
        // 0.1 s minimum, inside the jitter range logged. Recorded as the rule's limit, not tuned away.
        let track = afterASquat(Self.loggedSmallJump)
        let candidate = airborne(track, candidate: true, height: 1.4)
        #expect(!candidate.isEmpty, "candidate: take-off recognised")
        #expect((candidate.last ?? 0) - (candidate.first ?? 0) < PoseFirstCandidate.jumpMinimumFlight)
        // The same body, 6 cm up (4.3 % of height): long enough.
        let bigger = afterASquat(Self.loggedSmallJump.map { $0 > 0.02 ? $0 + 0.015 : $0 })
        let run = airborne(bigger, candidate: true, height: 1.4)
        #expect((run.last ?? 0) - (run.first ?? 0) >= PoseFirstCandidate.jumpMinimumFlight - 1e-6)
    }

    @Test func aStepCloserReanchorsTheFloorBeforeTheNextJump() {
        // Upright, the whole body reads 0.06 lower (a step toward the camera); 0.6 s later, a small hop.
        let track = track(3) { t in
            if t < 1 { return (0, 0.8) }
            if t < 1.6 { return (-0.06, 0.74) }
            let h = Self.hop(t - 1.6, height: 0.07, flight: 0.3)
            return (h.sole - 0.06, h.hip - 0.06)
        }
        #expect(airborne(track, candidate: false).isEmpty, "production: the old floor hides the hop")
        #expect(!airborne(track, candidate: true).isEmpty)
    }

    @Test func aRealJumpsApexIsNeverALanding() {
        // A 0.5 s, 15 cm hop whose apex holds within 1 % of height for 0.1 s: one continuous flight.
        let track = track(3) { t in self.after(t) { u in
            var h = u < 0.5 ? max(0, 0.15 * sin(.pi * u / 0.5)) : 0
            if (0.2...0.3).contains(u) { h = 0.15 }
            return (h, 0.8 + h)
        } }
        let times = airborne(track, candidate: true)
        let gaps = zip(times, times.dropFirst()).map { $1 - $0 }
        #expect(!times.isEmpty && gaps.allSatisfy { $0 < 0.05 }, "no landing at the apex")
        #expect((times.last ?? 0) - (times.first ?? 0) > 0.3)
    }

    @Test func aSquatNeverMovesTheCandidateFloor() {
        let track = track(4) { t in t < 1 ? (0, 0.8) : (-0.15, 0.5) }
        #expect(abs(estimate(track, candidate: true).baseline) < 1e-9)
        #expect(estimate(track, candidate: false).baseline < -0.1, "production follows the squat down")
    }

    @Test func aTrackingGapNeverReanchorsAcrossIt() {
        var estimator = LiveJumpEstimator()
        var frame: UInt64 = 0
        func step(_ t: Double, _ sole: Double?, hip: Double = 0.8) {
            frame += 1
            _ = estimator.step(frameID: frame, capturedAt: t, leftSole: sole, rightSole: sole, standingLeftSole: 0,
                standingRightSole: 0, standingHeight: 1.6, calibrationRevision: 1, hipY: hip, standingHip: 0.8,
                candidateRules: true)
        }
        var t = 0.0
        for _ in 0..<30 { step(t, 0); t += 1.0 / 30 }
        for _ in 0..<30 { step(t, nil); t += 1.0 / 30 }          // 1 s without feet
        for _ in 0..<3 { step(t, 0.05); t += 1.0 / 30 }          // back, elsewhere: 0.1 s still
        #expect(estimator.baseline < 0.01, "not re-anchored on three frames after the gap (only the slow drift moved)")
        for _ in 0..<6 { step(t, 0.05); t += 1.0 / 30 }          // still for 0.27 s
        #expect(abs(estimator.baseline - 0.05) < 1e-9, "re-anchored once still and upright")
    }

    // MARK: JUMP judge — a timed jump event

    /// Judges one low laser crossing at game time 10 (window 9.65…10.25, deadline 10.35) from 30 fps
    /// captures 9.6…10.4: `airborne(t)` gives each capture's phase, `soles(t)` its sole validity.
    private func jumpVerdict(airborne: (Double) -> Bool, soles: (Double) -> Bool = { _ in true },
                             restingSole: Double = 0, candidate: Bool = true) throws -> Judgement? {
        let scenario = try LaserReplayScenarios.make()[0]
        let generation = scenario.input.configuration.sessionGeneration
        let target = try LaserTarget(playerID: .player1, calibrationRevision: 1, requiredMove: .jump,
                                     beam: LaserBeamBand(lowerY: 0.005, upperY: 0.02), warningTime: 7, crossingTime: 10)
        let context = BodyInputContext(sessionGeneration: generation, cameraGeometryRevision: 1,
            calibrationRevisions: [.player1: 1, .player2: 1], cutovers: [:], isActive: true)
        let timing = try LaserEvidenceTiming(windowBefore: 0.35, windowAfter: 0.25, deliveryAllowance: 0.1)
        func v(_ x: Double) throws -> EstimatedScalar { try EstimatedScalar(value: x, validity: .valid) }
        let missing = try EstimatedScalar(value: nil, validity: .lowConfidence)
        var history: [LaserBodyEvidence] = []
        for i in 0..<25 {
            let t = 9.6 + Double(i) / 30
            let up = airborne(t), seen = soles(t)
            let sole = restingSole + (up ? 0.06 : 0) // a small jump: 6 cm above this player's floor
            let sample = try PlayerBodySample(playerID: .player1, calibrationRevision: 1, trackingStatus: .reliable,
                geometry: BodyGeometry(crownY: v(1.5), leftWristY: v(0.8), rightWristY: v(0.8),
                    leftSoleY: seen ? v(sole) : missing, rightSoleY: seen ? v(sole) : missing,
                    centerX: EstimatedScalar(value: 0, validity: .valid)),
                jumpState: seen ? JumpState(phase: up ? .airborne : .grounded, validity: .valid)
                                : JumpDetector.unavailable(.missingLandmarks))
            var players = scenario.input.records.first?.snapshot?.players ?? [:]
            players[.player1] = sample
            let snapshot = BodySnapshot(sessionGeneration: generation, frameID: UInt64(i + 1),
                                        capturedAt: 100 + t, cameraGeometryRevision: 1, players: players)
            history.append(LaserBodyEvidence(snapshot: snapshot, capturedGameTime: t, arrivedGameTime: t + 0.05))
        }
        let judge = LaserCollisionJudge()
        if candidate {
            return judge.judgeJumpEvent(target: target, history: history, timing: timing, context: context,
                minimumFlight: PoseFirstCandidate.jumpMinimumFlight, tolerance: PoseFirstCandidate.jumpTimingTolerance)
        }
        return try judge.judge(target: target, selection: judge.select(target: target, history: history, timing: timing,
                                                                        context: context), clearanceMargin: 0.005, context: context)
    }

    @Test func aSmallJumpInTheAirAtTheCrossingClears() throws {
        // 0.2 s in the air around the crossing (the smallest real jumps logged).
        #expect(try jumpVerdict(airborne: { (9.93...10.14).contains($0) }) == .clear)
        // A normal 0.4 s jump.
        #expect(try jumpVerdict(airborne: { (9.8...10.2).contains($0) }) == .clear)
    }

    @Test func theFloorIsThePlayersOwnNotTheCalibratedOne() throws {
        // iPad logs: resting soles read −0.02…−0.07 below the calibrated floor. A small jump then
        // never puts the soles above the drawn laser, so production scores HIT; the jump event clears.
        let jump: (Double) -> Bool = { (9.9...10.1).contains($0) }
        #expect(try jumpVerdict(airborne: jump, restingSole: -0.05, candidate: false) == .hit(.insufficientClearance))
        #expect(try jumpVerdict(airborne: jump, restingSole: -0.05, candidate: true) == .clear)
    }

    @Test func briefJitterIsNoJump() throws {
        // Two airborne captures (0.033 s): below the 0.1 s minimum flight.
        #expect(try jumpVerdict(airborne: { (9.99...10.03).contains($0) }) == .hit(.notAirborne))
    }

    @Test func aJumpThatEndsTooEarlyOrStartsTooLateIsAHit() throws {
        // Both in the 0.6 s evidence window, neither in the air at the crossing (± 0.05 s).
        #expect(try jumpVerdict(airborne: { (9.66...9.90).contains($0) }) == .hit(.notAirborne), "landed 0.1 s early")
        #expect(try jumpVerdict(airborne: { (10.10...10.25).contains($0) }) == .hit(.notAirborne), "took off 0.1 s late")
        // Just inside the tolerance on each side.
        #expect(try jumpVerdict(airborne: { (9.80...9.97).contains($0) }) == .clear, "landed 0.03 s before")
        #expect(try jumpVerdict(airborne: { (10.03...10.2).contains($0) }) == .clear, "took off 0.03 s after")
    }

    @Test func aBriefSoleDropoutInsideTheFlightDoesNotSplitIt() throws {
        let flight: (Double) -> Bool = { (9.9...10.1).contains($0) }
        #expect(try jumpVerdict(airborne: flight, soles: { !(10.0...10.04).contains($0) }) == .clear)
        // A grounded capture in the middle does split it into two runs too short to count.
        #expect(try jumpVerdict(airborne: { (9.96...10.03).contains($0) || (10.07...10.13).contains($0) }) == .hit(.notAirborne))
    }

    @Test func noUsableSolesInTheWindowIsUnavailableNeverClear() throws {
        let verdict = try jumpVerdict(airborne: { (9.9...10.1).contains($0) }, soles: { _ in false })
        guard case .unavailable = verdict else { Issue.record("\(String(describing: verdict))"); return }
    }


    // MARK: UNAVAILABLE retry budget

    @Test func unavailableIsUnscoredWithoutPauseUntilTheBudget() {
        var policy = LaserUnavailableRetryPolicy()
        func key(_ p: PlayerID = .player1) -> LaserTargetKey { .init(encounterID: UUID(), attemptID: UUID(), playerID: p) }
        let gap = Judgement.unavailable(.invalidEvidence(.leftWrist, .lowConfidence))
        var verdicts: [(key: LaserTargetKey, judgement: Judgement)] = []
        func add(_ j: Judgement, _ p: PlayerID = .player1, present: Bool = true) -> Bool {
            verdicts.append((key(p), j)); return policy.review(verdicts, isPresent: { _ in present })
        }
        #expect(!add(gap), "the first UNAVAILABLE: unscored, play continues")
        #expect(policy.forgiven.contains(verdicts[0].key.encounterID), "let through: final, never withdrawn later")
        #expect(!add(.clear), "a CLEAR resets the run")
        #expect(!add(gap))
        #expect(add(gap), "two in a row: pause and recover")
        #expect(!policy.forgiven.contains(verdicts.last!.key.encounterID), "the triggering laser is withdrawn and retried")
        policy.resumed()
        #expect(add(gap), "the fourth this round pauses even after a reset run")
        #expect(!add(.hit(.insufficientClearance)), "reviewed verdicts are never counted twice")
        var fresh = LaserUnavailableRetryPolicy()
        let absent = fresh.review([(key(), gap)], isPresent: { _ in false })
        #expect(absent, "an absent player always pauses")
        let pending = fresh.review([(key(.player2), .pending(.awaitingFinalization))], isPresent: { _ in true })
        #expect(!pending)
    }
}

/// Readiness: pause on ABSENCE in the candidate, on any unadmissible frame in production.
@MainActor struct PoseFirstCandidateReadinessTests {
    private let generation = UUID()
    private var context: BodyInputContext {
        BodyInputContext(sessionGeneration: generation, cameraGeometryRevision: 1,
                         calibrationRevisions: [.player1: 1, .player2: 1], cutovers: [:], isActive: true)
    }
    enum P1 { case tracked, presenceHeld, absent }
    private func packet(_ frame: UInt64, _ time: Double, _ p1: P1 = .tracked) throws -> BodySnapshot {
        let base = try LH00TestData.load().records.first!.snapshot!
        let missing = try EstimatedScalar(value: nil, validity: .identityUncertain)
        let players = try base.players.mapValues { s -> PlayerBodySample in
            guard s.playerID == .player1, p1 != .tracked else {
                return PlayerBodySample(playerID: s.playerID, calibrationRevision: 1, trackingStatus: .reliable,
                                        geometry: s.geometry, jumpState: s.jumpState)
            }
            // Hips hidden: head and wrists measured, soles and jump unknown (not admissible).
            let g = s.geometry
            var sample = PlayerBodySample(playerID: s.playerID, calibrationRevision: 1, trackingStatus: .uncertain,
                geometry: p1 == .presenceHeld
                    ? .init(crownY: g.crownY, leftWristY: g.leftWristY, rightWristY: g.rightWristY,
                            leftSoleY: missing, rightSoleY: missing, centerX: missing)
                    : .init(crownY: missing, leftWristY: missing, rightWristY: missing, leftSoleY: missing,
                            rightSoleY: missing, centerX: missing),
                jumpState: JumpDetector.unavailable(.identityUncertain))
            if p1 == .presenceHeld { sample.presenceOnly = true }
            try sample.validate()
            return sample
        }
        return BodySnapshot(sessionGeneration: generation, frameID: frame, capturedAt: time, cameraGeometryRevision: 1, players: players)
    }
    private func running(candidate: Bool) throws -> (LaserLiveReadiness, Double, UInt64) {
        let policy = try LaserLiveTimingPolicy(settlingDuration: 1, maximumEvidenceAge: 0.5, countdownDuration: 3,
            preservesCountdownOnTrackingFlicker: true, absenceGrace: candidate ? PoseFirstCandidate.absenceGrace : nil)
        var value = LaserLiveReadiness(policy: policy)
        var t = 1000.0, frame: UInt64 = 1
        while value.phase != .ready, t < 1003 { try value.observe(packet(frame, t), context: context, bindingConfirmed: true, at: t); t += 1.0 / 30; frame += 1 }
        try value.beginCountdown(at: t)
        while value.phase != .running, t < 1008 { try value.observe(packet(frame, t), context: context, bindingConfirmed: true, at: t); t += 1.0 / 30; frame += 1 }
        #expect(value.phase == .running)
        return (value, t, frame)
    }

    @Test func aHeldSquatKeepsTheCandidateRunningButPausesProduction() throws {
        var (today, t0, f0) = try running(candidate: false)
        try today.observe(packet(f0, t0, .presenceHeld), context: context, bindingConfirmed: true, at: t0)
        #expect(today.phase == .paused, "production: the first frame without soles pauses")

        var (value, t, frame) = try running(candidate: true)
        // 3 s squat with hidden hips: the pair is confirmed only through presence (binding not reliable).
        for _ in 0..<90 {
            try value.observe(packet(frame, t, .presenceHeld), context: context, bindingConfirmed: true, at: t)
            try value.invalidateBinding(at: t)
            try value.evaluate(at: t)
            t += 1.0 / 30; frame += 1
        }
        #expect(value.phase == .running, "present the whole time: no pause")
        // Back up: admitted again, still running, game time kept advancing.
        try value.observe(packet(frame, t), context: context, bindingConfirmed: true, at: t)
        #expect(value.phase == .running && value.gameTime > 2.9)
    }

    @Test func aPlayerWhoLeavesStillPausesTheCandidateAfterTheAbsenceGrace() throws {
        var (value, t, frame) = try running(candidate: true)
        let left = t
        while t - left < PoseFirstCandidate.absenceGrace - 0.05 {
            try value.observe(packet(frame, t, .absent), context: context, bindingConfirmed: false, at: t)
            t += 1.0 / 30; frame += 1
        }
        #expect(value.phase == .running, "a brief dropout is tolerated")
        while t - left < PoseFirstCandidate.absenceGrace + 0.1 {
            try value.observe(packet(frame, t, .absent), context: context, bindingConfirmed: false, at: t)
            t += 1.0 / 30; frame += 1
        }
        #expect(value.phase == .paused, "gone longer than the grace: pause")
        // Identity loss still pauses at once, whatever the grace.
        var (other, t2, _) = try running(candidate: true)
        try other.requireIdentityRecovery(at: t2)
        #expect(other.phase == .paused)
    }
}
