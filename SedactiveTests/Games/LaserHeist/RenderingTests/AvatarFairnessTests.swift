import Foundation
import RealityKit
import Testing
@testable import Sedactive

/// K04 synthetic visual fairness: one SYNTHETIC human body drives both the
/// authoritative `LaserCollisionJudge` (CP1-shaped sample) and the avatar
/// (K03 packet from the same numbers), against bands from the real
/// `LaserWaveDirector`. The shown side is measured on the actual solved rig.
/// Evidence for the PENDING D07 policy; not a fairness acceptance.
@MainActor
struct AvatarFairnessTests {
    // MARK: Synthetic human

    /// Pose of one synthetic person, in their own game units.
    struct Pose {
        /// Crown drop as a share of standing height; the hips drop 75% of it (the rest is torso flex).
        var crownDrop = 0.0
        /// Absolute wrist heights; `nil` hangs the arm.
        var leftWristY: Double?
        var rightWristY: Double?
        var lift = 0.0
        var leftFootRaise = 0.0
        var rightFootRaise = 0.0
        /// `nil`: airborne exactly when both soles are off the floor.
        var airborne: Bool?
        var leftWristValidity = EvidenceValidity.valid
        var tracking = TrackingStatus.reliable
        /// The calibration revision the body evidence and the packet carry (accepted: 1).
        var calibrationRevision: UInt64 = 1
    }

    static let layout = try! PlayerPlaneLayout.decodeForTests(leftCenterX: -0.65, rightCenterX: 0.65, unitsPerImageHeight: 2)
    static let aspect = 1.5, floorImageY = 0.1
    static let generation = UUID(uuidString: "F4000000-0000-4000-8000-000000000001")!
    static let context = AvatarSourceContext(generation: generation, epoch: UUID(uuidString: "F4000000-0000-4000-8000-000000000002")!,
                                             geometryRevision: 1, imageWidth: 1620, imageHeight: 1080, rotationAngle: 0, mirrored: false)

    static func mapping(_ player: PlayerID) -> ImageToPlayerPlaneMapping {
        try! JSONDecoder().decode(ImageToPlayerPlaneMapping.self, from: Data("""
            {"imageAspectRatio": \(aspect), "floorImageY": \(floorImageY), "originImageX": \(player == .player1 ? 0.7 : 0.3)}
            """.utf8))
    }

    static func calibration(_ player: PlayerID, height: Double) throws -> PlayerCalibration {
        let u = layout.gameUnitsPerImageHeight
        let c = PlayerCalibration(playerID: player, sessionGeneration: generation, revision: 1, cameraGeometryRevision: 1,
                                  sourceFrameID: 0, capturedAt: 0, standingCrownImageY: floorImageY + height / u,
                                  standingLeftSoleImageY: floorImageY, standingRightSoleImageY: floorImageY,
                                  standingHipImageY: floorImageY + 0.52 * height / u, standingBodyImageHeight: height / u,
                                  standingTorsoImageLength: 0.3 * height / u, headOffsetFromNoseShare: 0.07,
                                  leftFootOffsetShare: 0.04, rightFootOffsetShare: 0.04, mapping: mapping(player))
        try c.validate()
        return c
    }

