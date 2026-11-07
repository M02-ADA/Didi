import Foundation
import RealityKit
import Testing
@testable import Sedactive

// MARK: - Test-only fixture decoding (R7: no Codable added to Shared or seam types)

private struct FixtureFile: Decodable {
    struct Policy: Decodable { let maxAge: Double; let visualConfidence: Double }
    struct Context: Decodable {
        let generation: UUID, epoch: UUID, geometryRevision: UInt64
        let imageWidth: Int, imageHeight: Int, rotationAngle: Double, mirrored: Bool
    }
    struct ContextPatch: Decodable {
        var generation: UUID?, epoch: UUID?, geometryRevision: UInt64?
        var imageWidth: Int?, imageHeight: Int?, rotationAngle: Double?, mirrored: Bool?
    }
    struct Cutover: Decodable { let frameID: UInt64; let capturedAt: Double }
    struct Calibration: Decodable {
        let revision: UInt64
        let mapping: ImageToPlayerPlaneMapping
        let standingCrownImageY: Double, standingHipImageY: Double
        let standingLeftAnkleImageY: Double, standingRightAnkleImageY: Double
        let cutover: Cutover
    }
    struct Candidate: Decodable { let id: UInt64; let joints: [String: [Double]] }
    struct Base: Decodable {
        let context: Context
        let controlRevision: UInt64
        let layout: PlayerPlaneLayout
        let calibration: [String: Calibration]
        let candidates: [String: Candidate]
    }
    struct Slot: Decodable { let state: String; let candidate: UInt64?; let rebind: Bool? }
    struct Edit: Decodable { let drop: [String]?; let set: [String: [Double]]? }
    /// A number is a valid value; a string is an invalid validity (value nil).
    struct Scalar: Decodable {
        let value: EstimatedScalar
        init(from decoder: any Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let number = try? c.decode(Double.self) {
                value = try EstimatedScalar(value: number, validity: .valid)
            } else {
                let raw = try c.decode(String.self)
                guard let validity = EvidenceValidity(rawValue: raw) else {
                    throw DecodingError.dataCorruptedError(in: c, debugDescription: "validity \(raw)")
                }
                value = try EstimatedScalar(value: nil, validity: validity)
            }
        }
    }
    struct Visual: Decodable { let crownY: Scalar, leftSoleY: Scalar, rightSoleY: Scalar, centerX: Scalar }
    struct Status: Decodable {
        let revision: UInt64
        var isActive: Bool?
        var context: ContextPatch?
        var controlRevision: UInt64?
        var layout: Bool?
        var calibrated: [String]?
        var calibrationRevisions: [String: UInt64]?
        var cutovers: [String: Cutover]?
    }
    struct Offer: Decodable {
        let frameID: UInt64
        let capturedAt: Double
        let contextRevision: UInt64
        var controlRevision: UInt64?
        var context: ContextPatch?
        var slots: [String: Slot]?
        var candidates: [String]?
        var candidateIDs: [String: UInt64]?
        var extraCandidates: Int?
        var edit: [String: Edit]?
        var calibration: [String]?
        var calibrationRevisions: [String: UInt64]?
        var visual: [String: Visual]?
    }
    struct DrainExpect: Decodable {
        var frame: Bool?, frameID: UInt64?, hasCurrent: Bool?, expired: Bool?
        var resetAll: Bool?, resetCalibration: [String]?
        var player1: String?, player2: String?
        var player1Joints: Int?, player2Joints: Int?
        var player1NoseX: Double?, player2NoseX: Double?
    }
    enum Expect: Decodable {
        case outcome(String)
        case drain(DrainExpect)
        init(from decoder: any Decoder) throws {
            if let text = try? decoder.singleValueContainer().decode(String.self) { self = .outcome(text) } else {
                self = .drain(try DrainExpect(from: decoder))
            }
        }
    }
    struct Step: Decodable {
        var status: Status?
        var offer: Offer?
        var drain: Double?
        var revoke: Bool?
        var expect: Expect?
    }
    struct Fixture: Decodable { let id: String; let title: String; let steps: [Step] }

    let policy: Policy
    let base: Base
    let fixtures: [Fixture]
}

private func player(_ key: String) -> PlayerID { key == "player2" ? .player2 : .player1 }

