import Foundation
import Testing
@testable import Sedactive

/// Synthetic consumer evidence for D07. No rig, camera, accepted live anatomy,
/// production tuning, or spatial/temporal tolerance is certified by this suite.
nonisolated struct D07FairnessAuthorityTests {
    struct HeightPair: Sendable {
        let first: Double
        let second: Double
    }

    static let pairs = [HeightPair(first: 1, second: 1.6), HeightPair(first: 1.6, second: 1),
                        HeightPair(first: 1.3, second: 1.75), HeightPair(first: 1.75, second: 1.3)]

    struct PlayerCase: Sendable {
        let heights: HeightPair
        let player: PlayerID
    }

    static let playerCases = pairs.flatMap { pair in
        PlayerID.allCases.map { PlayerCase(heights: pair, player: $0) }
    }

    private struct Fixture {
        let configuration: LaserRoundConfiguration
        let context: BodyInputContext
        let encounter: LaserEncounter
        let heights: [PlayerID: Double]

        func packet(frame: UInt64, capture: Double,
                    change: (PlayerID, Double) throws -> PlayerBodySample) throws -> BodySnapshot {
            let players = try Dictionary(uniqueKeysWithValues: PlayerID.allCases.map { player in
                (player, try change(player, heights[player]!))
            })
            let snapshot = BodySnapshot(sessionGeneration: context.sessionGeneration, frameID: frame,
                capturedAt: 100 + capture, cameraGeometryRevision: 1, players: players)
            try snapshot.validate()
            return snapshot
        }

        func key(_ player: PlayerID) -> LaserTargetKey {
            LaserTargetKey(encounterID: encounter.id, attemptID: encounter.attemptID, playerID: player)
        }
    }

    private func fixture(_ pair: HeightPair, move: LaserMove) throws -> Fixture {
        let generation = UUID()
        let layout = PlayerPlaneLayout(leftCenterX: -0.65, rightCenterX: 0.65, gameUnitsPerImageHeight: 2)
        let heights: [PlayerID: Double] = [.player1: pair.first, .player2: pair.second]
        let calibrations = try Dictionary(uniqueKeysWithValues: PlayerID.allCases.map { player in
            let height = heights[player]!, floor = 0.1
            let calibration = PlayerCalibration(playerID: player, sessionGeneration: generation, revision: 1,
                cameraGeometryRevision: 1, sourceFrameID: 0, capturedAt: 100,
                standingCrownImageY: floor + height / 2, standingLeftSoleImageY: floor,
                standingRightSoleImageY: floor, standingHipImageY: floor + height * 0.52 / 2,
                standingBodyImageHeight: height / 2, standingTorsoImageLength: height * 0.3 / 2,
                headOffsetFromNoseShare: 0.07, leftFootOffsetShare: 0.04, rightFootOffsetShare: 0.04,
                mapping: ImageToPlayerPlaneMapping(imageAspectRatio: 1.5, floorImageY: floor,
                                                   originImageX: player == .player1 ? 0.7 : 0.3))
            try calibration.validate()
            return (player, calibration)
        })
        let configuration = try LaserRoundConfiguration(
            evidenceTiming: LaserEvidenceTiming(windowBefore: 0.35, windowAfter: 0.25, deliveryAllowance: 0.1),
            clearanceMargin: 0.005, diamondPoints: nil,
            scheduling: LaserSchedulingConfiguration(players: [.player1: .conservativeCandidate,
                                                                 .player2: .conservativeCandidate],
                                                      searchStep: 0.25, maximumSearchSteps: 200))
        let schedule = try LaserWaveDirector().schedule(
            script: [LaserWaveBeat(id: UUID(), move: move, nominalCrossingTime: 10, segmentEnd: 60)],
            calibrations: calibrations, layout: layout, configuration: configuration)
        let encounter = try #require(schedule.encounters.first)
        #expect(schedule.deferred.isEmpty)
        #expect(encounter.targets.count == 2)
        let context = BodyInputContext(sessionGeneration: generation, cameraGeometryRevision: 1,
            calibrationRevisions: [.player1: 1, .player2: 1], cutovers: [:], isActive: true)
        return Fixture(configuration: configuration, context: context, encounter: encounter, heights: heights)
    }

    private func sample(_ player: PlayerID, height: Double, raisedWrist: Bool? = nil,
                        loweredFoot: Bool? = nil, jump: JumpState = JumpState(phase: .airborne, validity: .valid))
        throws -> PlayerBodySample {
        func valid(_ value: Double) throws -> EstimatedScalar { try EstimatedScalar(value: value, validity: .valid) }
        return try PlayerBodySample(playerID: player, calibrationRevision: 1, trackingStatus: .reliable,
            geometry: BodyGeometry(crownY: valid(height * 0.9),
                leftWristY: valid(height * (raisedWrist == true ? 0.95 : 0.4)),
                rightWristY: valid(height * (raisedWrist == false ? 0.95 : 0.4)),
                leftSoleY: valid(loweredFoot == true ? 0 : height * 0.04),
                rightSoleY: valid(loweredFoot == false ? 0 : height * 0.04),
                centerX: valid(player == .player1 ? -0.65 : 0.65)), jumpState: jump)
    }

    private func game(_ fixture: Fixture) throws -> LaserGame {
        var game = try LaserGame(configuration: fixture.configuration, context: fixture.context,
                                 historyCapacityPerPlayer: 20)
        try game.register(fixture.encounter)
        return game
    }

    @Test(arguments: playerCases, [true, false])
    func eitherRaisedWristHitsOnlyItsOwnCalibratedPlayer(_ test: PlayerCase, _ leftWrist: Bool) throws {
        let offender = test.player
        let fixture = try fixture(test.heights, move: .duck)
        let packet = try fixture.packet(frame: 1, capture: 10) { player, height in
            try sample(player, height: height, raisedWrist: player == offender ? leftWrist : nil)
        }
        var game = try game(fixture)
        try game.receive(packet, capturedGameTime: 10, arrivedAt: 10.1)
        try game.advance(to: 10.35)
        for player in PlayerID.allCases {
            #expect(game.judgement(for: fixture.key(player)) ==
                    (player == offender ? .hit(.insufficientClearance) : .clear))
        }
        #expect(game.teamHealth == 4)
        #expect(game.teamScore == 100)
    }

    @Test(arguments: playerCases, [true, false])
    func oneFootLiftCannotClearEvenWithAnAirborneFlag(_ test: PlayerCase, _ leftFootGrounded: Bool) throws {
        let offender = test.player
        let fixture = try fixture(test.heights, move: .jump)
        let packet = try fixture.packet(frame: 1, capture: 10) { player, height in
            try sample(player, height: height, loweredFoot: player == offender ? leftFootGrounded : nil)
        }
        var game = try game(fixture)
        try game.receive(packet, capturedGameTime: 10, arrivedAt: 10.1)
        try game.advance(to: 10.35)
        for player in PlayerID.allCases {
            #expect(game.judgement(for: fixture.key(player)) ==
                    (player == offender ? .hit(.insufficientClearance) : .clear))
        }
    }

    @Test(arguments: playerCases, [EvidenceValidity.valid, .missingLandmarks, .stale])
    func clearSolesCannotReplaceAirborneEvidence(_ test: PlayerCase, _ validity: EvidenceValidity) throws {
        let offender = test.player
        let fixture = try fixture(test.heights, move: .jump)
        let packet = try fixture.packet(frame: 1, capture: 10) { player, height in
            let jump = player == offender
                ? JumpState(phase: validity == .valid ? .grounded : .unknown, validity: validity)
                : JumpState(phase: .airborne, validity: .valid)
            return try sample(player, height: height, jump: jump)
        }
        var game = try game(fixture)
        try game.receive(packet, capturedGameTime: 10, arrivedAt: 10.1)
        try game.advance(to: 10.35)
        for player in PlayerID.allCases {
            let expected: Judgement
            if player != offender { expected = .clear }
            else if validity == .valid { expected = .hit(.notAirborne) }
            else { expected = .unavailable(.invalidEvidence(.jumpPhase, validity)) }
            #expect(game.judgement(for: fixture.key(player)) == expected)
        }
        #expect(game.teamHealth == (validity == .valid ? 4 : 5))
        #expect(game.teamScore == (validity == .valid ? 100 : 0))
    }

    @Test(arguments: pairs, PlayerID.allCases)
    func latestClearPoseCannotOverwriteTheSelectedRaisedWristFrame(_ pair: HeightPair,
                                                                _ offender: PlayerID) throws {
        let fixture = try fixture(pair, move: .duck)
        let atCrossing = try fixture.packet(frame: 1, capture: 10) { player, height in
            try sample(player, height: height, raisedWrist: player == offender ? true : nil)
        }
        let latest = try fixture.packet(frame: 2, capture: 10.2) { player, height in
            try sample(player, height: height)
        }
        var game = try game(fixture)
        try game.receive(atCrossing, capturedGameTime: 10, arrivedAt: 10.1)
        try game.receive(latest, capturedGameTime: 10.2, arrivedAt: 10.3)
        try game.advance(to: 10.35)
        for player in PlayerID.allCases {
            guard case .selected(let evidence) = game.selection(for: fixture.key(player)) else {
                Issue.record("Expected the capture at crossing, not the latest display candidate")
                return
            }
            #expect(evidence.snapshot.frameID == atCrossing.frameID)
            #expect(evidence.capturedGameTime == 10)
            #expect(game.judgement(for: fixture.key(player)) ==
                    (player == offender ? .hit(.insufficientClearance) : .clear))
        }
    }
}