    /// Player-plane joints (game units; anatomical left at +x, unmirrored) and CP1-shaped geometry.
    static func body(_ player: PlayerID, height h: Double, _ pose: Pose) throws
        -> (joints: [BodyJoint: (Double, Double)], geometry: BodyGeometry, jump: JumpState) {
        let lane = layout.centerX(for: player)
        let c = pose.crownDrop * h, hipDrop = 0.75 * c, up = pose.lift
        let shoulderY = 0.81 * h - c + up
        let hang = shoulderY - 0.34 * h
        let lw = pose.leftWristY ?? hang, rw = pose.rightWristY ?? hang
        let wristX = { (y: Double) in y > shoulderY ? 0.17 * h : 0.14 * h }
        var j: [BodyJoint: (Double, Double)] = [
            .nose: (lane, 0.93 * h - c + up), .leftEye: (lane + 0.02 * h, 0.945 * h - c + up), .rightEye: (lane - 0.02 * h, 0.945 * h - c + up),
            .leftEar: (lane + 0.04 * h, 0.92 * h - c + up), .rightEar: (lane - 0.04 * h, 0.92 * h - c + up), .neck: (lane, 0.85 * h - c + up),
            .leftShoulder: (lane + 0.11 * h, shoulderY), .rightShoulder: (lane - 0.11 * h, shoulderY),
            .leftWrist: (lane + wristX(lw), lw), .rightWrist: (lane - wristX(rw), rw),
            .leftHip: (lane + 0.06 * h, 0.52 * h - hipDrop + up), .rightHip: (lane - 0.06 * h, 0.52 * h - hipDrop + up),
            .leftAnkle: (lane + 0.06 * h, 0.04 * h + up + pose.leftFootRaise), .rightAnkle: (lane - 0.06 * h, 0.04 * h + up + pose.rightFootRaise),
        ]
        if pose.leftWristValidity != .valid { j[.leftWrist] = nil }
        func v(_ x: Double) throws -> EstimatedScalar { try EstimatedScalar(value: x, validity: .valid) }
        let leftSole = up + pose.leftFootRaise, rightSole = up + pose.rightFootRaise
        let geometry = BodyGeometry(
            crownY: try v(h - c + up),
            leftWristY: pose.leftWristValidity == .valid ? try v(lw) : try EstimatedScalar(value: nil, validity: pose.leftWristValidity),
            rightWristY: try v(rw), leftSoleY: try v(leftSole), rightSoleY: try v(rightSole), centerX: try v(lane))
        let airborne = pose.airborne ?? (min(leftSole, rightSole) > 0.01 * h)
        return (j, geometry, JumpState(phase: airborne ? .airborne : .grounded, validity: .valid))
    }

    // MARK: Bands (the real director) and the judge

    static func targets(heights: [PlayerID: Double], move: LaserMove) throws -> [PlayerID: LaserTarget] {
        Dictionary(uniqueKeysWithValues: try encounter(heights: heights, move: move).targets.map { ($0.playerID, $0) })
    }

    static func encounter(heights: [PlayerID: Double], move: LaserMove) throws -> LaserEncounter {
        let calibrations = try Dictionary(uniqueKeysWithValues: heights.map { ($0.key, try calibration($0.key, height: $0.value)) })
        let configuration = try LaserRoundConfiguration(
            evidenceTiming: LaserEvidenceTiming(windowBefore: 0.35, windowAfter: 0.25, deliveryAllowance: 0.1),
            clearanceMargin: 0.005, diamondPoints: nil,
            scheduling: LaserSchedulingConfiguration(players: [.player1: .conservativeCandidate, .player2: .conservativeCandidate],
                                                     searchStep: 0.25, maximumSearchSteps: 200))
        let beat = LaserWaveBeat(id: UUID(), move: move, nominalCrossingTime: 10, segmentEnd: 60)
        let schedule = try LaserWaveDirector().schedule(script: [beat], calibrations: calibrations, layout: layout, configuration: configuration)
        return try #require(schedule.encounters.first)
    }

    static func judge(_ target: LaserTarget, geometry: BodyGeometry, jump: JumpState, tracking: TrackingStatus,
                      calibrationRevision: UInt64 = 1) throws -> Judgement? {
        let sample = PlayerBodySample(playerID: target.playerID, calibrationRevision: calibrationRevision, trackingStatus: tracking,
                                      geometry: geometry, jumpState: jump)
        let snapshot = BodySnapshot(sessionGeneration: generation, frameID: 100, capturedAt: target.crossingTime,
                                    cameraGeometryRevision: 1, players: [target.playerID: sample])
        let evidence = LaserBodyEvidence(snapshot: snapshot, capturedGameTime: target.crossingTime, arrivedGameTime: target.crossingTime)
        let context = BodyInputContext(sessionGeneration: generation, cameraGeometryRevision: 1,
                                       calibrationRevisions: [.player1: 1, .player2: 1], cutovers: [:], isActive: true)
        return try LaserCollisionJudge().judge(target: target, selection: .selected(evidence), clearanceMargin: 0.005, context: context)
    }

