#if DEBUG
import Foundation

/// Explicit SYNTHETIC preview input, through the EXISTING K03 mailbox/presenter and steering.
/// No camera, B2 instance, CP1 publisher, gameplay clock, timer or tutorial success injection.
@MainActor final class LeanFTUESyntheticInput: AvatarPosePump {
    let mailbox: AvatarPoseMailbox
    let source: SyntheticAvatarSource
    let configuration: BodyInputConfiguration
    var practice: (() -> FTUELaserPractice?)?
    var onBodySnapshot: ((BodySnapshot, Double) -> Void)?
    private(set) var latestSnapshot: BodySnapshot?
    private var diamondCycle: Int?
    private var diamondTarget: LaserDiamondPosition?
    private var currentAttempt: UUID?
    private var stageAttempts: [LaserMove: Int] = [:]
    let context: BodyInputContext
    let roster: [PlayerID]
    private let tutorial: LeanTutorial
    private var stopped = false
    private var frame: UInt64
    private var lastCapture = -Double.infinity
    private var stage: LeanTutorial.Stage?
    private var stageStart = 0.0
    private var wasSuspended = false
    private let hold: Bool
    private let skipsLeanMotion = ProcessInfo.processInfo.arguments.contains("-leanFTUENoMotion")

    init(configuration: BodyInputConfiguration, geometry: UInt64, tutorial: LeanTutorial,
         roster: [PlayerID], hold: Bool) {
        self.configuration = configuration
        self.tutorial = tutorial; self.roster = roster; self.hold = hold
        source = SyntheticAvatarSource(configuration: configuration, cameraGeometryRevision: geometry)
        frame = (configuration.calibrations.values.map(\.sourceFrameID).max() ?? 0) + 1
        context = BodyInputContext(sessionGeneration: configuration.sessionGeneration,
            cameraGeometryRevision: geometry, calibrationRevisions: configuration.calibrations.mapValues(\.revision),
            cutovers: configuration.calibrations.mapValues { .init(frameID: $0.sourceFrameID, capturedAt: $0.capturedAt) },
            isActive: true, wristContact: .init(sourceEpoch: source.context.epoch, controlRevision: source.controlRevision,
                bindingRequestID: UUID(), bindingFrameID: 0, bindingCapturedAt: 0,
                acceptedContextRevision: 1, freshness: LiveAvatarPresenter.maximumPoseAge))
        mailbox = AvatarPoseMailbox(maxAge: LiveAvatarPresenter.maximumPoseAge)
        mailbox.publish(source.status)
    }
    func tick() throws -> Bool {
        guard !stopped else { return false }
        let now = CameraHostClock.now()
        // Model a synthetic capture one frame before processing. No physical frame is restamped.
        let capture = now - 1.0 / 30
        guard capture - lastCapture >= 1.0 / 30 else { return true }
        lastCapture = capture; frame += 1
        if stage != tutorial.stage || wasSuspended != tutorial.isSuspended {
            stage = tutorial.stage; stageStart = now; wasSuspended = tutorial.isSuspended
        }
        let boundarySetup = ProcessInfo.processInfo.arguments.contains("-leanFTUEBoundary") && stage == .introduction
        let share: Double = boundarySetup ? 0.08 : hold || tutorial.isSuspended || now - stageStart < 3 ? 0
            : stage == .freeLean && !skipsLeanMotion ? 0.08 : 0
        var players: [PlayerID: PlayerBodySample] = [:]
        var poses: [PlayerID: PresentationPoseSample] = [:]
        func value(_ x: Double) throws -> EstimatedScalar { try .init(value: x, validity: .valid) }
        for player in roster {
            guard let c = source.calibrations[player] else { continue }
            let r = AvatarReference(calibration: c, layout: source.layout), h = r.standingHeight, lane = r.laneCenterX
            let shoulder = share * h, hip = r.standingHipY
            let head = shoulder * (0.9 * h - hip) / (0.82 * h - hip)
            func p(_ x: Double, _ y: Double) -> PresentationPoint { .init(x: lane + x, y: y, confidence: 0.9) }
            poses[player] = .init(playerID: player, calibrationRevision: c.revision, joints: [
                .leftShoulder: p(shoulder + 0.13 * h, 0.82 * h), .rightShoulder: p(shoulder - 0.13 * h, 0.82 * h),
                .leftHip: p(0.10 * h, hip), .rightHip: p(-0.10 * h, hip),
                .leftAnkle: p(0.10 * h, r.standingLeftAnkleY), .rightAnkle: p(-0.10 * h, r.standingRightAnkleY),
                .nose: p(head, 0.9 * h), .leftEar: p(head + 0.05 * h, 0.9 * h), .rightEar: p(head - 0.05 * h, 0.9 * h)])
            let activePractice = practice?()
            if let activePractice, currentAttempt != activePractice.attemptID {
                currentAttempt = activePractice.attemptID
                stageAttempts[activePractice.move, default: 0] += 1
            }
            let attempt = activePractice.map { stageAttempts[$0.move, default: 0] } ?? 0
            // Explicit DEBUG fixture: one mixed HIT then one all-CLEAR attempt per move.
            let succeeds = activePractice != nil && (attempt > 1 || (roster.count > 1 && player == .player1 && activePractice?.move == .jump)
                || (roster.count > 1 && player == .player2 && activePractice?.move == .duck))
            let action = activePractice.map { abs($0.elapsed - $0.crossing) < 0.3 && succeeds } ?? false
            let duck = action && activePractice?.move == .duck
            let jump = action && activePractice?.move == .jump
            players[player] = .init(playerID: player, calibrationRevision: c.revision, trackingStatus: .reliable,
                geometry: .init(crownY: try value(duck ? h * 0.6 : h), leftWristY: try value(h * 0.5), rightWristY: try value(h * 0.5),
                    leftSoleY: try value(jump ? h * 0.12 : 0), rightSoleY: try value(jump ? h * 0.12 : 0), centerX: try value(lane)),
                jumpState: .init(phase: jump ? .airborne : .grounded, validity: .valid))
        }
        for id in PlayerID.allCases where players[id] == nil {
            let missing = try EstimatedScalar(value: nil, validity: .notCalibrated)
            players[id] = .init(playerID: id, calibrationRevision: nil, trackingStatus: .lost,
                geometry: .init(crownY: missing, leftWristY: missing, rightWristY: missing,
                    leftSoleY: missing, rightSoleY: missing, centerX: missing),
                jumpState: .init(phase: .unknown, validity: .notCalibrated))
        }
        let snapshot = BodySnapshot(sessionGeneration: source.context.generation, frameID: frame,
            capturedAt: capture, cameraGeometryRevision: source.context.geometryRevision, players: players)
        let pose = PresentationPoseFrame(sessionGeneration: source.context.generation, frameID: frame,
            capturedAt: capture, players: poses)
        latestSnapshot = snapshot
        mailbox.offer(source.output(snapshot, joints: pose))
        onBodySnapshot?(snapshot, now)
        return true
    }
    func diamondTimeInputs() -> FTUEDiamondTimeSession.Inputs? {
        guard let plan = try? LaserLiveWristRoundPlan.completeRound(context: context,
            calibrations: configuration.calibrations, layout: configuration.playerPlaneLayout,
            seed: 7, roster: roster) else { return nil }
        return .init(configuration: plan.configuration, diamonds: plan.diamonds, context: context, roster: roster)
    }

