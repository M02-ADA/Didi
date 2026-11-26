#if DEBUG
import CoreGraphics
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

    @Test func theAvatarReceivesAirborneEvidenceWithValidSoles() throws {
        let script = try LaserReplayScript.load()
        let input = script.input.configuration
        let calibration = try #require(input.calibrations[.player1])
        let context = BodyInputContext(sessionGeneration: input.sessionGeneration,
                                       cameraGeometryRevision: script.input.cameraGeometryRevision,
                                       calibrationRevisions: [.player1: calibration.revision],
                                       cutovers: [:], isActive: true)
        let sole = try EstimatedScalar(value: 0.25, validity: .valid)
        let absent = try EstimatedScalar(value: nil, validity: .missingLandmarks)
        let player = PlayerBodySample(playerID: .player1, calibrationRevision: calibration.revision,
                                      trackingStatus: .reliable,
                                      geometry: .init(crownY: absent, leftWristY: absent, rightWristY: absent,
                                                      leftSoleY: sole, rightSoleY: sole, centerX: absent),
                                      jumpState: .init(phase: .airborne, validity: .valid))
        let snapshot = BodySnapshot(sessionGeneration: context.sessionGeneration, frameID: 1, capturedAt: 10,
                                    cameraGeometryRevision: context.cameraGeometryRevision, players: [.player1: player])
        let evidence = SoloAvatarPreviewSteering.avatarEvidence(context: context, snapshot: snapshot, capturedAt: 10)
        #expect(evidence?.airborne == true && evidence?.lowerSoleY == 0.25)
        #expect(SoloAvatarPreviewSteering.avatarEvidence(context: context, snapshot: snapshot, capturedAt: 11) == nil)
    }

    @Test func standingGuideUsesTheVisibleMirroredCameraBox() {
        let viewport = CGSize(width: 604, height: 745)
        let aspect = PlayerAcquisitionZones.builtInImageAspect
        let box = SoloAvatarStandingGuide.box(in: viewport, imageAspect: aspect)
        let zone = CalibrationStageLayout.sourceRect(for: box, in: viewport, aspect: aspect, fill: true)
        #expect(abs(box.width / box.height - CalibrationStageLayout.boxSize.width / CalibrationStageLayout.boxSize.height) < 0.001)
        #expect(!SoloAvatarStandingGuide.outsideZone(0.5, zone: zone))
        #expect(SoloAvatarStandingGuide.outsideZone(zone.minX - 0.01, zone: zone))
        #expect(SoloAvatarStandingGuide.outsideZone(zone.maxX + 0.01, zone: zone))
    }
}
#endif
