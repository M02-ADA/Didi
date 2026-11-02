import Foundation
import Testing
@testable import Sedactive

nonisolated private final class LH00TestBundle: NSObject {}

/// Shared synthetic builders. The JSON must be copied into the test bundle: no source-path fallback.
nonisolated enum LH00TestData {
    static func load(_ name: String = "cooperative-v2") throws -> ReplayFixture {
        let bundle = Bundle(for: LH00TestBundle.self)
        guard let url = bundle.url(forResource: name, withExtension: "json")
                ?? bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
            throw BodyInputContractError.invalidValue("missing bundled fixture: \(name)")
        }
        return try ReplayFixture.decode(Data(contentsOf: url))
    }

    static func fixture(_ records: [ReplayRecord], configuration: BodyInputConfiguration? = nil) throws -> ReplayFixture {
        let base = try load()
        return ReplayFixture(schemaVersion: 2,
                             configuration: configuration ?? base.configuration,
                             cameraGeometryRevision: 1, records: records)
    }

    static func configuration(_ base: BodyInputConfiguration, generation: UUID? = nil,
                              calibrations: [PlayerID: PlayerCalibration]? = nil,
                              capacity: Int = 8, policy: NoProgressPolicy = .disabled) -> BodyInputConfiguration {
        BodyInputConfiguration(sessionGeneration: generation ?? base.sessionGeneration,
                               calibrations: calibrations ?? base.calibrations,
                               playerPlaneLayout: base.playerPlaneLayout,
                               snapshotBufferCapacity: capacity, noProgressPolicy: policy)
    }

    static func snapshot(_ frameID: UInt64, capturedAt: Double? = nil, generation: UUID? = nil,
                         revision: UInt64 = 1, base: BodySnapshot? = nil) throws -> BodySnapshot {
        let original = try base ?? load().records[0].snapshot!
        return BodySnapshot(sessionGeneration: generation ?? original.sessionGeneration, frameID: frameID,
                            capturedAt: capturedAt ?? Double(frameID), cameraGeometryRevision: original.cameraGeometryRevision,
                            players: original.players.mapValues {
            PlayerBodySample(playerID: $0.playerID, calibrationRevision: revision,
                             trackingStatus: $0.trackingStatus, geometry: $0.geometry, jumpState: $0.jumpState)
        })
    }

    static func unavailableSample(_ id: PlayerID, tracking: TrackingStatus = .lost) throws -> PlayerBodySample {
        let missing = try EstimatedScalar(value: nil, validity: .notCalibrated)
        return PlayerBodySample(playerID: id, calibrationRevision: nil, trackingStatus: tracking,
                                geometry: BodyGeometry(crownY: missing, leftWristY: missing, rightWristY: missing,
                                                       leftSoleY: missing, rightSoleY: missing, centerX: missing),
                                jumpState: JumpState(phase: .unknown, validity: .notCalibrated))
    }

    static func calibration(_ original: PlayerCalibration, revision: UInt64,
                            sourceFrameID: UInt64 = 0, capturedAt: Double = 0,
                            generation: UUID? = nil, cameraRevision: UInt64? = nil) -> PlayerCalibration {
        PlayerCalibration(playerID: original.playerID, sessionGeneration: generation ?? original.sessionGeneration,
                          revision: revision, cameraGeometryRevision: cameraRevision ?? original.cameraGeometryRevision,
                          sourceFrameID: sourceFrameID, capturedAt: capturedAt,
                          standingCrownImageY: original.standingCrownImageY,
                          standingLeftSoleImageY: original.standingLeftSoleImageY,
                          standingRightSoleImageY: original.standingRightSoleImageY,
                          standingHipImageY: original.standingHipImageY,
                          standingBodyImageHeight: original.standingBodyImageHeight,
                          standingTorsoImageLength: original.standingTorsoImageLength,
                          headOffsetFromNoseShare: original.headOffsetFromNoseShare,
                          leftFootOffsetShare: original.leftFootOffsetShare,
                          rightFootOffsetShare: original.rightFootOffsetShare, mapping: original.mapping)
    }
}

