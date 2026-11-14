import Foundation
@testable import Sedactive

/// Synthetic transport and LH-09/LH-10 expectations, not a second production hit checker.
nonisolated struct LaserReplayExpectation: Equatable, Sendable {
    let playerID: PlayerID
    let selectedFrameID: UInt64?
    /// Nil means a pause prevented finalization, not an automatic CLEAR.
    let judgement: Judgement?
    let checkpoint: Double
}

nonisolated struct LaserReplayScenario: Equatable, Sendable {
    let id: String
    let input: ReplayFixture
    let encounter: LaserEncounter
    let configuration: LaserRoundConfiguration
    /// Captured source seconds map to game seconds by subtracting this fixed epoch.
    let captureEpoch: Double
    let pauseAtGameTime: Double?
    let expected: [LaserReplayExpectation]
}

nonisolated enum LaserReplayScenarios {
    static func make() throws -> [LaserReplayScenario] {
        let generation = UUID(uuidString: "00000000-0000-4000-8000-000000000007")!
        let encounterID = UUID(uuidString: "00000000-0000-4000-8000-000000000008")!
        let attemptID = UUID(uuidString: "00000000-0000-4000-8000-000000000009")!
        let epoch = 100.0
        // Test-only values. The production timing/configuration still requires team review.
        let timing = try LaserEvidenceTiming(windowBefore: 0.35, windowAfter: 0.25, deliveryAllowance: 0.1)
        let configuration = try LaserRoundConfiguration(evidenceTiming: timing, clearanceMargin: 0.01, diamondPoints: nil)
        var calibrations: [PlayerID: PlayerCalibration] = [:]
        for id in PlayerID.allCases {
            let crown = id == .player1 ? 0.8 : 0.55
            calibrations[id] = PlayerCalibration(
                playerID: id, sessionGeneration: generation, revision: 1, cameraGeometryRevision: 1,
                sourceFrameID: 0, capturedAt: 0, standingCrownImageY: crown,
                standingLeftSoleImageY: 0, standingRightSoleImageY: 0, standingHipImageY: 0.3,
                standingBodyImageHeight: crown, standingTorsoImageLength: 0.2,
                headOffsetFromNoseShare: 0.1, leftFootOffsetShare: 0.02, rightFootOffsetShare: 0.03,
                mapping: ImageToPlayerPlaneMapping(imageAspectRatio: 1.5, floorImageY: 0, originImageX: 0.5))
        }
        let bodyConfiguration = BodyInputConfiguration(
            sessionGeneration: generation, calibrations: calibrations,
            playerPlaneLayout: PlayerPlaneLayout(leftCenterX: -0.65, rightCenterX: 0.65, gameUnitsPerImageHeight: 2))

        func packet(_ frame: UInt64, _ time: Double, crownInvalid: Bool = false,
                    overlaps: Bool = false, phase: JumpPhase = .grounded, soles: Double = 0) throws -> BodySnapshot {
            func scalar(_ value: Double) throws -> EstimatedScalar { try EstimatedScalar(value: value, validity: .valid) }
            var players: [PlayerID: PlayerBodySample] = [:]
            for id in PlayerID.allCases {
                let crown = try crownInvalid ? EstimatedScalar(value: nil, validity: .missingLandmarks)
                    : scalar(overlaps ? 1.1 : (id == .player1 ? 0.7 : 0.4))
                let wrist = try scalar(overlaps ? 1.1 : 0.3)
                players[id] = PlayerBodySample(
                    playerID: id, calibrationRevision: 1, trackingStatus: .reliable,
                    geometry: BodyGeometry(crownY: crown, leftWristY: wrist, rightWristY: wrist,
                                           leftSoleY: try scalar(soles), rightSoleY: try scalar(soles),
                                           centerX: try scalar(id == .player1 ? -0.65 : 0.65)),
                    jumpState: JumpState(phase: phase, validity: .valid))
            }
            return BodySnapshot(sessionGeneration: generation, frameID: frame, capturedAt: epoch + time,
                                cameraGeometryRevision: 1, players: players)
        }

        func scenario(_ id: String, _ records: [ReplayRecord], move: LaserMove = .duck,
                      secondCrossing: Double = 10, pause: Double? = nil,
                      expected: Judgement? = .clear, frame: UInt64? = 1) throws -> LaserReplayScenario {
            let targets = try PlayerID.allCases.map { player in
                let lower = move == .jump ? 0.05 : (player == .player1 ? 0.9 : 0.6)
                return try LaserTarget(playerID: player, calibrationRevision: 1, requiredMove: move,
                                       beam: LaserBeamBand(lowerY: lower, upperY: lower + 0.05),
                                       warningTime: 7, crossingTime: player == .player1 ? 10 : secondCrossing)
            }
            let input = ReplayFixture(schemaVersion: 2, configuration: bodyConfiguration,
                                      cameraGeometryRevision: 1, records: records)
            try input.validate()
            let expectations = targets.map { target in
                LaserReplayExpectation(playerID: target.playerID,
                                       selectedFrameID: secondCrossing != 10 && target.playerID == .player2 ? 2 : frame,
                                       judgement: expected, checkpoint: timing.finalizationTime(crossing: target.crossingTime))
            }
            return LaserReplayScenario(id: id, input: input,
                                       encounter: try LaserEncounter(id: encounterID, attemptID: attemptID, targets: targets),
                                       configuration: configuration, captureEpoch: epoch,
                                       pauseAtGameTime: pause, expected: expectations)
        }

        let clear = try packet(1, 10)
        let record = ReplayRecord(deliveredAt: 110.05, snapshot: clear)
        return [
            try scenario("R1", [record]),
            try scenario("R2", [ReplayRecord(deliveredAt: 110.05, snapshot: packet(1, 10, overlaps: true))],
                         expected: .hit(.insufficientClearance)),
            try scenario("R3", [ReplayRecord(deliveredAt: 109.5, snapshot: packet(1, 9.5))],
                         expected: .unavailable(.stale), frame: nil),
            try scenario("R4", [ReplayRecord(deliveredAt: 110.5, snapshot: clear)],
                         expected: .unavailable(.noSample), frame: nil),
            try scenario("R5", [ReplayRecord(deliveredAt: 110.02, snapshot: packet(1, 10, phase: .airborne, soles: 0.02)),
                                ReplayRecord(deliveredAt: 110.12, snapshot: packet(2, 10.1, soles: 0.3))],
                         move: .jump, expected: .hit(.insufficientClearance)),
            try scenario("R6", [record, ReplayRecord(deliveredAt: 110.1, snapshot: clear)]),
            try scenario("R7", [record], pause: 10.1, expected: nil, frame: nil),
            try scenario("R8", [record, ReplayRecord(deliveredAt: 110.55, snapshot: packet(2, 10.5))], secondCrossing: 10.5),
            try scenario("R9", [ReplayRecord(deliveredAt: 110.02, snapshot: packet(1, 10, crownInvalid: true)),
                                ReplayRecord(deliveredAt: 110.12, snapshot: packet(2, 10.1))], frame: 2)
        ]
    }
}
