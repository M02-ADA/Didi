import Foundation
import Testing
@testable import Sedactive

/// Policy V2 live evidence (11 November 2026): head-top and soles from this frame's nose and ankles
/// plus the player's own accepted standing offsets, and airborne only when both soles AND the
/// hips rise after the player was seen grounded. No other player's data, no invented frames.
nonisolated struct LiveBodyEstimateTests {
    static let layout = PlayerPlaneLayout(leftCenterX: -1, rightCenterX: 1, gameUnitsPerImageHeight: 2)

    /// A live-accepted calibration: crown 0.9, soles 0.1, nose 0.8, ankles 0.13 (image y-up).
    static func calibration(provenance: AnatomicalReferenceQuality? = .experimental) throws -> PlayerCalibration {
        let height = 0.8
        let value = PlayerCalibration(playerID: .player1, sessionGeneration: UUID(), revision: 1,
            cameraGeometryRevision: 1, sourceFrameID: 1, capturedAt: 0.1, standingCrownImageY: 0.9,
            standingLeftSoleImageY: 0.1, standingRightSoleImageY: 0.1, standingHipImageY: 0.5,
            standingBodyImageHeight: height, standingTorsoImageLength: 0.25,
            headOffsetFromNoseShare: (0.9 - 0.8) / height, leftFootOffsetShare: (0.13 - 0.1) / height,
            rightFootOffsetShare: (0.13 - 0.1) / height,
            mapping: .init(imageAspectRatio: 16 / 9, floorImageY: 0.1, originImageX: 0.5),
            referenceQuality: provenance)
        try value.validate()
        return value
    }

    static func candidate(noseY: Double = 0.8, ankleY: Double = 0.13, hipY: Double = 0.5,
                          ankleConfidence: Double = 0.9) -> PoseCandidate {
        let j: [BodyJoint: PoseJoint] = [
            .nose: .init(x: 0.5, y: noseY, confidence: 0.9),
            .leftWrist: .init(x: 0.45, y: 0.5, confidence: 0.9), .rightWrist: .init(x: 0.55, y: 0.5, confidence: 0.9),
            .leftHip: .init(x: 0.47, y: hipY, confidence: 0.9), .rightHip: .init(x: 0.53, y: hipY, confidence: 0.9),
            .leftAnkle: .init(x: 0.46, y: ankleY, confidence: ankleConfidence),
            .rightAnkle: .init(x: 0.54, y: ankleY, confidence: ankleConfidence)]
        return PoseCandidate(candidateID: 10, joints: j, maskTopImageY: nil, maskBottomImageY: nil,
            leftFootBottomImageY: nil, rightFootBottomImageY: nil, maskAssociation: .unavailable)
    }

    static let tracking = PlayerTrackingSlotResult(state: .tracking, reason: .matched, candidateID: 10,
        cost: 0, requiresRebind: false, lastConfirmedAt: 0)

    @Test func standingGivesTheCalibratedHeadTopAndSoles() throws {
        let c = try Self.calibration()
        let s = BodyMeasurementExtractor.sample(id: .player1, candidate: Self.candidate(), slot: Self.tracking,
                                                calibration: c, layout: Self.layout)
        try s.validate()
        // Head-top = nose + its standing offset = 0.9 image → (0.9-0.1)*2 = 1.6 game units.
        #expect(abs((s.geometry.crownY.value ?? 0) - 1.6) < 1e-9)
        #expect(abs(s.geometry.leftSoleY.value ?? 1) < 1e-9 && abs(s.geometry.rightSoleY.value ?? 1) < 1e-9)
    }

    @Test func duckingLowersTheHeadTopWithTheNose() throws {
        let c = try Self.calibration()
        let s = BodyMeasurementExtractor.sample(id: .player1, candidate: Self.candidate(noseY: 0.55), slot: Self.tracking,
                                                calibration: c, layout: Self.layout)
        #expect(abs((s.geometry.crownY.value ?? 0) - (0.55 + 0.1 - 0.1) * 2) < 1e-9)
    }

    @Test func missingOrWeakLandmarksAreUnavailableNotGuessed() throws {
        let c = try Self.calibration()
        let weak = BodyMeasurementExtractor.sample(id: .player1, candidate: Self.candidate(ankleConfidence: 0.3),
                                                   slot: Self.tracking, calibration: c, layout: Self.layout)
        #expect(weak.geometry.leftSoleY.validity == .lowConfidence && weak.geometry.crownY.validity == .valid)
        // A calibration with no recorded live provenance still yields no head-top or soles.
        let synthetic = BodyMeasurementExtractor.sample(id: .player1, candidate: Self.candidate(), slot: Self.tracking,
            calibration: try Self.calibration(provenance: nil), layout: Self.layout)
        #expect(synthetic.geometry.crownY.validity != .valid && synthetic.geometry.leftSoleY.validity != .valid)
        // Not tracking: nothing valid at all.
        let lost = PlayerTrackingSlotResult(state: .uncertain, reason: .missingOrWeak, candidateID: nil, cost: nil,
                                            requiresRebind: false, lastConfirmedAt: 0)
        let s = BodyMeasurementExtractor.sample(id: .player1, candidate: Self.candidate(), slot: lost,
                                                calibration: c, layout: Self.layout)
        #expect(s.geometry.measurements.allSatisfy { $0.validity != .valid })
    }

    // MARK: Airborne (spike `LiveJumpDetector` "tuned" rule, synthetic tracks)

    /// 1.6 m player, 30 fps, ±1.2 cm independent ankle jitter (spike `LiveJumpTuningTests`).
    static let standing = 1.6, fps = 30.0
    static func jitter(_ count: Int, amplitude: Double, seed: UInt64) -> [Double] {
        var state = seed
        return (0..<count).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return (Double(state >> 11) / Double(1 << 53) * 2 - 1) * amplitude
        }
    }
    static func hop(_ t: Double, start: Double, duration: Double, peak: Double) -> Double {
        let u = (t - start) / duration
        return u > 0 && u < 1 ? 4 * peak * u * (1 - u) : 0
    }
    /// Per-frame (left, right) soles above the calibrated floor; nil = not valid this frame.
    static func track(seconds: Double = 4, offset: Double = 0, _ shape: (Double) -> (Double, Double)) -> [(Double?, Double?)] {
        let n = Int(seconds * fps)
        let l = jitter(n, amplitude: 0.012, seed: 7), r = jitter(n, amplitude: 0.012, seed: 106)
        return (0..<n).map { i in let (a, b) = shape(Double(i) / fps); return (a + l[i] + offset, b + r[i] + offset) }
    }
    struct Result { var phases: [JumpState] = []; var jumps = 0; var airborneFrames = 0 }
    static func run(_ frames: [(Double?, Double?)], revision: (Int) -> UInt64 = { _ in 1 }) -> Result {
        var e = LiveJumpEstimator(), out = Result(), was = false
        for (i, f) in frames.enumerated() {
            let s = e.step(frameID: UInt64(i + 1), capturedAt: Double(i) / fps, leftSole: f.0, rightSole: f.1,
                           standingLeftSole: 0, standingRightSole: 0, standingHeight: standing,
                           calibrationRevision: revision(i))
            out.phases.append(s)
            if s.phase == .airborne { out.airborneFrames += 1; if !was { out.jumps += 1 }; was = true }
            else if s.validity == .valid { was = false }
        }
        return out
    }

    @Test func standingArmsTiptoeAndOneKneeAreNeverAirborne() {
        let still = Self.track { _ in (0, 0) } // also raised arms: soles do not move
        let tiptoe = Self.track { t in
            let up = min(1, max(0, (t - 1) / 0.8)) - min(1, max(0, (t - 2.8) / 0.4)); return (0.06 * up, 0.06 * up) }
        let knee = Self.track { t in (t > 1 && t < 2.5 ? 0.25 : 0, 0) }
        for (name, frames) in [("standing", still), ("tiptoe", tiptoe), ("one knee", knee)] {
            #expect(Self.run(frames).jumps == 0, "\(name)")
        }
    }

    @Test func smallAndLargerJumpsAreOneCleanJumpThenLanding() {
        for (peak, duration) in [(0.06, 0.3), (0.10, 0.35), (0.20, 0.45)] {
            let r = Self.run(Self.track { t in let h = Self.hop(t, start: 2, duration: duration, peak: peak); return (h, h) })
            #expect(r.jumps == 1 && r.airborneFrames >= 3, "\(peak) m hop")
            let landing = r.phases.firstIndex { $0.phase == .landing }
            #expect(landing != nil && r.phases[landing! - 1].phase == .airborne, "landing follows the jump")
        }
    }

    /// iPad, 11 November 2026: live standing soles sat ~0.06 above the calibrated floor (more
    /// than the 3 % threshold). The baseline follows that drift, so a real hop still counts and
    /// standing on the drifted floor never does.
    @Test func aDriftedStandingFloorStillDetectsAHop() {
        #expect(Self.run(Self.track(offset: 0.06) { _ in (0, 0) }).jumps == 0)
        let r = Self.run(Self.track(offset: 0.06) { t in let h = Self.hop(t, start: 2.5, duration: 0.35, peak: 0.10); return (h, h) })
        #expect(r.jumps == 1)
    }

    /// iPad, 11 November 2026: a duck shifts the soles slowly by ~6 cm; a hop half a second
    /// later must still count (the shift is followed, it is not foot noise).
    @Test func aJumpRightAfterADuckIsStillDetected() {
        let r = Self.run(Self.track { t in
            let duck = -0.06 * (min(1, max(0, (t - 1) / 0.5)) - min(1, max(0, (t - 1.8) / 0.5)))
            let h = Self.hop(t, start: 2.8, duration: 0.35, peak: 0.10)
            return (duck + h, duck + h)
        })
        #expect(r.jumps == 1)
    }

    @Test func briefDropoutKeepsTheJumpButIsNeverAirborneItself() {
        var frames = Self.track { t in let h = Self.hop(t, start: 2, duration: 0.35, peak: 0.10); return (h, h) }
        let top = Int(2.17 * Self.fps)
        frames[top] = (nil, nil)
        let r = Self.run(frames)
        #expect(r.jumps == 1, "one jump, not split by a missing frame")
        #expect(r.phases[top].phase == .unknown && r.phases[top].validity == .missingLandmarks)
    }

    @Test func lostAnklesOrANewCalibrationNeverInventAJump() {
        // Ankles lost for 10 frames, back already 12 cm up: no takeoff was seen.
        var frames = Self.track { _ in (0, 0) }
        for i in 60..<70 { frames[i] = (nil, nil) }
        for i in 70..<76 { frames[i] = (0.12, 0.12) }
        #expect(Self.run(frames).jumps == 0)
        #expect(Self.run(frames).phases[60..<70].allSatisfy { $0.phase == .unknown })
        // A new calibration mid-jump restarts the detector: no airborne carried over.
        let hop = Self.track { t in let h = Self.hop(t, start: 2, duration: 0.45, peak: 0.20); return (h, h) }
        let reset = Self.run(hop, revision: { $0 < Int(2.2 * Self.fps) ? 1 : 2 })
        #expect(reset.phases[Int(2.2 * Self.fps)].phase != .airborne)
    }

    @Test func staleOrOutOfOrderFramesAreNotEvidence() {
        var e = LiveJumpEstimator()
        _ = e.step(frameID: 5, capturedAt: 1, leftSole: 0, rightSole: 0, standingLeftSole: 0, standingRightSole: 0,
                   standingHeight: 1.6, calibrationRevision: 1)
        let old = e.step(frameID: 4, capturedAt: 1.1, leftSole: 0.3, rightSole: 0.3, standingLeftSole: 0,
                         standingRightSole: 0, standingHeight: 1.6, calibrationRevision: 1)
        #expect(old.validity == .stale && old.phase == .unknown)
    }
}