nonisolated struct BodyInputContractTests {
    @Test func anonymousSlotsKeepFixedLanesAcrossDifferentGenerations() throws {
        let first = try LH00TestData.load()
        let second = try LH00TestData.load("two-player-recovery-v2")
        #expect(PlayerID.allCases == [.player1, .player2])
        #expect(first.configuration.sessionGeneration != second.configuration.sessionGeneration)
        for fixture in [first, second] {
            let packet = try #require(fixture.records[0].snapshot)
            #expect(Set(packet.players.keys) == Set(PlayerID.allCases))
            #expect(packet.players[.player1]?.geometry.centerX.value == -0.65)
            #expect(packet.players[.player2]?.geometry.centerX.value == 0.65)
            let p1CameraX = try #require(fixture.configuration.calibrations[.player1]?.mapping.originImageX)
            let p2CameraX = try #require(fixture.configuration.calibrations[.player2]?.mapping.originImageX)
            #expect(p1CameraX > p2CameraX) // Mirrored calibration binds displayed-left to P1.
        }
    }

    @Test func slotCodingUsesStringValuesAndObjectKeysWithoutProfileContext() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        #expect(String(decoding: try encoder.encode(PlayerID.player1), as: UTF8.self) == #""player1""#)
        let values: [PlayerID: Int] = [.player1: 1, .player2: 2]
        let data = try encoder.encode(values)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Int])
        #expect(object == ["player1": 1, "player2": 2])
        #expect(try decoder.decode([PlayerID: Int].self, from: data) == values)
        for invalid in ["player3", "00000000-0000-4000-8000-000000000001"] {
            #expect(throws: (any Error).self) {
                try decoder.decode(PlayerID.self, from: encoder.encode(invalid))
            }
            let invalidKeys = try encoder.encode([invalid: 1])
            #expect(throws: (any Error).self) { try decoder.decode([PlayerID: Int].self, from: invalidKeys) }
        }
        let config = try LH00TestData.load().configuration
        let configObject = try #require(JSONSerialization.jsonObject(with: encoder.encode(config)) as? [String: Any])
        #expect(Set(configObject.keys) == ["sessionGeneration", "calibrations", "playerPlaneLayout",
                                          "snapshotBufferCapacity", "noProgressPolicy"])
    }

    @Test(arguments: EvidenceValidity.allCases.filter { $0 != .valid })
    func unavailableIsNotZero(_ reason: EvidenceValidity) throws {
        let scalar = try EstimatedScalar(value: nil, validity: reason)
        #expect(scalar.value == nil)
        #expect(throws: BodyInputContractError.self) { try EstimatedScalar(value: 0, validity: reason) }
    }

    @Test func invalidNumbersAndDecodedInvalidScalarsAreRejected() throws {
        #expect(throws: BodyInputContractError.self) { try EstimatedScalar(value: nil, validity: .valid) }
        #expect(throws: BodyInputContractError.self) { try EstimatedScalar(value: .infinity, validity: .valid) }
        let data = Data(#"{"value":0,"validity":"missingLandmarks"}"#.utf8)
        #expect(throws: BodyInputContractError.self) { try JSONDecoder().decode(EstimatedScalar.self, from: data) }
        #expect(throws: BodyInputContractError.self) {
            try JumpState(phase: .airborne, validity: .identityUncertain).validate()
        }
    }

    @Test func sharedScalePreservesHeightsAndSlotsDeriveLanes() throws {
        let fixture = try LH00TestData.load()
        let config = fixture.configuration
        let first = try #require(config.calibrations[.player1])
        let second = try #require(config.calibrations[.player2])
        #expect(abs(first.mapping.gameY(imageY: first.standingCrownImageY, layout: config.playerPlaneLayout) - 1.6) < 1e-9)
        #expect(abs(second.mapping.gameY(imageY: second.standingCrownImageY, layout: config.playerPlaneLayout) - 1.05) < 1e-9)
        #expect(first.leftFootOffsetShare != first.rightFootOffsetShare)
        let standing = try #require(fixture.records[0].snapshot)
        #expect(standing.players[first.playerID]?.geometry.crownY.value == 1.6)
        #expect(standing.players[second.playerID]?.geometry.crownY.value == 1.05)
        let x = first.mapping.gameX(imageX: first.mapping.originImageX + 0.02, playerID: first.playerID,
                                        layout: config.playerPlaneLayout)
        #expect(abs(x - (-0.59)) < 1e-9) // Unmirrored displacement +0.06; display reflection belongs to Kevin.
        #expect(config.playerPlaneLayout.centerX(for: .player1) == -0.65)
        #expect(config.playerPlaneLayout.centerX(for: .player2) == 0.65)
        #expect(throws: BodyInputContractError.self) {
            try PlayerPlaneLayout(leftCenterX: 0, rightCenterX: 0, gameUnitsPerImageHeight: 2).validate()
        }
    }

    @Test func rawPoseKeepsAnatomicalWristConfidenceAndFrameLocalCandidates() throws {
        let generation = try LH00TestData.load().configuration.sessionGeneration
        let candidate = PoseCandidate(candidateID: 9,
                                      joints: [.leftWrist: PoseJoint(x: 0.2, y: 0.3, confidence: 0.9),
                                               .rightWrist: PoseJoint(x: 0.7, y: 0.4, confidence: 0.8)],
                                      maskTopImageY: nil, maskBottomImageY: nil,
                                      leftFootBottomImageY: nil, rightFootBottomImageY: nil, maskAssociation: .ambiguous)
        let frame = PoseFrame(sessionGeneration: generation, frameID: 1, capturedAt: 1,
                              cameraGeometryRevision: 1, imageWidth: 1920, imageHeight: 1280, candidates: [candidate])
        try frame.validate()
        #expect(frame.candidates[0].joints[.leftWrist]?.x == 0.2)
        #expect(frame.candidates[0].joints[.rightWrist]?.confidence == 0.8)
        #expect(frame.candidates[0].joints[.leftAnkle] == nil)
        #expect(throws: BodyInputContractError.self) { try PoseJoint(x: -1, y: 0, confidence: 1).validate() }
    }

    @Test func configurationAndSampleIdentityAreValidated() throws {
        let fixture = try LH00TestData.load()
        #expect(throws: BodyInputContractError.self) {
            try LH00TestData.configuration(fixture.configuration, capacity: 0).validate()
        }
        let sample = try #require(fixture.records[0].snapshot?.players.values.first)
        let uncertain = PlayerBodySample(playerID: sample.playerID, calibrationRevision: 1,
                                        trackingStatus: .uncertain, geometry: sample.geometry, jumpState: sample.jumpState)
        #expect(throws: BodyInputContractError.self) { try uncertain.validate() }
    }

    @Test func fixedSnapshotKeysAndCalibrationIdentityAreValidated() throws {
        let fixture = try LH00TestData.load()
        let snapshot = try LH00TestData.snapshot(1)
        let p1 = try #require(snapshot.players[.player1])
        let invalidSets: [[PlayerID: PlayerBodySample]] = [[:], [.player1: p1], [.player1: p1, .player2: p1]]
        for invalidPlayers in invalidSets {
            let invalid = BodySnapshot(sessionGeneration: snapshot.sessionGeneration, frameID: 1, capturedAt: 1,
                                       cameraGeometryRevision: 1, players: invalidPlayers)
            #expect(throws: BodyInputContractError.self) { try invalid.validate() }
        }
        let unavailable = BodySnapshot(sessionGeneration: snapshot.sessionGeneration, frameID: 1, capturedAt: 1,
                                       cameraGeometryRevision: 1,
                                       players: [.player1: try LH00TestData.unavailableSample(.player1),
                                                 .player2: try LH00TestData.unavailableSample(.player2)])
        try unavailable.validate()
        let baseline = try #require(fixture.configuration.calibrations[.player1])
        #expect(throws: BodyInputContractError.self) {
            try LH00TestData.configuration(fixture.configuration, calibrations: [.player2: baseline]).validate()
        }
    }

    @Test func rawCandidatePermutationPreservesDataWithoutPretendingToTrackPeople() throws {
        let generation = try LH00TestData.load().configuration.sessionGeneration
        let leftInPreview = PoseCandidate(candidateID: 9, joints: [.leftWrist: PoseJoint(x: 0.75, y: 0.4, confidence: 0.9)],
                                         maskTopImageY: nil, maskBottomImageY: nil, leftFootBottomImageY: nil,
                                         rightFootBottomImageY: nil, maskAssociation: .matched)
        let rightInPreview = PoseCandidate(candidateID: 2, joints: [.rightWrist: PoseJoint(x: 0.25, y: 0.6, confidence: 0.8)],
                                          maskTopImageY: nil, maskBottomImageY: nil, leftFootBottomImageY: nil,
                                          rightFootBottomImageY: nil, maskAssociation: .matched)
        let first = PoseFrame(sessionGeneration: generation, frameID: 1, capturedAt: 1, cameraGeometryRevision: 1,
                              imageWidth: 1920, imageHeight: 1280, candidates: [leftInPreview, rightInPreview])
        let reordered = PoseFrame(sessionGeneration: generation, frameID: 1, capturedAt: 1, cameraGeometryRevision: 1,
                                  imageWidth: 1920, imageHeight: 1280, candidates: [rightInPreview, leftInPreview])
        try first.validate()
        try reordered.validate()
        #expect(Dictionary(uniqueKeysWithValues: first.candidates.map { ($0.candidateID, $0) })
                == Dictionary(uniqueKeysWithValues: reordered.candidates.map { ($0.candidateID, $0) }))
        #expect(first.candidates.first != reordered.candidates.first)
        // This proves the raw schema preserves evidence. Live binding/reacquisition is later PlayerTracker work.
    }

}