    // MARK: The avatar side (K03 packets, actual rig)

    static func packet(frame: UInt64, time: Double, heights: [PlayerID: Double],
                       bodies: [PlayerID: (joints: [BodyJoint: (Double, Double)], geometry: BodyGeometry, tracking: TrackingStatus)],
                       calibrationRevisions: [PlayerID: UInt64] = [:])
        -> AvatarSourceOutput {
        let u = layout.gameUnitsPerImageHeight
        var candidates: [PoseCandidate] = []
        var calibration: [PlayerID: AvatarCalibrationInput] = [:]
        var slots: [PlayerID: AvatarTrackedSlot] = [:]
        for player in PlayerID.allCases {
            guard let body = bodies[player], let h = heights[player], body.tracking == .reliable else {
                slots[player] = AvatarTrackedSlot(state: .lost, candidateID: nil, requiresRebind: false)
                continue
            }
            let lane = layout.centerX(for: player), m = mapping(player)
            let id: UInt64 = player == .player1 ? 1 : 2
            // Joints that leave the camera image are missing, as B1 would report them.
            let image = body.joints.mapValues { (($0.0 - lane) / (aspect * u) + m.originImageX, $0.1 / u + floorImageY) }
                .filter { (0...1).contains($0.value.0) && (0...1).contains($0.value.1) }
            candidates.append(PoseCandidate(candidateID: id, joints: image.mapValues {
                PoseJoint(x: $0.0, y: $0.1, confidence: 0.9)
            }, maskTopImageY: nil, maskBottomImageY: nil, leftFootBottomImageY: nil, rightFootBottomImageY: nil, maskAssociation: .unavailable))
            slots[player] = AvatarTrackedSlot(state: .tracking, candidateID: id, requiresRebind: false)
            calibration[player] = AvatarCalibrationInput(
                revision: calibrationRevisions[player] ?? 1, mapping: m, standingCrownImageY: floorImageY + h / u, standingHipImageY: floorImageY + 0.52 * h / u,
                standingLeftAnkleImageY: floorImageY + 0.04 * h / u, standingRightAnkleImageY: floorImageY + 0.04 * h / u,
                visual: body.geometry)
        }
        return AvatarSourceOutput(source: AvatarSourceFrame(context: context, frameID: frame, capturedAt: time, controlRevision: 1),
                                  contextRevision: 1, player1: slots[.player1]!, player2: slots[.player2]!,
                                  candidates: candidates, calibration: calibration)
    }

    static var status: AvatarSourceStatus {
        AvatarSourceStatus(revision: 1, isActive: true, context: context, controlRevision: 1, layout: layout,
                           calibrations: [.player1: AvatarCalibrationStatus(revision: 1, cutover: BodyInputCutover(frameID: 0, capturedAt: 0)),
                                          .player2: AvatarCalibrationStatus(revision: 1, cutover: BodyInputCutover(frameID: 0, capturedAt: 0))])
    }

    struct Case {
        let name: String
        let move: LaserMove
        let height: Double
        let pose: Pose
    }

    struct Result {
        let name: String
        let height: Double
        let comparison: AvatarFairness.Comparison
        let extremities: AvatarExtremities
        /// Where P1's gate was actually drawn (game units).
        let drawn: ClosedRange<Float>
        let normalized: Bool
    }

