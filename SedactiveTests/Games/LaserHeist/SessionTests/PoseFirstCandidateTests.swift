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

    // MARK: Bent-back legs in the air (21 November 2026; SYNTHETIC tracks, not device data)
    //
    // A tuck jump: the heels fold back toward the buttocks once the feet leave the floor, so the
    // ankle-based soles rise by the flight PLUS the tuck, while the hips rise by the flight alone.

    /// A jump of `height` over `flight` s; the lower legs fold back by up to `tuck` (each side's
    /// share in `sides`) from 0.06 s after take-off until 0.08 s before landing.
    static func tuckJump(_ u: Double, height: Double = 0.12, flight: Double = 0.45, tuck: Double = 0.35,
                         kickAt: Double = 0.06, sides: (left: Double, right: Double) = (1, 1)) -> (left: Double, right: Double, hip: Double) {
        guard u >= 0, u < flight else { return (0, 0, 0.8) }
        let h = height * sin(.pi * u / flight)
        let fold = max(0, sin(.pi * min(1, max(0, (u - kickAt) / (flight - kickAt - 0.08)))))
        return (h + tuck * sides.left * fold, h + tuck * sides.right * fold, 0.8 + h)
    }
    private func twoSoles(_ seconds: Double, _ f: (Double) -> (left: Double?, right: Double?, hip: Double)) -> [Double] {
        var estimator = LiveJumpEstimator()
        var out: [Double] = []
        for i in 0..<Int(seconds * 30) {
            let t = Double(i) / 30, v = f(t)
            let state = estimator.step(frameID: UInt64(i + 1), capturedAt: t, leftSole: v.left, rightSole: v.right,
                standingLeftSole: 0, standingRightSole: 0, standingHeight: 1.6, calibrationRevision: 1,
                hipY: v.hip, standingHip: 0.8, candidateRules: true)
            if state.phase == .airborne { out.append(t) }
        }
        return out
    }
    /// The airborne runs (start, end) in a list of airborne frame times.
    static func runs(_ times: [Double]) -> [(Double, Double)] {
        var out: [(Double, Double)] = []
        for t in times {
            if let last = out.last, t - last.1 < 1.5 / 30 { out[out.count - 1].1 = t } else { out.append((t, t)) }
        }
        return out
    }

    /// (A) The heels kick back as the feet leave the floor (no delay): at the first frame over the
    /// take-off line the soles have already risen far more than the hips.
    @Test func aTuckJumpKickingBackAtTakeOffIsAirborne() {
        let jump = twoSoles(3) { t in let v = Self.tuckJump(t - 1, kickAt: 0); return (v.left, v.right, v.hip) }
        let runs = Self.runs(jump)
        #expect(runs.count == 1 && runs.first.map { $0.1 - $0.0 >= 0.2 } == true, "one flight: \(runs)")
    }

    /// Missing ankles mid-flight keep the existing rule unchanged: a tuck jump survives a 2-frame
    /// dropout (`dropoutFrames`), those frames UNKNOWN.
    @Test func aTuckJumpKeepsItsFlightThroughABriefAnkleDropout() {
        let hidden = (1.0 + 4.0 / 30)...(1.0 + 5.5 / 30)
        let jump = twoSoles(3) { t in
            let v = Self.tuckJump(t - 1, kickAt: 0)
            return hidden.contains(t) ? (nil, nil, v.hip) : (v.left, v.right, v.hip)
        }
        let runs = Self.runs(jump)
        #expect(runs.count == 2 && runs[1].0 - runs[0].1 <= 3.5 / 30, "one flight around the UNKNOWN frames: \(runs)")
    }

    /// A flight survives 4 frames (0.13 s) with no soles at all and resumes when they are seen again,
    /// still up (iPad: the tracker lost butt-kick jumpers for 5 frames at the top). Those frames stay
    /// UNKNOWN; past `maximumGap` the flight ends (`aLongAnkleDropoutEndsTheJumpAndNeverResumesIt`).
    @Test func aFlightSurvivesAShortGapWithNoSoles() {
        let hidden = (1.0 + 4.0 / 30)...(1.0 + 7.5 / 30)
        let jump = twoSoles(3) { t in
            let v = Self.tuckJump(t - 1, kickAt: 0)
            return hidden.contains(t) ? (nil, nil, v.hip) : (v.left, v.right, v.hip)
        }
        #expect(jump.contains { $0 < hidden.lowerBound } && jump.contains { $0 > hidden.upperBound }, "\(jump)")
        #expect(jump.allSatisfy { !hidden.contains($0) }, "never airborne without soles")
    }

    @Test func alternatingBackwardLegLiftsAreNeverAJump() {
        // Left heel back, down, right heel back, down… quickly, one foot always on the floor.
        let kicks = twoSoles(5) { t in
            guard t >= 1 else { return (0, 0, 0.8) }
            let phase = (t - 1).truncatingRemainder(dividingBy: 0.8), up = 0.35 * max(0, sin(.pi * min(1, phase / 0.4)))
            return phase < 0.4 ? ((t - 1).truncatingRemainder(dividingBy: 1.6) < 0.8 ? (up, 0, 0.8) : (0, up, 0.8)) : (0, 0, 0.8)
        }
        #expect(kicks.isEmpty)
    }

    @Test func aSlowCalfRaiseIsNeverAJump() {
        // Up 6 cm over 0.6 s, held, down: absorbed by the floor (the existing calf-raise behaviour).
        let raise = twoSoles(5) { t in
            let h = 0.06 * (min(1, max(0, (t - 1) / 0.6)) - min(1, max(0, (t - 3) / 0.6)))
            return (h, h, 0.8 + h)
        }
        #expect(raise.isEmpty)
    }

    @Test func aTuckJumpWithBothLowerLegsBentBackIsAirborne() {
        let jump = twoSoles(3) { t in let v = Self.tuckJump(t - 1); return (v.left, v.right, v.hip) }
        let runs = Self.runs(jump)
        #expect(runs.count == 1, "one jump: \(runs)")
        #expect(runs.first.map { $0.0 < 1.15 && $0.1 > 1.25 } == true, "airborne through the flight: \(runs)")
    }

    @Test func anAsymmetricTuckJumpIsAirborne() {
        // One heel folds right back, the other only a little: the lower sole still leaves the floor.
        let jump = twoSoles(3) { t in let v = Self.tuckJump(t - 1, kickAt: 0, sides: (1, 0.3)); return (v.left, v.right, v.hip) }
        #expect(Self.runs(jump).count == 1)
    }

    @Test func liftingOneFootBackWhileStandingIsNeverAJump() {
        // The heel kicks back fast and is held; the other foot (the lower sole) stays down.
        let kick = twoSoles(4) { t in (t < 1 ? 0 : min(0.35, 3 * (t - 1)), 0, 0.8) }
        #expect(kick.isEmpty)
    }

    @Test func bothSolesRisingWithoutTheHipsIsNeverAJump() {
        // Both ankle-based soles rise quickly (heels drawn back, or ankles mis-placed) while the hips
        // stay put, or rise less than the take-off line: no whole-body flight, no take-off.
        for hipRise in [0.0, -0.05, 0.03] {
            let heels = twoSoles(3) { t in
                let u = min(1, max(0, (t - 1) / 0.15)), back = max(0, 1 - max(0, t - 1.6) / 0.15)
                let s = 0.3 * min(u, back)
                return (s, s, 0.8 + hipRise * min(u, back))
            }
            #expect(heels.isEmpty, "hips rising \(hipRise)")
        }
    }

    @Test func aSquatWithoutAJumpIsNeverAJump() {
        // Down and up over 0.4 s each, the soles reading low while squatting (as the iPad logs show).
        let squat = twoSoles(4) { t in
            let d = min(1, max(0, (t - 1) / 0.4)) - min(1, max(0, (t - 2.2) / 0.4))
            return (-0.15 * d, -0.15 * d, 0.8 - 0.3 * d)
        }
        #expect(squat.isEmpty)
    }

    @Test func aLongAnkleDropoutEndsTheJumpAndNeverResumesIt() {
        // Hidden for 9 frames (0.3 s): the flight ends (the existing `dropoutFrames` rule) and is
        // not resumed; nothing is claimed airborne without seen soles.
        let hidden = (1.0 + 2.0 / 30)...(1.0 + 10.5 / 30)
        let jump = twoSoles(3) { t in
            let v = Self.tuckJump(t - 1, height: 0.2, flight: 0.6)
            return hidden.contains(t) ? (nil, nil, v.hip) : (v.left, v.right, v.hip)
        }
        #expect(jump.allSatisfy { !hidden.contains($0) })
        #expect(jump.allSatisfy { $0 < hidden.lowerBound }, "not resumed after a too-long dropout: \(jump)")
    }

    @Test func repeatedTuckJumpsAreSeparateJumpsWithLandings() {
        let jumps = twoSoles(4) { t in
            let v = t < 2 ? Self.tuckJump(t - 1, kickAt: 0) : Self.tuckJump(t - 2.2, kickAt: 0)
            return (v.left, v.right, v.hip)
        }
        #expect(Self.runs(jumps).count == 2, "\(Self.runs(jumps))")
    }

    @Test func eachPlayersEstimatorIsIndependent() {
        // P1 tuck-jumps while P2 kicks one heel back, frame by frame together.
        var p1 = LiveJumpEstimator(), p2 = LiveJumpEstimator()
        var air1 = 0, air2 = 0
        for i in 0..<90 {
            let t = Double(i) / 30, a = Self.tuckJump(t - 1, kickAt: 0)
            let s1 = p1.step(frameID: UInt64(i + 1), capturedAt: t, leftSole: a.left, rightSole: a.right, standingLeftSole: 0,
                             standingRightSole: 0, standingHeight: 1.6, calibrationRevision: 1, hipY: a.hip, standingHip: 0.8, candidateRules: true)
            let s2 = p2.step(frameID: UInt64(i + 1), capturedAt: t, leftSole: t < 1 ? 0 : min(0.35, 3 * (t - 1)), rightSole: 0,
                             standingLeftSole: 0, standingRightSole: 0, standingHeight: 1.6, calibrationRevision: 1, hipY: 0.8,
                             standingHip: 0.8, candidateRules: true)
            if s1.phase == .airborne { air1 += 1 }
            if s2.phase == .airborne { air2 += 1 }
        }
        #expect(air1 >= 8 && air2 == 0)
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

    @Test func reactingAfterTheGreenJumpCueCanClearTheCrossing() throws {
        let crossing = 10.0
        let green = crossing - LaserTimingPresentation.jumpReactionLead
        // A slower reaction plus takeoff takes 520 ms. The player is still grounded at crossing.
        let takeoff = green + 0.52
        #expect(takeoff > crossing)
        #expect(try jumpVerdict(airborne: { (takeoff ... takeoff + 0.18).contains($0) }) == .clear)
        #expect(try jumpVerdict(airborne: { _ in false }) == .hit(.notAirborne))
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
        #expect(try jumpVerdict(airborne: { (9.66...9.83).contains($0) }) == .hit(.notAirborne), "landed over 150 ms early")
        #expect(try jumpVerdict(airborne: { (10.16...10.25).contains($0) }) == .hit(.notAirborne), "took off over 150 ms late")
        #expect(try jumpVerdict(airborne: { (9.70...9.88).contains($0) }) == .clear, "last airborne frame about 133 ms early")
        #expect(try jumpVerdict(airborne: { (10.12...10.25).contains($0) }) == .clear, "first airborne frame about 133 ms late")
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


    // MARK: Butt-kick jumps on the iPad (21 November 2026, `[LaserJumpTrace]`)

    /// The three butt-kick jumps the iPad scored HIT, as the jump estimator received them: time from
    /// the laser's crossing (s), left and right sole (game units; nil = ankle below 0.5 confidence)
    /// and the hips (game units). Derived measurements only (no image data, no raw joints). Standing
    /// values from their grounded frames: hips 0.732, floor 0, height 1.433 (enter line 0.043).
    static let iPadButtKickJumps: [[(t: Double, left: Double?, right: Double?, hip: Double?)]] = [
        // iPad jump 1 (21 Nov 2026)
        [
            (-1.173, -0.005, 0.022, 0.730), (-1.139, -0.005, 0.023, 0.730), (-1.106, -0.002, 0.023, 0.728), (-1.073, -0.004, 0.023, 0.728), (-1.039, -0.006, 0.022, 0.728),
            (-1.006, -0.006, 0.022, 0.729), (-0.973, -0.006, 0.022, 0.728), (-0.940, -0.005, 0.022, 0.730), (-0.906, -0.006, 0.022, 0.731), (-0.873, -0.006, 0.021, 0.730),
            (-0.840, -0.005, 0.021, 0.733), (-0.806, -0.005, 0.020, 0.735), (-0.773, -0.005, 0.021, 0.737), (-0.740, -0.004, 0.020, 0.730), (-0.706, -0.002, 0.020, 0.718),
            (-0.673, -0.003, 0.019, 0.701), (-0.640, -0.003, 0.017, 0.682), (-0.606, -0.006, 0.014, 0.660), (-0.573, -0.008, 0.015, 0.642), (-0.540, -0.019, 0.011, 0.628),
            (-0.506, -0.013, 0.010, 0.622), (-0.473, -0.017, 0.010, 0.640), (-0.440, -0.010, 0.015, 0.664), (-0.406, -0.003, 0.023, 0.704), (-0.373, 0.014, 0.029, 0.775),
            (-0.340, 0.041, 0.028, 0.822), (-0.306, 0.135, 0.201, 0.887), (-0.273, nil, nil, 0.923), (-0.240, nil, nil, 0.964), (-0.206, nil, nil, 0.969),
            (-0.173, nil, nil, 0.985), (-0.140, nil, nil, 0.982), (-0.106, nil, nil, 0.981), (-0.073, nil, nil, 0.976), (-0.040, nil, nil, 0.976),
            (-0.006, 0.229, nil, 0.963), (0.027, 0.124, 0.168, 0.931), (0.060, 0.074, 0.109, 0.878), (0.094, 0.008, 0.035, 0.806), (0.127, -0.023, 0.011, 0.747),
            (0.160, -0.037, 0.000, 0.680),
        ],
        // iPad jump 2 (21 Nov 2026)
        [
            (-1.176, 0.031, 0.063, 0.734), (-1.142, 0.031, 0.063, 0.737), (-1.109, 0.030, 0.063, 0.737), (-1.076, 0.033, 0.063, 0.737), (-1.042, 0.032, 0.062, 0.736),
            (-1.009, 0.031, 0.061, 0.735), (-0.976, 0.031, 0.061, 0.737), (-0.942, 0.031, 0.062, 0.738), (-0.909, 0.032, 0.063, 0.735), (-0.876, 0.032, 0.062, 0.736),
            (-0.842, 0.033, 0.061, 0.735), (-0.809, 0.033, 0.059, 0.735), (-0.776, 0.033, 0.059, 0.736), (-0.742, 0.033, 0.059, 0.737), (-0.709, 0.033, 0.060, 0.737),
            (-0.676, 0.034, 0.059, 0.736), (-0.642, 0.033, 0.059, 0.736), (-0.609, 0.033, 0.062, 0.732), (-0.576, 0.033, 0.064, 0.722), (-0.542, 0.031, 0.060, 0.705),
            (-0.509, 0.029, 0.056, 0.687), (-0.476, 0.029, 0.054, 0.669), (-0.443, 0.026, 0.050, 0.656), (-0.409, 0.026, 0.051, 0.644), (-0.376, 0.022, 0.051, 0.642),
            (-0.343, 0.024, 0.054, 0.649), (-0.309, 0.028, 0.055, 0.681), (-0.276, 0.033, 0.067, 0.727), (-0.243, 0.060, 0.111, 0.780), (-0.209, 0.126, 0.132, 0.844),
            (-0.176, 0.199, 0.210, 0.893), (-0.143, nil, nil, 0.928), (-0.109, nil, nil, 0.952), (-0.076, nil, nil, 0.973), (-0.043, nil, nil, 0.985),
            (-0.009, nil, nil, 0.983), (0.024, nil, nil, 0.982), (0.057, nil, nil, 0.979), (0.091, nil, 0.289, 0.973), (0.124, 0.233, 0.256, 0.954),
            (0.157, 0.213, 0.224, 0.935),
        ],
        // iPad jump 3 (21 Nov 2026)
        [
            (-1.177, -0.019, 0.006, 0.734), (-1.144, -0.016, 0.006, 0.733), (-1.111, -0.020, 0.006, 0.733), (-1.077, -0.019, 0.006, 0.732), (-1.044, -0.017, 0.006, 0.730),
            (-1.011, -0.017, 0.006, 0.729), (-0.977, -0.017, 0.006, 0.730), (-0.944, -0.017, 0.007, 0.729), (-0.911, -0.017, 0.006, 0.730), (-0.877, -0.015, 0.006, 0.732),
            (-0.844, -0.013, 0.007, 0.730), (-0.811, -0.014, 0.005, 0.731), (-0.777, -0.011, 0.008, 0.721), (-0.744, -0.013, 0.009, 0.718), (-0.711, -0.019, 0.009, 0.705),
            (-0.677, -0.016, 0.009, 0.686), (-0.644, -0.018, 0.004, 0.662), (-0.611, -0.021, 0.004, 0.644), (-0.577, -0.030, -0.000, 0.627), (-0.544, -0.039, -0.002, 0.609),
            (-0.511, -0.040, -0.004, 0.606), (-0.477, -0.041, -0.003, 0.619), (-0.444, -0.035, 0.002, 0.639), (-0.411, -0.022, 0.008, 0.688), (-0.377, -0.001, 0.021, 0.753),
            (-0.344, 0.046, 0.036, 0.801), (-0.311, 0.103, 0.091, 0.854), (-0.277, 0.189, 0.207, 0.922), (-0.244, nil, nil, 0.936), (-0.211, nil, nil, 0.959),
            (-0.177, nil, nil, 0.970), (-0.144, nil, nil, 0.967), (-0.111, nil, nil, 0.967), (-0.077, nil, nil, 0.965), (-0.044, nil, nil, 0.953),
            (-0.011, nil, nil, 0.933), (0.023, 0.190, 0.238, 0.930), (0.056, 0.154, 0.146, 0.883), (0.089, 0.077, 0.073, 0.827), (0.123, 0.042, 0.031, 0.763),
            (0.156, 0.032, 0.019, 0.703),
        ],
    ]

    /// The two butt-kick jumps the iPad still scored HIT with the hip bound (second session): at the top
    /// of the kick the tracker lost the player for 5 frames (`uncertain`, no candidate: here nil soles
    /// and hips) and the service discarded the jump estimator. Standing values from the trace:
    /// hips 0.676, floor 0 / 0.006, height 1.333 (enter line 0.040).
    static let iPadTrackingGapJumps: [[(t: Double, left: Double?, right: Double?, hip: Double?)]] = [
        // iPad jump 4 (21 Nov 2026, second session)
        [
            (-1.177, -0.048, -0.044, 0.666), (-1.144, -0.047, -0.043, 0.663), (-1.111, -0.048, -0.042, 0.664), (-1.077, -0.050, -0.043, 0.663), (-1.044, -0.048, -0.042, 0.663),
            (-1.011, -0.049, -0.043, 0.662), (-0.977, -0.051, -0.043, 0.662), (-0.944, -0.053, -0.043, 0.661), (-0.911, -0.050, -0.043, 0.661), (-0.877, -0.052, -0.044, 0.664),
            (-0.844, -0.047, -0.043, 0.663), (-0.811, -0.052, -0.040, 0.659), (-0.777, -0.051, -0.037, 0.653), (-0.744, -0.048, -0.037, 0.639), (-0.711, -0.051, -0.036, 0.621),
            (-0.677, -0.047, -0.041, 0.602), (-0.644, -0.052, -0.041, 0.585), (-0.611, -0.056, -0.044, 0.567), (-0.577, -0.056, -0.047, 0.550), (-0.544, -0.060, -0.047, 0.547),
            (-0.511, -0.057, -0.047, 0.550), (-0.477, -0.054, -0.046, 0.580), (-0.444, -0.046, -0.041, 0.633), (-0.411, -0.034, -0.033, 0.686), (-0.377, 0.010, 0.018, 0.753),
            (-0.344, 0.061, 0.047, 0.813), (-0.311, nil, nil, nil), (-0.278, nil, nil, nil), (-0.244, nil, nil, nil), (-0.211, nil, nil, nil),
            (-0.177, nil, nil, nil), (-0.144, nil, nil, 0.935), (-0.111, nil, nil, 0.932), (-0.078, nil, nil, 0.926), (-0.044, nil, nil, 0.909),
            (-0.011, 0.195, nil, 0.893), (0.022, 0.102, 0.112, 0.847), (0.056, 0.048, 0.033, 0.782), (0.089, -0.010, -0.011, 0.723), (0.122, -0.035, -0.040, 0.657),
            (0.156, -0.044, -0.045, 0.612),
        ],
        // iPad jump 5 (21 Nov 2026, second session)
        [
            (-1.199, -0.021, -0.016, 0.673), (-1.166, -0.021, -0.016, 0.673), (-1.132, -0.021, -0.017, 0.673), (-1.099, -0.021, -0.018, 0.674), (-1.066, -0.021, -0.017, 0.673),
            (-1.032, -0.021, -0.017, 0.673), (-0.999, -0.021, -0.015, 0.675), (-0.966, -0.021, -0.017, 0.674), (-0.932, -0.021, -0.016, 0.675), (-0.899, -0.021, -0.018, 0.674),
            (-0.866, -0.021, -0.018, 0.673), (-0.832, -0.022, -0.018, 0.673), (-0.799, -0.021, -0.018, 0.673), (-0.766, -0.021, -0.015, 0.674), (-0.732, -0.021, -0.017, 0.671),
            (-0.699, -0.021, -0.020, 0.670), (-0.666, -0.021, -0.020, 0.662), (-0.632, -0.020, -0.019, 0.646), (-0.599, -0.019, -0.019, 0.629), (-0.566, -0.023, -0.024, 0.606),
            (-0.532, -0.026, -0.026, 0.585), (-0.499, -0.031, -0.027, 0.566), (-0.466, -0.030, -0.029, 0.559), (-0.432, -0.030, -0.029, 0.560), (-0.399, -0.027, -0.027, 0.579),
            (-0.366, -0.023, -0.020, 0.622), (-0.332, -0.014, -0.011, 0.674), (-0.299, 0.009, 0.019, 0.737), (-0.266, 0.056, 0.055, 0.803), (-0.233, nil, nil, nil),
            (-0.199, nil, nil, nil), (-0.166, nil, nil, nil), (-0.133, nil, nil, nil), (-0.099, nil, nil, nil), (-0.066, nil, nil, 0.973),
            (-0.032, nil, nil, 0.968), (0.001, nil, nil, 0.969), (0.034, nil, nil, 0.960), (0.068, 0.282, 0.244, 0.950), (0.101, 0.229, 0.215, 0.923),
            (0.134, 0.134, 0.153, 0.880), (0.168, 0.106, 0.089, 0.827),
        ],
    ]

    /// Replays one recorded jump through the live estimator and the timed jump judge, its crossing
    /// placed at game time 10. `bound`: the hip-bounded flight soles. `keepFlight`: frames with no
    /// player at all (nil hips and soles) keep the estimator, as the service now does in a flight;
    /// otherwise they discard it, as before.
    private func recordedVerdict(_ frames: [(t: Double, left: Double?, right: Double?, hip: Double?)], bound: Bool,
                                 keepFlight: Bool = true, standingHip: Double = 0.732, floor: (Double, Double) = (0, 0),
                                 height: Double = 1.433) throws -> Judgement? {
        var estimator = LiveJumpEstimator()
        var phases: [(t: Double, airborne: Bool, soles: Bool)] = []
        for (i, f) in frames.enumerated() {
            if f.hip == nil, f.left == nil, f.right == nil, !(keepFlight && estimator.isInFlight) {
                estimator = LiveJumpEstimator() // tracking lost: discarded
                phases.append((10 + f.t, false, false))
                continue
            }
            var soles = (left: f.left, right: f.right, bounded: false)
            if bound {
                soles = LiveJumpEstimator.flightSoles(left: f.left, right: f.right, inFlight: estimator.isInFlight, hipY: f.hip,
                    standingHip: standingHip, standingLeftSole: floor.0, standingRightSole: floor.1, standingHeight: height)
            }
            let state = estimator.step(frameID: UInt64(i + 1), capturedAt: 10 + f.t, leftSole: soles.left, rightSole: soles.right,
                standingLeftSole: floor.0, standingRightSole: floor.1, standingHeight: height, calibrationRevision: 1,
                hipY: f.hip, standingHip: standingHip, candidateRules: true)
            phases.append((10 + f.t, state.phase == .airborne, soles.left != nil && soles.right != nil))
        }
        func nearest(_ t: Double) -> (t: Double, airborne: Bool, soles: Bool) { phases.min { abs($0.t - t) < abs($1.t - t) }! }
        return try jumpVerdict(airborne: { nearest($0).airborne }, soles: { nearest($0).soles })
    }

    /// THE IPAD FAILURE: each jump took off, the folded legs hid the ankles for 8–9 frames around the
    /// crossing, and the jump scored HIT. With the hips bounding the hidden feet during the flight,
    /// each is airborne through the crossing and CLEAR.
    @Test(arguments: 0..<3) func theIPadButtKickJumpsClear(jump: Int) throws {
        let frames = Self.iPadButtKickJumps[jump]
        #expect(try recordedVerdict(frames, bound: false) == .hit(.notAirborne), "as on the iPad")
        #expect(try recordedVerdict(frames, bound: true) == .clear, "jump \(jump + 1)")
    }

    /// THE SECOND IPAD FAILURE: with the hip bound, two butt-kick jumps still scored HIT because the
    /// tracker lost the player for 5 frames mid-flight and the estimator was discarded. Kept through
    /// the gap, the flight resumes (hip-bounded) and each is CLEAR.
    @Test(arguments: 0..<2) func theIPadButtKickJumpsWithATrackingGapClear(jump: Int) throws {
        let frames = Self.iPadTrackingGapJumps[jump]
        func verdict(keep: Bool) throws -> Judgement? {
            try recordedVerdict(frames, bound: true, keepFlight: keep, standingHip: 0.676, floor: (0, 0.006), height: 1.333)
        }
        #expect(try verdict(keep: false) == .hit(.notAirborne), "as on the iPad (second session)")
        #expect(try verdict(keep: true) == .clear, "jump \(jump + 4)")
    }

    /// The bound applies only inside a flight already seen, only to a hidden ankle, and only while
    /// the hips are at least the take-off line above standing; real soles are never replaced.
    @Test func theHipBoundOnlyStandsInForAHiddenAnkleDuringAFlight() {
        func b(_ l: Double?, _ r: Double?, flight: Bool, hip: Double) -> (left: Double?, right: Double?, bounded: Bool) {
            LiveJumpEstimator.flightSoles(left: l, right: r, inFlight: flight, hipY: hip, standingHip: 0.73,
                                          standingLeftSole: 0, standingRightSole: 0.02, standingHeight: 1.43)
        }
        let none = b(nil, nil, flight: false, hip: 0.95)
        #expect(none.left == nil && none.right == nil && !none.bounded, "no take-off seen: nothing")
        let low = b(nil, nil, flight: true, hip: 0.76)
        #expect(low.left == nil && low.right == nil && !low.bounded, "hips below the take-off line: nothing")
        let hidden = b(nil, 0.2, flight: true, hip: 0.95)
        #expect(hidden.bounded && abs((hidden.left ?? 0) - 0.22) < 1e-9 && hidden.right == 0.2, "only the hidden side, from its own standing leg")
        let seen = b(0.1, 0.2, flight: true, hip: 0.95)
        #expect(seen.left == 0.1 && seen.right == 0.2 && !seen.bounded, "both seen: untouched")
        let both = b(nil, nil, flight: true, hip: 0.95)
        #expect(both.bounded && abs((both.right ?? 0) - 0.24) < 1e-9)
    }

    /// Hidden ankles never start a jump: hips rising with the ankles hidden throughout is no take-off.
    @Test func theHipBoundNeverStartsAJump() {
        var estimator = LiveJumpEstimator()
        var airborne: [Double] = []
        for i in 0..<60 {
            let t = Double(i) / 30, hip = t < 1 ? 0.73 : 0.98
            let soles = LiveJumpEstimator.flightSoles(left: t < 1 ? 0 : nil, right: t < 1 ? 0 : nil, inFlight: estimator.isInFlight,
                hipY: hip, standingHip: 0.73, standingLeftSole: 0, standingRightSole: 0, standingHeight: 1.43)
            let s = estimator.step(frameID: UInt64(i + 1), capturedAt: t, leftSole: soles.left, rightSole: soles.right,
                standingLeftSole: 0, standingRightSole: 0, standingHeight: 1.43, calibrationRevision: 1,
                hipY: hip, standingHip: 0.73, candidateRules: true)
            if s.phase == .airborne { airborne.append(t) }
        }
        #expect(airborne.isEmpty, "\(airborne)")
    }

    /// A straight jump whose ankles drop out after it has come down (hips back at standing) is not
    /// prolonged: the bound needs the hips up.
    @Test func theHipBoundNeverProlongsALandedJump() {
        var estimator = LiveJumpEstimator()
        var airborne: [Double] = []
        for i in 0..<75 {
            let t = Double(i) / 30, u = t - 1, h = u > 0 && u < 0.4 ? 0.15 * sin(.pi * u / 0.4) : 0
            let hidden = t > 1.37 && t < 1.8 // ankles lost just as it lands, for 0.4 s
            let soles = LiveJumpEstimator.flightSoles(left: hidden ? nil : h, right: hidden ? nil : h, inFlight: estimator.isInFlight,
                hipY: 0.73 + h, standingHip: 0.73, standingLeftSole: 0, standingRightSole: 0, standingHeight: 1.43)
            let s = estimator.step(frameID: UInt64(i + 1), capturedAt: t, leftSole: soles.left, rightSole: soles.right,
                standingLeftSole: 0, standingRightSole: 0, standingHeight: 1.43, calibrationRevision: 1,
                hipY: 0.73 + h, standingHip: 0.73, candidateRules: true)
            if s.phase == .airborne { airborne.append(t) }
        }
        #expect(!airborne.isEmpty && airborne.allSatisfy { $0 < 1.4 }, "\(airborne)")
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