/// Builds seam values from the fixture base plus per-step overrides.
@MainActor
private struct Builder {
    let file: FixtureFile
    var base: FixtureFile.Base { file.base }

    func context(_ patch: FixtureFile.ContextPatch?) -> AvatarSourceContext {
        let c = base.context
        return AvatarSourceContext(generation: patch?.generation ?? c.generation, epoch: patch?.epoch ?? c.epoch,
                                   geometryRevision: patch?.geometryRevision ?? c.geometryRevision,
                                   imageWidth: patch?.imageWidth ?? c.imageWidth, imageHeight: patch?.imageHeight ?? c.imageHeight,
                                   rotationAngle: patch?.rotationAngle ?? c.rotationAngle, mirrored: patch?.mirrored ?? c.mirrored)
    }

    func status(_ s: FixtureFile.Status) -> AvatarSourceStatus {
        let active = s.isActive ?? true
        var calibrations: [PlayerID: AvatarCalibrationStatus] = [:]
        for key in s.calibrated ?? ["player1", "player2"] {
            let b = base.calibration[key]!
            let cut = s.cutovers?[key] ?? b.cutover
            calibrations[player(key)] = AvatarCalibrationStatus(
                revision: s.calibrationRevisions?[key] ?? b.revision,
                cutover: BodyInputCutover(frameID: cut.frameID, capturedAt: cut.capturedAt))
        }
        return AvatarSourceStatus(revision: s.revision, isActive: active, context: active ? context(s.context) : nil,
                                  controlRevision: s.controlRevision ?? base.controlRevision,
                                  layout: (s.layout ?? true) ? base.layout : nil, calibrations: calibrations)
    }

    func joints(_ key: String, edit: FixtureFile.Edit?) -> [BodyJoint: PoseJoint] {
        var raw = base.candidates[key]!.joints
        for name in edit?.drop ?? [] { raw[name] = nil }
        for (name, value) in edit?.set ?? [:] { raw[name] = value }
        var out: [BodyJoint: PoseJoint] = [:]
        for (name, v) in raw { out[BodyJoint(rawValue: name)!] = PoseJoint(x: v[0], y: v[1], confidence: v[2]) }
        return out
    }

    func output(_ o: FixtureFile.Offer) -> AvatarSourceOutput {
        func id(_ key: String) -> UInt64 { o.candidateIDs?[key] ?? base.candidates[key]!.id }
        var candidates = (o.candidates ?? ["player1", "player2"]).map {
            PoseCandidate(candidateID: id($0), joints: joints($0, edit: o.edit?[$0]), maskTopImageY: nil, maskBottomImageY: nil,
                          leftFootBottomImageY: nil, rightFootBottomImageY: nil, maskAssociation: .unavailable)
        }
        for n in 0..<(o.extraCandidates ?? 0) {
            candidates.append(PoseCandidate(candidateID: 900 + UInt64(n), joints: joints("player1", edit: nil), maskTopImageY: nil,
                                            maskBottomImageY: nil, leftFootBottomImageY: nil, rightFootBottomImageY: nil,
                                            maskAssociation: .unavailable))
        }
        func slot(_ key: String) -> AvatarTrackedSlot {
            guard let s = o.slots?[key] else { return AvatarTrackedSlot(state: .tracking, candidateID: id(key), requiresRebind: false) }
            return AvatarTrackedSlot(state: AvatarTrackedState(rawValue: s.state)!, candidateID: s.candidate,
                                     requiresRebind: s.rebind ?? false)
        }
        var calibration: [PlayerID: AvatarCalibrationInput] = [:]
        for key in o.calibration ?? ["player1", "player2"] {
            let b = base.calibration[key]!
            let visual = o.visual?[key].map { v in
                BodyGeometry(crownY: v.crownY.value, leftWristY: try! EstimatedScalar(value: nil, validity: .missingLandmarks),
                             rightWristY: try! EstimatedScalar(value: nil, validity: .missingLandmarks),
                             leftSoleY: v.leftSoleY.value, rightSoleY: v.rightSoleY.value, centerX: v.centerX.value)
            }
            calibration[player(key)] = AvatarCalibrationInput(
                revision: o.calibrationRevisions?[key] ?? b.revision, mapping: b.mapping,
                standingCrownImageY: b.standingCrownImageY, standingHipImageY: b.standingHipImageY,
                standingLeftAnkleImageY: b.standingLeftAnkleImageY, standingRightAnkleImageY: b.standingRightAnkleImageY,
                visual: visual)
        }
        return AvatarSourceOutput(source: AvatarSourceFrame(context: context(o.context), frameID: o.frameID, capturedAt: o.capturedAt,
                                                            controlRevision: o.controlRevision ?? base.controlRevision),
                                  contextRevision: o.contextRevision, player1: slot("player1"), player2: slot("player2"),
                                  candidates: candidates, calibration: calibration)
    }