    func vaultPracticeInputs() -> FTUEVaultPractice.Inputs? {
        guard let plan = try? LaserLiveWristRoundPlan.completeRound(context: context,
            calibrations: configuration.calibrations, layout: configuration.playerPlaneLayout,
            seed: 7, roster: roster), let director = plan.director else { return nil }
        return .init(round: .init(configuration: plan.configuration, diamonds: plan.diamonds,
                                  context: context, roster: roster),
                     zones: director.vaultContactZones(gateIndex: 0))
    }

    func vaultPracticeSnapshot(_ snapshot: BodySnapshot, practice: FTUEVaultPractice) throws -> BodySnapshot {
        try withWristEvidence(snapshot) { player, wrist in
            guard let zone = practice.inputs.zones.first(where: { $0.playerID == player }) else { return nil }
            let pressTime = player == .player1 ? 1.5 : 3.4
            let pressing = wrist == .left && practice.state.gameTime >= pressTime
            return .init(x: zone.position.x, y: zone.position.y - (pressing ? 0 : zone.radius * 2))
        }
    }

    /// Deterministic wrist trajectories for the labeled preview. Scoring still requires
    /// fresh, outside-to-inside contact through the production consumer.
    func diamondTimeSnapshot(_ snapshot: BodySnapshot, round: FTUEDiamondTimeSession) throws -> BodySnapshot {
        let time = round.game.gameTime
        let cycle = Int(time / 1.15)
        let moment = time - Double(cycle) * 1.15
        if moment >= 0.62, diamondCycle != cycle {
            diamondCycle = cycle
            diamondTarget = round.game.activeDiamonds.min { $0.id.uuidString < $1.id.uuidString }?.position
        }
        let reaching = roster[cycle % roster.count]
        return try withWristEvidence(snapshot) { player, wrist in
            guard let height = round.inputs.diamonds.standingHeights[player] else { return nil }
            let home = LaserDiamondTimeBoard.homeX(player: player, solo: roster.count == 1)
            var position = try LaserDiamondPosition(x: home + (wrist == .left ? -0.23 : 0.23), y: 0.904)
            if player == reaching, wrist == .left, moment >= 0.62, let diamondTarget { position = diamondTarget }
            let lane = round.inputs.diamonds.layout.centerX(for: player)
            let span = LaserDiamondTimeBoard.height - 2 * LaserDiamondTimeBoard.inset
            let lifted = (LaserDiamondTimeBoard.height - LaserDiamondTimeBoard.inset - position.y) / span
            let y = LaserDiamondTimeBoard.lowWristHeight
                + lifted * (LaserDiamondTimeBoard.highWristHeight - LaserDiamondTimeBoard.lowWristHeight)
            return .init(x: lane + (home - position.x) * height / LaserDiamondTimeBoard.lateralGain, y: y * height)
        }
    }