/// End to end on the provider's own state: live standing samples → accepted calibration → live
/// frames → head-top, soles and a grounded jump state that the round's readiness gate admits.
/// (Before policy V2 these were always UNAVAILABLE, so no live round could ever start.)
nonisolated struct LiveCalibrationToReadinessTests {
    @Test func anAcceptedLiveCalibrationMakesLiveFramesReady() throws {
        let (f, initial, stamp) = try LiveVisionFixtures.sessionFixture()
        var session = initial
        for i in 0..<10 {
            let pose = try f.result(UInt64(i + 3), Double(i) * 0.25 + 0.25, LiveVisionFixtures.standingPair)
            let started = session.beginSample(stamp, source: pose.source, at: pose.source.capturedAt)
            try #require(started)
            session.observe(LiveVisionFixtures.withAnatomy(LiveVisionFixtures.mask(pose), pose: pose, revision: stamp.bindingRevision),
                pose: pose, association: LiveVisionFixtures.association(pose, revision: stamp.bindingRevision),
                stamp: stamp, at: pose.source.capturedAt + 0.01)
        }
        let candidate = try #require(session.candidate)
        var body = LiveBodyInputState()
        try body.configure(LiveVisionFixtures.configuration(f.context.generation), source: f.context)
        body.calibration = session
        let context = try body.accept(candidateID: candidate.id, expectedRevision: 0, at: 3)
        var readiness = LaserLiveReadiness(policy: try .init(settlingDuration: 0.2, maximumEvidenceAge: 0.5,
                                                             countdownDuration: 1))
        for i in 0..<6 {
            let time = 3.1 + Double(i) * 0.1
            let pose = try f.result(UInt64(20 + i), time, LiveVisionFixtures.standingPair)
            body.publish(pose, association: LiveVisionFixtures.association(pose, revision: stamp.bindingRevision),
                admission: CameraTrackingAdmission(context: f.context, revision: stamp.bindingRevision,
                                                   requestID: stamp.bindingRequest),
                acknowledgment: nil)
            let snapshot = try #require(body.latest, "frame \(i) published")
            for player in PlayerID.allCases {
                let sample = try #require(snapshot.players[player])
                #expect(sample.geometry.crownY.validity == .valid && sample.geometry.leftSoleY.validity == .valid
                    && sample.geometry.rightSoleY.validity == .valid, "\(player) head-top and soles")
                #expect(sample.jumpState.phase == .grounded && sample.jumpState.validity == .valid)
                // Head-top = nose 0.8 + measured offset 0.1 → 0.9 image → 1.6 game units.
                #expect(abs((sample.geometry.crownY.value ?? 0) - 1.6) < 1e-6)
            }
            try readiness.observe(snapshot, context: context, bindingConfirmed: true, at: time + 0.02)
        }
        #expect(readiness.phase == .ready, "live evidence admits the round")
    }

    /// Live frames through the provider: a whole-body hop after the accepted calibration becomes
    /// AIRBORNE in the published snapshot with valid soles above the floor, then lands. This is
    /// the evidence the laser judge and the mascot read; standing frames stay grounded.
    @Test func aLiveHopReachesTheSnapshotAsAirborne() throws {
        let (f, initial, stamp) = try LiveVisionFixtures.sessionFixture()
        var session = initial
        for i in 0..<10 {
            let pose = try f.result(UInt64(i + 3), Double(i) * 0.25 + 0.25, LiveVisionFixtures.standingPair)
            let started = session.beginSample(stamp, source: pose.source, at: pose.source.capturedAt)
            try #require(started)
            session.observe(LiveVisionFixtures.withAnatomy(LiveVisionFixtures.mask(pose), pose: pose, revision: stamp.bindingRevision),
                pose: pose, association: LiveVisionFixtures.association(pose, revision: stamp.bindingRevision),
                stamp: stamp, at: pose.source.capturedAt + 0.01)
        }
        var body = LiveBodyInputState()
        try body.configure(LiveVisionFixtures.configuration(f.context.generation), source: f.context)
        body.calibration = session
        _ = try body.accept(candidateID: try #require(session.candidate).id, expectedRevision: 0, at: 3)
        func lifted(_ dy: Double) -> [PoseCandidate] {
            LiveVisionFixtures.standingPair.map { c in
                .init(candidateID: c.candidateID, joints: c.joints.mapValues { .init(x: $0.x, y: $0.y + dy, confidence: $0.confidence) },
                      maskTopImageY: nil, maskBottomImageY: nil, leftFootBottomImageY: nil, rightFootBottomImageY: nil,
                      maskAssociation: .unavailable)
            }
        }
        var phases: [JumpPhase] = []
        for i in 0..<60 {
            let t = 3.1 + Double(i) / 30
            // Standing 1 s, then a 0.35 s hop of 0.05 image heights (~6 % of standing height).
            let dy = LiveBodyEstimateTests.hop(t, start: 4.1, duration: 0.35, peak: 0.05)
            let pose = try f.result(UInt64(20 + i), t, lifted(dy))
            body.publish(pose, association: LiveVisionFixtures.association(pose, revision: stamp.bindingRevision),
                admission: CameraTrackingAdmission(context: f.context, revision: stamp.bindingRevision,
                                                   requestID: stamp.bindingRequest),
                acknowledgment: nil)
            let sample = try #require(body.latest?.players[.player1])
            phases.append(sample.jumpState.phase)
            if sample.jumpState.phase == .airborne {
                #expect(sample.jumpState.validity == .valid && (sample.geometry.leftSoleY.value ?? 0) > 0.02)
            }
        }
        #expect(phases.prefix(30).allSatisfy { $0 == .grounded }, "standing is grounded")
        #expect(phases.contains(.airborne) && phases.contains(.landing))
        #expect(phases.last == .grounded)
    }
}
