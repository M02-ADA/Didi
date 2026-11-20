import Foundation
import Testing
@testable import Sedactive

/// StandingCollectionPolicyV1.2: a player is stable once 10 of their valid samples within the
/// existing 10 s span agree within the unchanged tolerance, all after the feet last moved, and at
/// least 60 % of the valid samples across their span. A head-top jump never restarts anything; a
/// real step does. Deterministic: explicit capture/host times, the real `CalibrationSession`.
nonisolated struct SpanMajorityCalibrationTests {
    /// The iPad's native instance-mask height: the 2-row tolerance is 2/384 of the image height.
    static let maskRows = 384
    static let row = 1.0 / Double(maskRows)
    static let crown = 0.9, sole = 0.1

    struct Reading {
        var crown = SpanMajorityCalibrationTests.crown
        var leftSole = SpanMajorityCalibrationTests.sole
        var rightSole = SpanMajorityCalibrationTests.sole
        var p2Tracking = true
        var p1Nose = true
        var solesValid = true
    }

    static func sample(_ i: Int, _ p1: Reading, p2: Reading = Reading(), session: inout CalibrationSession,
                       f: TrackingIntegrationFixture, stamp: CalibrationAdmission) throws {
        var candidates = LiveVisionFixtures.standingPair
        if !p1.p1Nose, let index = candidates.firstIndex(where: { $0.candidateID == 10 }) {
            let c = candidates[index]; var joints = c.joints; joints[.nose] = nil
            candidates[index] = .init(candidateID: c.candidateID, joints: joints, maskTopImageY: nil, maskBottomImageY: nil,
                leftFootBottomImageY: nil, rightFootBottomImageY: nil, maskAssociation: .unavailable)
        }
        let p = try f.result(UInt64(i + 3), 0.25 + Double(i) * 0.25, candidates)
        let admitted = session.beginSample(stamp, source: p.source, at: p.source.capturedAt)
        try #require(admitted, "sample \(i) admitted")
        var mask = LiveVisionFixtures.mask(p)
        mask.maskHeight = maskRows
        for (id, region) in mask.regions {
            let r = id == .player1 ? p1 : p2
            mask.anatomy[id] = .init(source: p.source, controlRevision: stamp.bindingRevision, candidateID: region.candidateID,
                crown: .init(imageY: r.crown, status: .experimental), leftSole: .init(imageY: r.leftSole, status: .experimental),
                rightSole: .init(imageY: r.rightSole, status: r.solesValid ? .experimental : .ambiguous))
        }
        var association = LiveVisionFixtures.association(p, revision: stamp.bindingRevision)
        if !p2.p2Tracking {
            association = .init(source: association.source, evaluatedAt: association.evaluatedAt,
                controlRevision: association.controlRevision, player1: association.player1,
                player2: .init(state: .lost, reason: .observationGap, candidateID: nil, cost: nil,
                               requiresRebind: false, lastConfirmedAt: p.source.capturedAt - 0.3),
                assignmentCount: 1, confirmedDescriptorCount: 2, provisionalDescriptorCount: 0)
        }
        session.observe(mask, pose: p, association: association, stamp: stamp, at: p.source.capturedAt + 0.01)
    }

    /// Feeds P1 `readings` (P2 still) until a candidate exists; returns its sample index, or nil.
    static func run(_ readings: [Reading], session: inout CalibrationSession,
                    f: TrackingIntegrationFixture, stamp: CalibrationAdmission) throws -> Int? {
        for (i, r) in readings.enumerated() {
            try sample(i, r, p2: Reading(p2Tracking: r.p2Tracking), session: &session, f: f, stamp: stamp)
            if session.phase == .candidateReady { return i }
        }
        return nil
    }

    static func run(_ readings: [Reading]) throws -> (index: Int?, session: CalibrationSession) {
        let (f, initial, stamp) = try LiveVisionFixtures.sessionFixture(); var session = initial
        return (try run(readings, session: &session, f: f, stamp: stamp), session)
    }

    static func shifted(_ rows: Double) -> Reading { Reading(crown: crown + rows * row) }
    static let jumped = shifted(6) // the iPad's 5–8 mask-row head-top jumps
    static let S = Reading()

    // MARK: Estimator jitter

    /// The iPad pattern: two jumps in a row on a still player. V1.1 restarted at the second jump.
    @Test func pairedHeadTopJumpsNoLongerRestartAndNeverEnterTheReference() throws {
        let (done, session) = try Self.run([Self.S, Self.S, Self.S, Self.jumped, Self.jumped] + Array(repeating: Self.S, count: 10))
        #expect(done == 11, "the 10th still sample completes (V1.1: sample 14)")
        let p1 = try #require(session.candidate?.players[.player1]?.anatomy)
        #expect(abs(p1.crownY - Self.crown) < 1e-12 && abs(p1.leftSoleY - Self.sole) < 1e-12)
        #expect(session.candidate?.samples == StandingCollectionPolicyV1.sampleCount)
        #expect(session.players[.player1]?.rejected[.moving] == 2, "each jump is still reported")
    }

    @Test func progressNeverFallsBackOnJumps() throws {
        let (done, session) = try Self.run(Array(repeating: Self.S, count: 7) + [Self.jumped, Self.jumped, Self.jumped])
        #expect(done == nil)
        #expect(session.players[.player1]?.samples == 7, "70 % stays 70 % (V1.1 restarted at 20–30 %)")
    }

    /// V1.1 already skipped isolated jumps; that stays (the 8-of-10 rule would refuse this).
    @Test func isolatedJumpsOnEveryThirdSampleStillComplete() throws {
        let (done, session) = try Self.run((0..<20).map { $0 % 3 == 2 ? Self.jumped : Self.S })
        #expect(done == 13, "as V1.1: the 10th still sample")
        #expect(abs((session.candidate?.players[.player1]?.anatomy?.crownY ?? 0) - Self.crown) < 1e-12)
    }

    // MARK: Real movement

    @Test func sustainedMovementNeverCompletes() throws {
        let (done, session) = try Self.run((0..<36).map { i in
            Reading(crown: Self.crown - Double(i) * 1.2 * Self.row, leftSole: Self.sole - Double(i) * 1.2 * Self.row,
                    rightSole: Self.sole - Double(i) * 1.2 * Self.row)
        })
        #expect(done == nil)
        #expect((session.players[.player1]?.samples ?? 0) <= 2 && (session.players[.player1]?.rejected[.moving] ?? 0) > 30)
    }

    @Test func aStepCalibratesOnlyAtTheNewPlaceAndNeverMixesPlaces() throws {
        let stepped = Reading(crown: Self.crown - 8 * Self.row, leftSole: Self.sole - 8 * Self.row,
                              rightSole: Self.sole - 8 * Self.row)
        let (done, session) = try Self.run(Array(repeating: Self.S, count: 6) + Array(repeating: stepped, count: 12))
        #expect(done == 6 + 9, "10 samples at the new place (as V1.1)")
        let p1 = try #require(session.candidate?.players[.player1]?.anatomy)
        #expect(abs(p1.crownY - stepped.crown) < 1e-12 && abs(p1.leftSoleY - stepped.leftSole) < 1e-12)
        // Half at each place never calibrates.
        let (mixed, _) = try Self.run(Array(repeating: Self.S, count: 8) + Array(repeating: stepped, count: 8))
        #expect(mixed == nil)
    }

    /// Stepping away (both feet move) and back: samples from before the step are stale evidence,
    /// even though they match the new ones. 10 fresh samples are needed after the return.
    @Test func samplesFromBeforeAStepAwayAndBackNeverCount() throws {
        let aside = Reading(crown: Self.crown - 8 * Self.row, leftSole: Self.sole - 8 * Self.row, rightSole: Self.sole - 8 * Self.row)
        let (early, _) = try Self.run(Array(repeating: Self.S, count: 9) + [aside, aside] + Array(repeating: Self.S, count: 8))
        #expect(early == nil, "9 before + 8 after match, but never combine across the step")
        let (done, session) = try Self.run(Array(repeating: Self.S, count: 9) + [aside, aside] + Array(repeating: Self.S, count: 10))
        #expect(done == 9 + 2 + 9, "10 samples after the return")
        #expect(abs((session.candidate?.players[.player1]?.anatomy?.crownY ?? 0) - Self.crown) < 1e-12)
    }

    /// The head alone dips for two samples (feet still): treated as noise, earlier samples kept.
    @Test func aBriefHeadOnlyDeviationKeepsTheEvidence() throws {
        let (done, session) = try Self.run(Array(repeating: Self.S, count: 9) + [Self.shifted(-40), Self.shifted(-40), Self.S])
        #expect(done == 11)
        #expect(abs((session.candidate?.players[.player1]?.anatomy?.crownY ?? 0) - Self.crown) < 1e-12)
    }

    /// One stray sole reading is noise (as in V1.1), not a step.
    @Test func aSingleStraySoleReadingIsNotAStep() throws {
        let stray = Reading(leftSole: Self.sole - 8 * Self.row)
        let (done, _) = try Self.run(Array(repeating: Self.S, count: 6) + [stray] + Array(repeating: Self.S, count: 6))
        #expect(done == 6 + 1 + 3, "the 10th still sample")
    }

    /// V1.2's step is "both soles elsewhere for two samples in a row" (pre-merge audit, 20 November
    /// 2026: the code counted one foot alone). One foot shifting and coming back is not a step: the
    /// evidence from before it is kept, and the shifted samples never enter the reference.
    @Test func oneFootShiftingAndBackIsNotAStep() throws {
        let oneFoot = Reading(leftSole: Self.sole - 8 * Self.row)
        let (done, session) = try Self.run(Array(repeating: Self.S, count: 9) + [oneFoot, oneFoot] + Array(repeating: Self.S, count: 10))
        #expect(done == 9 + 2, "the 10th still sample completes (counting one foot as a step: 9 + 2 + 9)")
        let p1 = try #require(session.candidate?.players[.player1]?.anatomy)
        #expect(abs(p1.leftSoleY - Self.sole) < 1e-12 && abs(p1.rightSoleY - Self.sole) < 1e-12, "the shifted foot never enters it")
    }

    /// One foot moved to stay: the player calibrates where they now stand; the two places never mix
    /// (that sole disagrees), and half at each place still never calibrates.
    @Test func oneFootMovedToStayCalibratesOnlyAtTheNewStance() throws {
        let stance = Reading(leftSole: Self.sole - 8 * Self.row)
        let (done, session) = try Self.run(Array(repeating: Self.S, count: 6) + Array(repeating: stance, count: 12))
        #expect(done == 6 + 9, "10 samples in the new stance")
        let p1 = try #require(session.candidate?.players[.player1]?.anatomy)
        #expect(abs(p1.leftSoleY - stance.leftSole) < 1e-12 && abs(p1.rightSoleY - Self.sole) < 1e-12)
        let (mixed, _) = try Self.run(Array(repeating: Self.S, count: 8) + Array(repeating: stance, count: 8))
        #expect(mixed == nil)
    }

    /// Both feet participating (a real step, away and back) still discards the earlier evidence.
    @Test func bothFeetMovingIsStillAStep() throws {
        let both = Reading(leftSole: Self.sole - 8 * Self.row, rightSole: Self.sole - 8 * Self.row)
        let (early, _) = try Self.run(Array(repeating: Self.S, count: 9) + [both, both] + Array(repeating: Self.S, count: 8))
        #expect(early == nil, "never combined across the step")
    }

    /// Sole jitter within tolerance on either foot, alternating feet, is neither movement nor a step.
    @Test func soleJitterWithinToleranceIsNotAStep() throws {
        let readings = (0..<10).map { i in
            Reading(leftSole: Self.sole + (i % 2 == 0 ? 1 : 0) * Self.row, rightSole: Self.sole + (i % 2 == 1 ? 1 : 0) * Self.row)
        }
        let (done, session) = try Self.run(readings)
        #expect(done == 9)
        #expect((session.players[.player1]?.rejected[.moving] ?? 0) == 0)
    }

    // MARK: Alternating readings

    /// An estimate alternating evenly between two head-tops is not a reference, either way.
    @Test func evenAlternationNeverCalibrates() throws {
        let (done, session) = try Self.run((0..<36).map { $0 % 2 == 0 ? Self.S : Self.jumped })
        #expect(done == nil, "V1.1 calibrated this on whichever reading it happened to keep")
        #expect((session.players[.player1]?.samples ?? 0) < StandingCollectionPolicyV1.sampleCount)
    }

    /// A clear majority (two readings in three) is the reference; the minority never enters it.
    @Test func aClearMajorityReadingIsTheReference() throws {
        let (done, session) = try Self.run((0..<30).map { $0 % 3 == 1 ? Self.jumped : Self.S })
        #expect(done != nil)
        #expect(abs((session.candidate?.players[.player1]?.anatomy?.crownY ?? 0) - Self.crown) < 1e-12)
    }

    // MARK: Accuracy

    @Test func toleranceAndSampleCountAreUnchanged() throws {
        let (done, session) = try Self.run((0..<12).map { $0 % 2 == 0 ? Self.S : Self.shifted(2) })
        #expect(done == 9, "10 samples within 2 rows")
        #expect(abs((session.candidate?.players[.player1]?.anatomy?.crownY ?? 0) - (Self.crown + Self.row)) < 1e-12)
        let (wide, _) = try Self.run((0..<16).map { $0 % 2 == 0 ? Self.S : Self.shifted(2.01) })
        #expect(wide == nil, "readings 2.01 rows apart never count together")
    }

    // MARK: Existing safety checks

    /// Soles that are not a usable estimate refuse the sample (never counted), as before.
    @Test func invalidSolesNeverCount() throws {
        let (done, session) = try Self.run(Array(repeating: Self.S, count: 5) + Array(repeating: Reading(solesValid: false), count: 4)
            + Array(repeating: Self.S, count: 6))
        #expect(done == 5 + 4 + 4, "only the 10 valid samples")
        #expect((session.players[.player1]?.accepted ?? 0) == 10)
    }

    /// A frame older than the sample freshness is never sampled; a result arriving after it is
    /// stale is ignored, as before.
    @Test func staleObservationsNeverCount() throws {
        let (f, initial, stamp) = try LiveVisionFixtures.sessionFixture(); var session = initial
        let old = try f.result(3, 0.25, LiveVisionFixtures.standingPair)
        let staleAdmitted = session.beginSample(stamp, source: old.source, at: 0.25 + StandingCollectionPolicyV1.sampleFreshness)
        #expect(!staleAdmitted)
        let late = try f.result(4, 0.5, LiveVisionFixtures.standingPair)
        let lateAdmitted = session.beginSample(stamp, source: late.source, at: 0.5)
        try #require(lateAdmitted)
        var mask = LiveVisionFixtures.withAnatomy(LiveVisionFixtures.mask(late), pose: late, revision: stamp.bindingRevision)
        mask.maskHeight = Self.maskRows
        session.observe(mask, pose: late, association: LiveVisionFixtures.association(late, revision: stamp.bindingRevision),
                        stamp: stamp, at: 0.5 + StandingCollectionPolicyV1.sampleFreshness)
        #expect(session.players[.player1]?.accepted == nil && session.count == 0)
    }

    @Test func invalidTrackingAndInvalidLandmarksNeverCount() throws {
        let (done, session) = try Self.run(Array(repeating: Self.S, count: 7) + [Reading(p2Tracking: false)]
            + Array(repeating: Self.S, count: 12))
        #expect(done == 7 + 10, "P2's identity failure clears only P2, who needs 10 fresh samples")
        #expect(session.players[.player2]?.rejected[.trackingLost] == 1)
        let (faceless, noFace) = try Self.run(Array(repeating: Self.S, count: 4) + Array(repeating: Reading(p1Nose: false), count: 6)
            + Array(repeating: Self.S, count: 8))
        #expect(faceless == 15, "only the 10 valid samples count")
        #expect(noFace.players[.player1]?.rejected[.faceNotVisible] == 6)
    }

    // MARK: Repeated sessions

    @Test func repeatedCalibrationSessionsStartEmptyAndCalibrateTheSameWay() throws {
        let (f, initial, stamp) = try LiveVisionFixtures.sessionFixture(); var session = initial
        let readings = [Self.S, Self.jumped, Self.jumped] + Array(repeating: Self.S, count: 10)
        #expect(try Self.run(readings, session: &session, f: f, stamp: stamp) == 11)
        session.consumed()
        for round in 2...4 {
            session.resetForNewSession()
            #expect(session.count == 0 && session.players.isEmpty, "round \(round) starts empty")
            let request = try #require(f.gate.snapshot.requestID)
            _ = try session.request(id: UUID(), source: f.context, revision: f.gate.snapshot.revision,
                                    bindingRequest: request, at: 0.125)
            let next = try #require(session.admission)
            #expect(try Self.run(readings, session: &session, f: f, stamp: next) == 11, "round \(round)")
            #expect(abs((session.candidate?.players[.player1]?.anatomy?.crownY ?? 0) - Self.crown) < 1e-12)
            session.consumed()
        }
    }

    // MARK: Cost

    /// Worst case for the agreement search (it runs inside the tracking gate's lock): 40 retained
    /// samples (the 10 s span at 4 Hz), every reading distinct, none forming 10 within tolerance
    /// of each other on all three channels at once. Debug build, Simulator.
    @Test func agreementSearchStaysCheapAtTheRetentionBound() throws {
        let (f, initial, stamp) = try LiveVisionFixtures.sessionFixture(); var session = initial
        var slowest = 0.0
        for i in 0..<40 {
            // Crown and soles cycle out of phase, a fifth of a row apart: dense, distinct values.
            let r = Reading(crown: Self.crown + Double(i % 13) * 0.21 * Self.row,
                            leftSole: Self.sole + Double((i * 7) % 11) * 0.23 * Self.row,
                            rightSole: Self.sole + Double((i * 5) % 17) * 0.17 * Self.row)
            let start = CameraHostClock.now()
            try Self.sample(i, r, session: &session, f: f, stamp: stamp)
            slowest = max(slowest, CameraHostClock.now() - start)
            if session.phase == .candidateReady { break }
        }
        print(String(format: "[SpanMajority] slowest observe at the retention bound: %.2f ms", slowest * 1000))
        #expect(slowest < 0.02, "well inside a 33 ms camera frame")
    }

    // MARK: Never harder than V1.1

    /// V1.1's window rule (`StandingCollectionPolicyV1.1`), on head-top readings only: a reading
    /// within tolerance of the window joins it; otherwise two agreeing outliers in a row restart
    /// the window from themselves; complete at 10. Returns the completing index, or nil.
    static func v11(_ crowns: [Double], tolerance: Double) -> (index: Int, share: Double)? {
        var window: [(c: Double, i: Int)] = [], outlier: (c: Double, i: Int)?
        func spread(_ v: [Double]) -> Double { (v.max() ?? 0) - (v.min() ?? 0) }
        for (i, c) in crowns.enumerated() {
            if spread(window.map(\.c) + [c]) <= tolerance + 1e-9 { window.append((c, i)); outlier = nil }
            else if let o = outlier, spread([o.c, c]) <= tolerance + 1e-9 { window = [o, (c, i)]; outlier = nil }
            else { outlier = (c, i) }
            if window.count > 10 { window.removeFirst(window.count - 10) }
            if window.count == 10 { return (i, 10.0 / Double(i - window[0].i + 1)) }
        }
        return nil
    }

    /// 300 seeded sequences of still readings, ±1 row noise, 6-row jumps (alone or in runs) and
    /// head-only steps: whenever V1.1 completes from readings that were at least 60 % of their
    /// span, V1.2 completes no later. (Below that share V1.1 calibrated on an alternating estimate;
    /// V1.2 refuses that on purpose.) The reference is always within tolerance of the readings.
    @Test func neverHarderThanV11WhereV11WasSound() throws {
        var rng = SplitMix(seed: 0x5EDAC71)
        var earlier = 0, same = 0, onlyV12 = 0, refusedAlternation = 0
        for _ in 0..<300 {
            var offset = 0.0, crowns: [Double] = []
            while crowns.count < 30 {
                switch rng.next() % 10 {
                case 0: offset += Double(rng.next() % 9) - 4 // a step of up to 4 rows
                case 1, 2: for _ in 0..<Int(1 + rng.next() % 3) { crowns.append(Self.crown + (offset + 6) * Self.row) }; continue
                default: break
                }
                crowns.append(Self.crown + (offset + Double(rng.next() % 3) - 1) * Self.row / 2)
            }
            crowns = Array(crowns.prefix(30))
            let old = Self.v11(crowns, tolerance: 2 * Self.row)
            let (new, session) = try Self.run(crowns.map { Reading(crown: $0) })
            if let old, old.share >= StandingCollectionPolicyV1.minimumAgreeingShare {
                let new = try #require(new, "V1.1 completed at \(old.index) but V1.2 did not: \(crowns)")
                #expect(new <= old.index)
                if new < old.index { earlier += 1 } else { same += 1 }
            } else if old != nil, new == nil { refusedAlternation += 1 }
            else if old == nil, new != nil { onlyV12 += 1 }
            if new != nil, let p1 = session.candidate?.players[.player1]?.anatomy {
                // The reference is a mean of readings within the tolerance of each other.
                #expect(crowns.contains { abs($0 - p1.crownY) <= 2 * Self.row + 1e-9 })
            }
        }
        print("[SpanMajority] V1.2 vs V1.1 on 300 sequences: earlier \(earlier) · same \(same) · only V1.2 \(onlyV12) · V1.1 below 60 % refused \(refusedAlternation)")
    }
}

/// A tiny deterministic generator (SplitMix64) so the property test is reproducible.
nonisolated struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