    /// Holds one pose for a second (settled), then shows the encounter just
    /// before its crossing through the real presenter and compares the posed
    /// rig with the gate as drawn. P1 runs the case; P2 stands at 1.6.
    /// `normalized`: the D07 candidate (`normalizesLaserBands`) on.
    func run(_ c: Case, normalized: Bool = false) async throws -> Result {
        let heights: [PlayerID: Double] = [.player1: c.height, .player2: 1.6]
        let encounter = try Self.encounter(heights: heights, move: c.move)
        let target = try #require(encounter.targets.first { $0.playerID == .player1 })
        let p1 = try Self.body(.player1, height: c.height, c.pose)
        let p2 = try Self.body(.player2, height: 1.6, Pose())
        let scene = LaserScene()
        let layer = RobotAvatarLayer(scene: scene, players: Set(PlayerID.allCases), templates: try await RobotAvatarLayer.sharedTemplates())
        layer.normalizesLaserBands = normalized
        scene.robotAvatars = layer
        let mailbox = AvatarPoseMailbox(maxAge: 0.25)
        mailbox.publish(Self.status)
        for n in 1...30 {
            let t = Double(n) / 30
            mailbox.offer(Self.packet(frame: UInt64(n), time: t, heights: heights,
                                      bodies: [.player1: (p1.joints, p1.geometry, c.pose.tracking), .player2: (p2.joints, p2.geometry, .reliable)],
                                      calibrationRevisions: [.player1: c.pose.calibrationRevision]))
            layer.apply(mailbox.drain(now: t + 0.005), now: t + 0.005)
        }
        // The gate as the presenter draws it, just before the crossing.
        let presenter = GameplayScenePresenter(scene: scene, configuration: try LaserReplayScript.load().configuration, encounters: [encounter])
        let pending = Dictionary(uniqueKeysWithValues: PlayerID.allCases.map { ($0, Judgement.pending(.awaitingFinalization)) })
        presenter.apply(state: LaserGameState(sessionGeneration: Self.generation, phase: .activity, gameTime: target.crossingTime - 0.05,
                                              activityProgress: 0, teamHealth: 5, teamScore: 0,
                                              encounters: [LaserEncounterState(encounter: encounter, judgements: pending, effectsCommitted: false)]),
                        events: [], snapshot: nil)
        let key = LaserTargetKey(encounterID: encounter.id, attemptID: encounter.attemptID, playerID: .player1)
        let drawn = try #require(presenter.hazard(for: key)?.band)
        #expect(drawn == presenter.displayedBand(target))
        let verdict = try Self.judge(target, geometry: p1.geometry, jump: p1.jump, tracking: c.pose.tracking,
                                     calibrationRevision: c.pose.calibrationRevision)
        let extremities = try #require(layer.extremities(of: .player1, mapping: scene.mapping))
        presenter.stop()
        layer.remove()
        return Result(name: c.name, height: c.height,
                      comparison: AvatarFairness.compare(target: target, authoritative: verdict, geometry: p1.geometry,
                                                         extremities: extremities, displayedBand: drawn),
                      extremities: extremities, drawn: drawn, normalized: normalized)
    }

    static func describe(_ j: Judgement?) -> String {
        switch j {
        case .clear?: "CLEAR"
        case .hit?: "HIT"
        case .unavailable?: "UNAVAILABLE"
        case .pending?: "PENDING"
        case nil: "WITHDRAWN"
        }
    }

    func report(_ r: Result) {
        let c = r.comparison
        print(String(format: "K04 %@ | %-34@ | H %.2f | %@ | %-11@ | drawn %.3f–%.3f | human %+.3f | shown %+.3f | head %.3f hands %.3f/%.3f soles %.3f/%.3f",
                     r.normalized ? "B" : "A", r.name, r.height, "\(c.move)", Self.describe(c.authoritative),
                     r.drawn.lowerBound, r.drawn.upperBound, c.humanMargin ?? .nan, c.shownMargin,
                     r.extremities.headTopY, r.extremities.leftHandY, r.extremities.rightHandY,
                     r.extremities.leftSoleY, r.extremities.rightSoleY) + " | " + c.agreement.rawValue)
    }

    // MARK: The K04 table

    /// Why a case is expected to disagree (each is a PENDING D06/D07 policy, not a defect).
    enum Cause: String {
        case none
        case equalSizeShorter = "D07: equal 1.6 m mascot, shorter player (band in the player's units)"
        case equalSizeTaller = "D07: equal 1.6 m mascot, taller player"
        case armEnvelope = "D07: outward-arm envelope + mascot reach keep the hand below a raised wrist"
        case noJumpPhase = "D06: the packet carries no jump phase; the avatar shows the soles' lift"
        case unavailable = "not judged (UNAVAILABLE); the avatar holds/fades and dims"
    }

