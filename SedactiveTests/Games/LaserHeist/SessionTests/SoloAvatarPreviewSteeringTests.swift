#if DEBUG
import Testing
@testable import Sedactive

@MainActor struct SoloAvatarPreviewSteeringTests {
    @Test(arguments: [-1.0, 1.0])
    func aSustainedLeanMovesTheBoardInTheMirroredDirection(direction: Double) throws {
        let script = try LaserReplayScript.load()
        let input = script.input.configuration
        let calibration = try #require(input.calibrations[.player1])
        let context = BodyInputContext(sessionGeneration: input.sessionGeneration,
                                       cameraGeometryRevision: script.input.cameraGeometryRevision,
                                       calibrationRevisions: [.player1: calibration.revision],
                                       cutovers: [:], isActive: true)
        let steering = SoloAvatarPreviewSteering(layout: input.playerPlaneLayout)
        let initialX = try #require(steering.update(now: 10, context: context, snapshot: nil, calibration: calibration))
        let height = LaserLiveRoundGeometryV1.standingHeight(calibration, layout: input.playerPlaneLayout)
        let absent = try EstimatedScalar(value: nil, validity: .missingLandmarks)
        let center = try EstimatedScalar(value: input.playerPlaneLayout.centerX(for: .player1), validity: .valid)
        let lean = try EstimatedScalar(value: -direction * 0.08 * height, validity: .valid)
        let sample = PlayerBodySample(
            playerID: .player1, calibrationRevision: calibration.revision, trackingStatus: .reliable,
            geometry: .init(crownY: absent, leftWristY: absent, rightWristY: absent, leftSoleY: absent,
                            rightSoleY: absent, centerX: center, trunkLeanX: lean),
            jumpState: .init(phase: .grounded, validity: .valid)
        )

        var last: BodySnapshot?
        for frame in 1...16 {
            let now = 10 + Double(frame) / 30
            last = BodySnapshot(sessionGeneration: input.sessionGeneration, frameID: UInt64(frame),
                                capturedAt: now - 0.01, cameraGeometryRevision: context.cameraGeometryRevision,
                                players: [.player1: sample])
            _ = steering.update(now: now, context: context, snapshot: last, calibration: calibration)
        }

        let movedX = try #require(steering.update(now: 10.54, context: context, snapshot: last, calibration: calibration))
        #expect((movedX - initialX) * direction > 0.2)
        let staleX = steering.update(now: 11, context: context, snapshot: last, calibration: calibration)
        #expect(steering.update(now: 12, context: context, snapshot: last, calibration: calibration) == staleX)
        #expect(steering.update(now: 12, context: nil, snapshot: last, calibration: calibration) == nil)
    }
}
#endif