    private func withWristEvidence(_ snapshot: BodySnapshot,
                                   point: (PlayerID, LaserContactWrist) throws -> WristPlanePoint?) throws -> BodySnapshot {
        guard let authority = context.wristContact else { return snapshot }
        var hands: [PlayerID: PlayerWristContactV1] = [:]
        for player in PlayerID.allCases {
            func observation(_ wrist: LaserContactWrist) throws -> WristContactObservationV1 {
                guard let xy = try point(player, wrist) else {
                    return .init(observed: nil, observationRefusal: .missingJoint,
                                 playerPlane: nil, contactRefusal: .missingJoint)
                }
                return .init(observed: .init(x: 0.5, y: 0.5, confidence: 0.9), observationRefusal: nil,
                             playerPlane: xy, contactRefusal: nil)
            }
            hands[player] = try .init(playerID: player, trackingStatus: snapshot.players[player]?.trackingStatus ?? .lost,
                requiresRebind: false, candidateID: roster.contains(player) ? (player == .player1 ? 10 : 20) : nil,
                calibrationRevision: context.calibrationRevisions[player], cutover: context.cutovers[player],
                left: observation(.left), right: observation(.right))
        }
        let attachment = WristContactAttachmentV1(sourceEpoch: authority.sourceEpoch,
            sourceFrameID: snapshot.frameID, sourceCapturedAt: snapshot.capturedAt,
            controlRevision: authority.controlRevision, bindingRequestID: authority.bindingRequestID,
            bindingFrameID: authority.bindingFrameID, bindingCapturedAt: authority.bindingCapturedAt,
            acceptedContextRevision: authority.acceptedContextRevision, players: hands)
        return BodySnapshot(sessionGeneration: snapshot.sessionGeneration, frameID: snapshot.frameID,
            capturedAt: snapshot.capturedAt, cameraGeometryRevision: snapshot.cameraGeometryRevision,
            players: snapshot.players, wristContact: attachment)
    }

    func stop() { stopped = true; practice = nil; onBodySnapshot = nil; mailbox.revoke() }
}
#endif