    struct Row {
        let c: Case
        /// A: current mapping (beams drawn at the judged band).
        let expected: AvatarFairness.Agreement
        let cause: Cause
        /// B: the D07 normalized candidate. The equal-size causes resolve; the others remain.
        var expectedNormalized: AvatarFairness.Agreement {
            cause == .equalSizeShorter || cause == .equalSizeTaller ? .agrees : expected
        }
    }

    static var rows: [Row] {
        var rows: [Row] = []
        for h in [1.0, 1.3, 1.6, 1.75] {
            let shorter = h < 1.6, taller = h > 1.6
            rows.append(Row(c: Case(name: "duck: standing (no duck)", move: .duck, height: h, pose: Pose()),
                            expected: taller ? .avatarLooksClear : .agrees, cause: taller ? .equalSizeTaller : .none))
            rows.append(Row(c: Case(name: "duck: just enough", move: .duck, height: h, pose: Pose(crownDrop: 0.08 + 0.01 / h)),
                            expected: shorter ? .avatarLooksHit : .agrees, cause: shorter ? .equalSizeShorter : .none))
            rows.append(Row(c: Case(name: "duck: deep", move: .duck, height: h, pose: Pose(crownDrop: 0.2)),
                            expected: shorter ? .avatarLooksHit : .agrees, cause: shorter ? .equalSizeShorter : .none))
            rows.append(Row(c: Case(name: "jump: standing", move: .jump, height: h, pose: Pose()), expected: .agrees, cause: .none))
            rows.append(Row(c: Case(name: "jump: just clear", move: .jump, height: h, pose: Pose(lift: 0.02 * h + 0.01)),
                            expected: .agrees, cause: .none))
            rows.append(Row(c: Case(name: "jump: high", move: .jump, height: h, pose: Pose(lift: 0.15 * h)), expected: .agrees, cause: .none))
        }
        rows += [
            Row(c: Case(name: "duck deep, left wrist up", move: .duck, height: 1.6, pose: Pose(crownDrop: 0.2, leftWristY: 1.7)),
                expected: .avatarLooksClear, cause: .armEnvelope),
            Row(c: Case(name: "duck deep, left wrist at band", move: .duck, height: 1.6, pose: Pose(crownDrop: 0.2, leftWristY: 1.48)),
                expected: .avatarLooksClear, cause: .armEnvelope),
            Row(c: Case(name: "jump, left foot lower (hit)", move: .jump, height: 1.6, pose: Pose(lift: 0.1, leftFootRaise: -0.09)),
                expected: .agrees, cause: .none),
            Row(c: Case(name: "jump, one foot raised (grounded)", move: .jump, height: 1.6, pose: Pose(rightFootRaise: 0.1)),
                expected: .agrees, cause: .none),
            Row(c: Case(name: "soles up but not airborne", move: .jump, height: 1.6, pose: Pose(lift: 0.1, airborne: false)),
                expected: .avatarLooksClear, cause: .noJumpPhase),
            Row(c: Case(name: "duck, left wrist missing", move: .duck, height: 1.6,
                        pose: Pose(crownDrop: 0.2, leftWristValidity: .missingLandmarks)), expected: .notJudged, cause: .unavailable),
            Row(c: Case(name: "tracking lost", move: .duck, height: 1.6, pose: Pose(crownDrop: 0.2, tracking: .lost)),
                expected: .notJudged, cause: .unavailable),
            Row(c: Case(name: "calibration incompatible", move: .duck, height: 1.3, pose: Pose(crownDrop: 0.2, calibrationRevision: 2)),
                expected: .notJudged, cause: .unavailable),
            Row(c: Case(name: "duck, both wrists below crown", move: .duck, height: 1.3,
                        pose: Pose(crownDrop: 0.15, leftWristY: 0.9, rightWristY: 0.6)), expected: .avatarLooksHit, cause: .equalSizeShorter),
        ]
        return rows
    }