    /// A plain offer (base candidates, both tracked) with optional visual values for P1/P2.
    func offer(_ frameID: UInt64, at time: Double, context revision: UInt64, p1Revision: UInt64? = nil,
               visual: [String: (crown: Double, sole: Double?)] = [:], p2Lost: Bool = false,
               edit: [String: FixtureFile.Edit] = [:], calibrated: [String]? = nil) -> AvatarSourceOutput {
        func scalar(_ v: Double?) -> FixtureFile.Scalar { try! JSONDecoder().decode(FixtureFile.Scalar.self, from: Data((v.map { "\($0)" } ?? "\"stale\"").utf8)) }
        let visuals = visual.mapValues { v in
            FixtureFile.Visual(crownY: scalar(v.crown), leftSoleY: scalar(v.sole), rightSoleY: scalar(v.sole),
                               centerX: scalar(nil))
        }
        var o = FixtureFile.Offer(frameID: frameID, capturedAt: time, contextRevision: revision)
        o.calibration = calibrated
        o.calibrationRevisions = p1Revision.map { ["player1": $0] }
        o.visual = visuals
        o.edit = edit
        if p2Lost {
            o.slots = ["player2": FixtureFile.Slot(state: "lost", candidate: nil, rebind: nil)]
            o.candidates = ["player1"]
        }
        return output(o)
    }
}

private func describe(_ slot: AvatarSlot) -> String {
    switch slot {
    case .unavailable(let reason): "unavailable:\(reason.rawValue)"
    case .available(let pose):
        switch pose.capability {
        case .directionOnly: "directionOnly"
        case .calibrated(let reference, _): "calibrated:\(reference.calibrationRevision)"
        }
    }
}

// MARK: - Tests

/// K03 synthetic contract: the shared D06 fixtures (F01–F13) through the
/// projection and the bounded mailbox, then the avatar layer's behaviour on
/// the same packets. SYNTHETIC values only; no camera, tracker or CP1 reader.
@MainActor
struct AvatarPoseContractTests {
    private final class Token {}

