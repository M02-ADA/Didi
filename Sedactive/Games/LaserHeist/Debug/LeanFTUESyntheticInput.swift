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
        let share: Double = hold || tutorial.isSuspended || now - stageStart < 3 ? 0
            : stage == .practiceLeft ? 0.08 : stage == .practiceRight ? -0.08 : 0
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
        mailbox.offer(source.output(snapshot, joints: pose))
        onBodySnapshot?(snapshot, now)
        return true
    }
    func stop() { stopped = true; practice = nil; onBodySnapshot = nil; mailbox.revoke() }
}
#endif