    /// Every case's agreement is as recorded, with its cause, for A (current
    /// mapping) and B (the normalized candidate); both tables are printed (`K04 A|B |`).
    @Test(arguments: [false, true])
    func fairnessTableMatchesTheRecordedAgreements(normalized: Bool) async throws {
        for row in Self.rows {
            let result = try await run(row.c, normalized: normalized)
            report(result)
            let expected = normalized ? row.expectedNormalized : row.expected
            #expect(result.comparison.agreement == expected,
                    "\(normalized ? "B" : "A") \(row.c.name) H \(row.c.height): \(result.comparison.agreement) (expected \(expected); \(row.cause.rawValue))")
        }
    }

    /// B draws each player's band scaled by exactly the avatar's motion scale
    /// (floor at 0, per player, no double scaling); A draws the judged band. The
    /// judged band itself, the lanes and the gate depth are the same in both;
    /// a direction-only (uncalibrated) player keeps the judged band.
    @Test func normalizedBandsScaleOnlyTheDrawnHeightPerPlayer() async throws {
        for h in [1.0, 1.3, 1.75] {
            let a = try await run(Case(name: "band A", move: .duck, height: h, pose: Pose()), normalized: false)
            let b = try await run(Case(name: "band B", move: .duck, height: h, pose: Pose()), normalized: true)
            let target = try #require(try Self.targets(heights: [.player1: h, .player2: 1.6], move: .duck)[.player1])
            #expect(a.drawn == Float(target.beam.lowerY)...Float(target.beam.upperY))
            let scale = Float(RobotAvatarLayer.standingHeight) / Float(h)
            #expect(abs(b.drawn.lowerBound - a.drawn.lowerBound * scale) < 1e-4 && abs(b.drawn.upperBound - a.drawn.upperBound * scale) < 1e-4)
        }
        let uncalibrated = try await run(Case(name: "band B, uncalibrated", move: .duck, height: 1.3, pose: Pose(calibrationRevision: 2)),
                                         normalized: true)
        let target = try #require(try Self.targets(heights: [.player1: 1.3, .player2: 1.6], move: .duck)[.player1])
        #expect(uncalibrated.drawn == Float(target.beam.lowerY)...Float(target.beam.upperY))
    }

    /// At the mascot's own height the shown margin equals the human margin
    /// (duck and jump), so the avatar agrees right up to the boundary.
    @Test func atMatchedHeightTheShownMarginTracksTheHumanMargin() async throws {
        for (move, pose) in [(LaserMove.duck, Pose(crownDrop: 0.08 + 0.01 / 1.6)), (.jump, Pose(lift: 0.02 * 1.6 + 0.01)),
                             (.duck, Pose(crownDrop: 0.08 + 0.002 / 1.6)), (.jump, Pose(lift: 0.02 * 1.6 + 0.002))] {
            let r = try await run(Case(name: "matched \(move)", move: move, height: 1.6, pose: pose))
            report(r)
            #expect(r.comparison.agreement == .agrees)
            #expect(abs(r.comparison.shownMargin - (r.comparison.humanMargin ?? .nan)) < 0.003, "\(move)")
        }
    }

    // MARK: Smoothing and display delay

    /// With render-rate smoothing (as the demo and lab use), a fast duck that
    /// clears a matched-height band: how long after the human evidence first
    /// clears does the shown avatar clear? Recorded, not judged against a limit.
    @Test func smoothingDelayIsMeasured() async throws {
        let heights: [PlayerID: Double] = [.player1: 1.6, .player2: 1.6]
        let target = try #require(try Self.targets(heights: heights, move: .duck)[.player1])
        let layer = RobotAvatarLayer(scene: LaserScene(), players: Set(PlayerID.allCases), templates: try await RobotAvatarLayer.sharedTemplates())
        layer.smoothing = 0.03
        let mailbox = AvatarPoseMailbox(maxAge: 0.25)
        mailbox.publish(Self.status)
        var humanClearAt: Double?, shownClearAt: Double?
        var frame: UInt64 = 0
        for tick in 0..<120 {  // 60 Hz render, 30 Hz frames; the duck takes 0.3 s from t = 0.5
            let now = Double(tick) / 60
            if tick % 2 == 0 {
                frame += 1
                let drop = 0.2 * min(1, max(0, (now - 0.5) / 0.3))
                let p1 = try Self.body(.player1, height: 1.6, Pose(crownDrop: drop))
                let p2 = try Self.body(.player2, height: 1.6, Pose())
                mailbox.offer(Self.packet(frame: frame, time: now, heights: heights,
                                          bodies: [.player1: (p1.joints, p1.geometry, .reliable), .player2: (p2.joints, p2.geometry, .reliable)]))
                if humanClearAt == nil, (AvatarFairness.humanMargin(move: .duck, band: target.beam, geometry: p1.geometry) ?? -1) > 0.005 {
                    humanClearAt = now
                }
            }
            layer.apply(mailbox.drain(now: now), now: now)
            layer.render(now: now)
            if shownClearAt == nil, let e = layer.extremities(of: .player1, mapping: LaserScene().mapping),
               AvatarFairness.shownMargin(move: .duck, band: target.beam, extremities: e) > 0 { shownClearAt = now }
        }
        let human = try #require(humanClearAt), shown = try #require(shownClearAt)
        print(String(format: "K04 | smoothing 30 ms, 30 Hz frames, 60 Hz render: human clears at %.3f s, avatar shown clear at %.3f s (lag %.0f ms)",
                     human, shown, (shown - human) * 1000))
        #expect(shown >= human)  // never shown clear before the evidence
        layer.remove()
    }

    // MARK: Diagnostic overlay

    /// The `-avatarFairness` markers sit on the measured extremities and leave with the avatars.
    @Test func fairnessMarkersFollowTheExtremitiesAndAreRemoved() async throws {
        let scene = LaserScene()
        let layer = RobotAvatarLayer(scene: scene, players: Set(PlayerID.allCases), templates: try await RobotAvatarLayer.sharedTemplates())
        layer.showsFairnessMarkers = true
        let mailbox = AvatarPoseMailbox(maxAge: 0.25)
        mailbox.publish(Self.status)
        let heights: [PlayerID: Double] = [.player1: 1.6, .player2: 1.3]
        for n in 1...10 {
            let p1 = try Self.body(.player1, height: 1.6, Pose(crownDrop: 0.1))
            let p2 = try Self.body(.player2, height: 1.3, Pose(lift: 0.1))
            mailbox.offer(Self.packet(frame: UInt64(n), time: Double(n) / 30, heights: heights,
                                      bodies: [.player1: (p1.joints, p1.geometry, .reliable), .player2: (p2.joints, p2.geometry, .reliable)]))
            layer.apply(mailbox.drain(now: Double(n) / 30), now: Double(n) / 30)
        }
        func markers(_ player: PlayerID) -> [Entity] { scene.root.children.filter { $0.name == "avatar.fairness.\(player.rawValue)" } }
        for player in PlayerID.allCases {
            let found = markers(player), e = try #require(layer.extremities(of: player, mapping: scene.mapping))
            #expect(found.count == 5)
            #expect(abs(Double(found[0].position.y) - e.headTopY) < 1e-4 && abs(Double(found[3].position.y) - e.leftSoleY) < 1e-4)
        }
        layer.remove()
        #expect(PlayerID.allCases.allSatisfy { markers($0).isEmpty })
    }
}

extension PlayerPlaneLayout {
    /// Test-only construction through the existing Codable conformance (no new API).
    static func decodeForTests(leftCenterX: Double, rightCenterX: Double, unitsPerImageHeight: Double) throws -> Self {
        try JSONDecoder().decode(Self.self, from: Data("""
            {"leftCenterX": \(leftCenterX), "rightCenterX": \(rightCenterX), "gameUnitsPerImageHeight": \(unitsPerImageHeight)}
            """.utf8))
    }
}