    private static func load() throws -> FixtureFile {
        let bundle = Bundle(for: Token.self)
        let url = try #require(bundle.url(forResource: "d06-avatar-pose-fixtures", withExtension: "json")
            ?? bundle.url(forResource: "d06-avatar-pose-fixtures", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(FixtureFile.self, from: Data(contentsOf: url))
    }

    /// Runs one fixture's timeline; `onDrain` sees every drain (for layer checks).
    private func run(_ fixture: FixtureFile.Fixture, _ file: FixtureFile,
                     onDrain: (AvatarPoseDrain, Double) -> Void = { _, _ in }) {
        let builder = Builder(file: file)
        let mailbox = AvatarPoseMailbox(maxAge: file.policy.maxAge)
        for (index, step) in fixture.steps.enumerated() {
            let at = "\(fixture.id) step \(index + 1)"
            if let status = step.status { mailbox.publish(builder.status(status)) }
            if step.revoke == true { mailbox.revoke() }
            if let offer = step.offer {
                let result = mailbox.offer(builder.output(offer))
                if case .outcome(let expected)? = step.expect {
                    #expect((result?.rawValue ?? "accepted") == expected, "\(at)")
                }
            }
            if let now = step.drain {
                let drain = mailbox.drain(now: now)
                onDrain(drain, now)
                guard case .drain(let e)? = step.expect else { continue }
                if let frameID = e.frameID { #expect(drain.frame?.source.frameID == frameID, "\(at) frameID") }
                if let frame = e.frame { #expect((drain.frame != nil) == frame, "\(at) frame") }
                if let hasCurrent = e.hasCurrent { #expect(drain.hasCurrent == hasCurrent, "\(at) hasCurrent") }
                if let expired = e.expired { #expect(drain.expired == expired, "\(at) expired") }
                if let all = e.resetAll { #expect(drain.reset.all == all, "\(at) resetAll") }
                if let players = e.resetCalibration { #expect(drain.reset.calibration == Set(players.map(player)), "\(at) resetCalibration") }
                for (key, expected) in [("player1", e.player1), ("player2", e.player2)] {
                    guard let expected else { continue }
                    #expect(drain.frame.map { describe($0.slot(player(key))) } == expected, "\(at) \(key)")
                }
                for (key, count) in [("player1", e.player1Joints), ("player2", e.player2Joints)] {
                    guard let count else { continue }
                    if case .available(let pose)? = drain.frame?.slot(player(key)) {
                        #expect(pose.joints.count == count, "\(at) \(key) joints")
                    } else { Issue.record("\(at) \(key) not available") }
                }
                for (key, x) in [("player1", e.player1NoseX), ("player2", e.player2NoseX)] {
                    guard let x else { continue }
                    if case .available(let pose)? = drain.frame?.slot(player(key)) {
                        #expect(abs((pose.joints[.nose]?.x ?? .nan) - x) < 1e-9, "\(at) \(key) nose: identity from the slot, not order")
                    } else { Issue.record("\(at) \(key) not available") }
                }
            }
        }
    }

    @Test(arguments: ["F01", "F02", "F03", "F04", "F05", "F06", "F07", "F08", "F09", "F10", "F11", "F12", "F13"])
    func sharedFixture(id: String) throws {
        let file = try Self.load()
        let fixture = try #require(file.fixtures.first { $0.id == id })
        run(fixture, file)
    }

    @Test func fixtureFileCoversEveryCaseOnce() throws {
        let file = try Self.load()
        #expect(file.fixtures.map(\.id) == (1...13).map { String(format: "F%02d", $0) })
    }

    // MARK: Conversion

    /// F01: the producer's image-space reference, converted here, equals the
    /// existing CP1-calibration derivation (the oracle); joints convert with
    /// CP1's own formula: standing hips land on the reference and the lane.
    @Test func referenceAndJointConversionMatchTheOracle() throws {
        let file = try Self.load()
        let builder = Builder(file: file)
        let status = builder.status(FixtureFile.Status(revision: 1))
        let frame = try AvatarPoseProjection.project(builder.offer(10, at: 1, context: 1), status: status).get()
        for key in ["player1", "player2"] {
            let id = player(key)
            guard case .available(let pose) = frame.slot(id), let standing = pose.capability.reference else {
                Issue.record("\(key) not calibrated"); continue
            }
            let b = file.base.calibration[key]!
            let calibration = PlayerCalibration(
                playerID: id, sessionGeneration: file.base.context.generation, revision: b.revision, cameraGeometryRevision: 1,
                sourceFrameID: b.cutover.frameID, capturedAt: b.cutover.capturedAt, standingCrownImageY: b.standingCrownImageY,
                standingLeftSoleImageY: b.standingLeftAnkleImageY, standingRightSoleImageY: b.standingRightAnkleImageY,
                standingHipImageY: b.standingHipImageY, standingBodyImageHeight: b.standingCrownImageY - b.standingLeftAnkleImageY,
                standingTorsoImageLength: 0.3, headOffsetFromNoseShare: 0, leftFootOffsetShare: 0, rightFootOffsetShare: 0,
                mapping: b.mapping)
            try calibration.validate()
            #expect(AvatarReference(standing: standing, playerID: id) == AvatarReference(calibration: calibration, layout: file.base.layout))
            #expect(abs(standing.standingCrownY - 1.6) < 1e-9 && abs(standing.standingHipY - 0.8) < 1e-9)
            let o = AvatarPoseAdapter.observation(pose, playerID: id, imageAspect: 1920.0 / 1080)
            let hipX = ((o.joints[.leftHip]?.x ?? .nan) + (o.joints[.rightHip]?.x ?? .nan)) / 2
            #expect(abs(hipX - file.base.layout.centerX(for: id)) < 1e-9)
            #expect(abs((o.joints[.leftHip]?.y ?? .nan) - standing.standingHipY) < 1e-9)
            #expect(abs((o.joints[.leftAnkle]?.y ?? .nan) - standing.standingLeftAnkleY) < 1e-9)
            #expect(o.joints[.leftElbow] == nil && o.joints[.leftKnee] == nil)  // never invented
        }
    }

    // MARK: The avatar layer on packets

    private func layer() async throws -> RobotAvatarLayer {
        RobotAvatarLayer(scene: LaserScene(), players: Set(PlayerID.allCases), templates: try await RobotAvatarLayer.sharedTemplates())
    }

    /// F09 with root lift (R3/R5): a calibrated jump is fully reset when the
    /// calibration is replaced; old-revision packets stay direction-only; a
    /// compatible packet after the cutover re-establishes calibrated motion;
    /// the peer is unaffected throughout.
    @Test func calibrationReplacementResetsThenUpgradesWithoutStaleState() async throws {
        let file = try Self.load()
        let builder = Builder(file: file)
        let layer = try await layer()
        let mailbox = AvatarPoseMailbox(maxAge: 0.25)
        mailbox.publish(builder.status(FixtureFile.Status(revision: 1)))
        func step(_ output: AvatarSourceOutput, now: Double) -> AvatarPoseRejection? {
            let result = mailbox.offer(output)
            layer.apply(mailbox.drain(now: now), now: now)
            return result
        }
        let up: [String: (crown: Double, sole: Double?)] = ["player1": (1.85, 0.25), "player2": (1.85, 0.25)]
        for n in 0..<15 { #expect(step(builder.offer(10 + UInt64(n), at: 1 + Double(n) / 30, context: 1, visual: up), now: 1 + Double(n) / 30 + 0.01) == nil) }
        let p1 = { layer.robots[.player1]! }, p2 = { layer.robots[.player2]! }
        #expect(p1().retargeter.lift > 0.1 && p1().container.position.y > 0.1 && p1().retargeter.reference?.calibrationRevision == 1)
        let p2Lift = p2().retargeter.lift
        #expect(p2Lift > 0.1)

        // Replacement: P1 revision 2 from frame 30. The old jump is dropped at once.
        mailbox.publish(builder.status(FixtureFile.Status(revision: 2, calibrationRevisions: ["player1": 2],
                                                          cutovers: ["player1": .init(frameID: 30, capturedAt: 3.0)])))
        let reset = mailbox.drain(now: 1.6)
        #expect(reset.reset.calibration == [.player1] && !reset.reset.all)
        layer.apply(reset, now: 1.6)
        #expect(p1().retargeter.lift == 0 && p1().container.position.y == 0 && p1().retargeter.targets.pelvisDrop == 0)
        #expect(abs(p2().retargeter.lift - p2Lift) < 1e-6)  // the peer holds its pose

        // Delayed packet of the old context: refused. Old-reference packet: direction-only, no lift.
        #expect(step(builder.offer(26, at: 1.7, context: 1, visual: up), now: 1.71) == .staleContext)
        #expect(step(builder.offer(27, at: 1.8, context: 2, visual: up), now: 1.81) == nil)
        #expect(p1().retargeter.reference == nil && p1().retargeter.lift == 0 && !p1().retargeter.isCalibrated)
        #expect(p2().retargeter.lift > 0.1)

        // Compatible packets after the cutover: calibrated again, revision 2, and the jump shows.
        for n in 0..<15 {
            #expect(step(builder.offer(31 + UInt64(n), at: 3.1 + Double(n) / 30, context: 2, p1Revision: 2, visual: up),
                         now: 3.1 + Double(n) / 30 + 0.01) == nil)
        }
        #expect(p1().retargeter.reference?.calibrationRevision == 2 && p1().retargeter.lift > 0.1)
        // A NEWER frame that still carries revision 1 (an incompatible calibration, not a
        // late packet) is shown direction-only with no stale lift (R3). A genuinely late
        // packet never reaches this point: it is refused as staleFrame or staleContext.
        #expect(step(builder.offer(60, at: 4.0, context: 2, visual: up), now: 4.01) == nil)
        #expect(p1().retargeter.reference == nil && p1().retargeter.lift == 0)
    }

    /// F10 on the layer: valid soles lift the root; stale soles let it settle;
    /// a valid crown drop with no hip evidence lowers the pelvis.
    @Test func visualValuesDriveLiftAndCrownDuckOnlyWhenValid() async throws {
        let file = try Self.load()
        let builder = Builder(file: file)
        let layer = try await layer()
        let mailbox = AvatarPoseMailbox(maxAge: 0.25)
        mailbox.publish(builder.status(FixtureFile.Status(revision: 1)))
        var t = 1.0, id: UInt64 = 10
        func feed(_ frames: Int, _ visual: [String: (crown: Double, sole: Double?)], edit: [String: FixtureFile.Edit] = [:]) {
            for _ in 0..<frames {
                t += 1.0 / 30; id += 1
                mailbox.offer(builder.offer(id, at: t, context: 1, visual: visual, edit: edit))
                layer.apply(mailbox.drain(now: t + 0.005), now: t + 0.005)
            }
        }
        let r = { layer.robots[.player1]!.retargeter }
        feed(15, ["player1": (1.85, 0.25)])
        #expect(r().lift > 0.1)
        let lifted = r().lift
        feed(30, ["player1": (1.6, nil)])  // soles stale: hold, then settle
        #expect(r().lift < lifted * 0.2)
        feed(20, ["player1": (1.36, 0)], edit: ["player1": FixtureFile.Edit(drop: ["leftHip", "rightHip"], set: nil)])
        #expect(r().targets.pelvisDrop > 0.03, "crown duck \(r().targets.pelvisDrop)")
    }

    /// Direction-only: arms, lean and head follow; root, crouch and feet stay
    /// neutral even with raised ankles and visual values present.
    @Test func directionOnlyMovesArmsButNeverClaimsFloorOrScale() async throws {
        let file = try Self.load()
        let builder = Builder(file: file)
        let layer = try await layer()
        let mailbox = AvatarPoseMailbox(maxAge: 0.25)
        var status = FixtureFile.Status(revision: 1)
        status.calibrated = ["player2"]
        mailbox.publish(builder.status(status))
        let raised = FixtureFile.Edit(drop: nil, set: ["leftWrist": [0.78, 0.95, 0.9], "leftAnkle": [0.72, 0.30, 0.9], "rightAnkle": [0.68, 0.30, 0.9]])
        for n in 0..<20 {
            let t = 1 + Double(n) / 30
            mailbox.offer(builder.offer(10 + UInt64(n), at: t, context: 1, visual: ["player1": (1.85, 0.25)],
                                        edit: ["player1": raised], calibrated: ["player2"]))
            layer.apply(mailbox.drain(now: t + 0.005), now: t + 0.005)
        }
        let r = layer.robots[.player1]!.retargeter
        #expect(!r.isCalibrated && r.reference == nil && r.isAvailable)
        #expect(r.lift == 0 && r.sway == 0 && r.targets.pelvisDrop == 0 && r.footDelta.isEmpty)
        let leftArm = simd_normalize(r.targets.upperArm[.left] ?? SIMD3(0, -1, 0))
        #expect(leftArm.y > 0.5 && (r.targets.armWeight[.left] ?? 0) > 0.5, "left arm \(leftArm)")  // raised
        #expect(layer.robots[.player1]!.container.position.y == 0)
    }

    /// One slot lost for a second: it fades and dims; the peer keeps
    /// animating; on recovery it fades back in.
    @Test func partialLossAndRecoveryKeepPeersIndependent() async throws {
        let file = try Self.load()
        let builder = Builder(file: file)
        let layer = try await layer()
        let mailbox = AvatarPoseMailbox(maxAge: 0.25)
        mailbox.publish(builder.status(FixtureFile.Status(revision: 1)))
        var t = 1.0, id: UInt64 = 10
        func feed(_ frames: Int, p2Lost: Bool) {
            for _ in 0..<frames {
                t += 1.0 / 30; id += 1
                mailbox.offer(builder.offer(id, at: t, context: 1, visual: ["player1": (1.85, 0.25), "player2": (1.6, 0)], p2Lost: p2Lost))
                layer.apply(mailbox.drain(now: t + 0.005), now: t + 0.005)
            }
        }
        feed(10, p2Lost: false)
        feed(30, p2Lost: true)
        let p2 = layer.robots[.player2]!
        #expect(!p2.retargeter.isAvailable && p2.retargeter.presence < 0.1)
        #expect(p2.container.components[OpacityComponent.self]?.opacity == RobotAvatarLayer.unavailableOpacity)
        #expect(layer.robots[.player1]!.retargeter.lift > 0.1 && layer.robots[.player1]!.retargeter.isAvailable)
        feed(10, p2Lost: false)
        #expect(layer.robots[.player2]!.retargeter.isAvailable && layer.robots[.player2]!.retargeter.presence > 0.9)
    }

    /// Stop: neutral at once (no fade, no held jump); a late frame is refused;
    /// no-frame expiry then relaxes a fresh session to neutral too.
    @Test func stopIsImmediateAndExpiryRelaxes() async throws {
        let file = try Self.load()
        let builder = Builder(file: file)
        let layer = try await layer()
        let mailbox = AvatarPoseMailbox(maxAge: 0.25)
        mailbox.publish(builder.status(FixtureFile.Status(revision: 1)))
        for n in 0..<15 {
            let t = 1 + Double(n) / 30
            mailbox.offer(builder.offer(10 + UInt64(n), at: t, context: 1, visual: ["player1": (1.85, 0.25), "player2": (1.85, 0.25)]))
            layer.apply(mailbox.drain(now: t + 0.005), now: t + 0.005)
        }
        #expect(layer.robots.values.allSatisfy { $0.retargeter.lift > 0.1 })
        var stop = FixtureFile.Status(revision: 2)
        stop.isActive = false
        mailbox.publish(builder.status(stop))
        layer.apply(mailbox.drain(now: 1.6), now: 1.6)
        for robot in layer.robots.values {
            #expect(robot.retargeter.presence == 0 && robot.retargeter.lift == 0 && robot.container.position.y == 0)
            #expect(robot.retargeter.reference == nil)
        }
        #expect(mailbox.offer(builder.offer(40, at: 1.61, context: 1)) == .inactive)

        // A new session: one frame, then silence; expiry fades it out on later drains.
        mailbox.publish(builder.status(FixtureFile.Status(revision: 3)))
        mailbox.offer(builder.offer(41, at: 2.0, context: 3))
        layer.apply(mailbox.drain(now: 2.01), now: 2.01)
        #expect(layer.robots[.player1]!.retargeter.isAvailable)
        var t = 2.01, expiredSeen = false
        for _ in 0..<90 {
            t += 1.0 / 60
            let drain = mailbox.drain(now: t)
            expiredSeen = expiredSeen || drain.expired
            layer.apply(drain, now: t)
        }
        #expect(expiredSeen && layer.robots.values.allSatisfy { !$0.retargeter.isAvailable && $0.retargeter.presence < 0.05 })
    }

    // MARK: Bounded delivery

    /// A renderer that never drains holds at most one pending frame, one
    /// status and one reset summary, whatever the producer sends; the
    /// summary still reports every reset that matters (no lost stop).
    @Test func aStalledRendererKeepsOnlyTheLatestAndLosesNoReset() throws {
        let file = try Self.load()
        let builder = Builder(file: file)
        let mailbox = AvatarPoseMailbox(maxAge: 0.25)
        mailbox.publish(builder.status(FixtureFile.Status(revision: 1)))
        for n in 0..<500 { #expect(mailbox.offer(builder.offer(10 + UInt64(n), at: 1 + Double(n) / 30, context: 1)) == nil) }
        var p2Change = FixtureFile.Status(revision: 2)
        p2Change.calibrationRevisions = ["player2": 7]
        mailbox.publish(builder.status(p2Change))
        var stop = FixtureFile.Status(revision: 3)
        stop.isActive = false
        mailbox.publish(builder.status(stop))
        mailbox.publish(builder.status(FixtureFile.Status(revision: 4)))  // resumed before any drain
        for n in 0..<50 { mailbox.offer(builder.offer(600 + UInt64(n), at: 30 + Double(n) / 30, context: 4)) }
        let d = mailbox.diagnostics
        #expect(d.accepted == 550 && d.replacedPending == 548 && d.statusesInstalled == 4)
        let drain = mailbox.drain(now: 31.64)
        #expect(drain.reset.all && drain.reset.calibration.contains(.player2))
        #expect(drain.frame?.source.frameID == 649)
        #expect(mailbox.drain(now: 31.65).reset.isEmpty)  // reported once
    }

    /// The producer offers from another thread while the renderer drains:
    /// no task per frame, no blocking, frames only ever move forward.
    @Test func concurrentProducerAndRendererStayOrderedAndBounded() async throws {
        let file = try Self.load()
        let builder = Builder(file: file)
        let mailbox = AvatarPoseMailbox(maxAge: 10)
        mailbox.publish(builder.status(FixtureFile.Status(revision: 1)))
        let outputs = (0..<2000).map { builder.offer(10 + UInt64($0), at: 1 + Double($0) / 1000, context: 1) }
        let producing = DispatchGroup()
        producing.enter()
        DispatchQueue(label: "k03.producer").async {
            for output in outputs { mailbox.offer(output) }
            producing.leave()
        }
        var last: UInt64 = 0, shown = 0
        while true {
            let finished = producing.wait(timeout: .now()) == .success
            if let frame = mailbox.drain(now: 2).frame {
                #expect(frame.source.frameID > last)
                last = frame.source.frameID
                shown += 1
            }
            if finished { break }
            await Task.yield()
        }
        if let frame = mailbox.drain(now: 2).frame { last = frame.source.frameID; shown += 1 }
        #expect(last == 2009 && shown >= 1 && mailbox.diagnostics.accepted == 2000)
    }

    // MARK: Synthetic demo through packets; presentation unchanged

    /// The synthetic demo, converted to labelled synthetic packets, drives the
    /// Lemon/Tangerine pair through the mailbox: P1 jumps while P2 stands, P2
    /// ducks while P1 stands, arms move; equal size and colours unchanged.
    @Test func syntheticDemoDrivesBothMascotsThroughPackets() async throws {
        let input = try LaserReplayScript.load().input
        let source = SyntheticAvatarSource(configuration: input.configuration, cameraGeometryRevision: input.cameraGeometryRevision)
        func play(_ scenario: RobotDemoScenario) async throws -> (RobotAvatarLayer, [PlayerID: Float], [PlayerID: Float], [PlayerID: Float]) {
            let layer = RobotAvatarLayer(scene: LaserScene(), players: Set(PlayerID.allCases), templates: try await RobotAvatarLayer.sharedTemplates())
            let mailbox = AvatarPoseMailbox(maxAge: 0.25)
            mailbox.publish(source.status)
            let sequence = RobotDemoSequence(configuration: input.configuration, cameraGeometryRevision: input.cameraGeometryRevision, only: scenario)
            var lift: [PlayerID: Float] = [:], drop: [PlayerID: Float] = [:], arm: [PlayerID: Float] = [:]
            for index in UInt64(1)...110 {
                let f = try sequence.frame(index)
                #expect(mailbox.offer(source.output(f.snapshot, joints: f.joints)) == nil)
                layer.apply(mailbox.drain(now: f.snapshot.capturedAt + 0.005), now: f.snapshot.capturedAt + 0.005)
                for (player, robot) in layer.robots {
                    lift[player] = max(lift[player] ?? 0, robot.retargeter.lift)
                    drop[player] = max(drop[player] ?? 0, robot.retargeter.targets.pelvisDrop)
                    let w = RobotPoseTargets.Side.allCases.map { robot.retargeter.targets.armWeight[$0] ?? 0 }.max() ?? 0
                    arm[player] = max(arm[player] ?? 0, w)
                }
            }
            return (layer, lift, drop, arm)
        }
        let (jumpLayer, jump, _, _) = try await play(.p1JumpLand)
        #expect((jump[.player1] ?? 0) > 0.1 && (jump[.player2] ?? 1) < 0.01, "lift \(jump)")
        let (_, _, duck, _) = try await play(.p2DuckStand)
        #expect((duck[.player2] ?? 0) > 0.03 && (duck[.player1] ?? 1) < 0.01, "drop \(duck)")
        let (_, _, _, arms) = try await play(.asymmetricArms)
        #expect((arms[.player1] ?? 0) > 0.5, "arms \(arms)")
        // Same Lemon/Tangerine pair, same size.
        let p1 = try #require(jumpLayer.robots[.player1]), p2 = try #require(jumpLayer.robots[.player2])
        #expect(MascotColorVariantTests.close(MascotColorVariantTests.bodyColor(p1), MascotColorVariantTests.lemonBody))
        #expect(MascotColorVariantTests.close(MascotColorVariantTests.bodyColor(p2), MascotColorVariantTests.tangerineBody))
        #expect(p1.container.scale == p2.container.scale && p1.container.scale == SIMD3(repeating: RobotAvatarLayer.modelScale))
    }
}
