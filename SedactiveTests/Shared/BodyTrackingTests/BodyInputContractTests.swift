import Foundation
import Testing
@testable import Sedactive

nonisolated private final class LH00TestBundle: NSObject {}

/// Shared synthetic builders. The JSON must be copied into the test bundle: no source-path fallback.
nonisolated enum LH00TestData {
    static func load(_ name: String = "cooperative-v1") throws -> ReplayFixture {
        let bundle = Bundle(for: LH00TestBundle.self)
        guard let url = bundle.url(forResource: name, withExtension: "json")
                ?? bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
            throw BodyInputContractError.invalidValue("missing bundled fixture: \(name)")
        }
        return try ReplayFixture.decode(Data(contentsOf: url))
    }

    static func fixture(_ records: [ReplayRecord], configuration: BodyInputConfiguration? = nil) throws -> ReplayFixture {
        let base = try load()
        return ReplayFixture(schemaVersion: 1, profiles: base.profiles,
                             configuration: configuration ?? base.configuration,
                             cameraGeometryRevision: 1, records: records)
    }

    static func configuration(_ base: BodyInputConfiguration, generation: UUID? = nil,
                              calibrations: [PlayerID: PlayerCalibration]? = nil,
                              capacity: Int = 8, policy: NoProgressPolicy = .disabled) -> BodyInputConfiguration {
        BodyInputConfiguration(sessionGeneration: generation ?? base.sessionGeneration,
                               selectedPlayers: base.selectedPlayers,
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

    static func calibration(_ original: PlayerCalibration, revision: UInt64,
                            sourceFrameID: UInt64 = 0, capturedAt: Double = 0) -> PlayerCalibration {
        PlayerCalibration(playerID: original.playerID, sessionGeneration: original.sessionGeneration,
                          revision: revision, cameraGeometryRevision: original.cameraGeometryRevision,
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
    @Test func persistentProfilesAndReversedSelection() throws {
        let first = try LH00TestData.load()
        let second = try LH00TestData.load("reversed-selection-v1")
        #expect(first.profiles == second.profiles)
        #expect(first.configuration.selectedPlayers.firstID == second.configuration.selectedPlayers.secondID)
        #expect(first.configuration.sessionGeneration != second.configuration.sessionGeneration)
        for fixture in [first, second] {
            let selected = fixture.configuration.selectedPlayers
            let packet = try #require(fixture.records[0].snapshot)
            #expect(packet.players[selected.firstID]?.geometry.centerX.value == -0.65)
            #expect(packet.players[selected.secondID]?.geometry.centerX.value == 0.65)
            let firstCameraX = try #require(fixture.configuration.calibrations[selected.firstID]?.mapping.originImageX)
            let secondCameraX = try #require(fixture.configuration.calibrations[selected.secondID]?.mapping.originImageX)
            #expect(firstCameraX > secondCameraX) // Displayed-left binding in a mirrored calibration preview.
        }
        #expect(throws: BodyInputContractError.self) {
            try SelectedPlayers(firstID: first.profiles[0].id, secondID: first.profiles[0].id).validate()
        }
        #expect(throws: BodyInputContractError.self) {
            try Player(id: first.profiles[0].id, name: "Kevin", weightKg: .nan).validate()
        }
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

    @Test func sharedScalePreservesHeightsAndSelectionDerivesLanes() throws {
        let fixture = try LH00TestData.load()
        let config = fixture.configuration
        let first = try #require(config.calibrations[config.selectedPlayers.firstID])
        let second = try #require(config.calibrations[config.selectedPlayers.secondID])
        #expect(abs(first.mapping.gameY(imageY: first.standingCrownImageY, layout: config.playerPlaneLayout) - 1.6) < 1e-9)
        #expect(abs(second.mapping.gameY(imageY: second.standingCrownImageY, layout: config.playerPlaneLayout) - 1.05) < 1e-9)
        #expect(first.leftFootOffsetShare != first.rightFootOffsetShare)
        let standing = try #require(fixture.records[0].snapshot)
        #expect(standing.players[first.playerID]?.geometry.crownY.value == 1.6)
        #expect(standing.players[second.playerID]?.geometry.crownY.value == 1.05)
        let x = try first.mapping.gameX(imageX: first.mapping.originImageX + 0.02, playerID: first.playerID,
                                        selection: config.selectedPlayers, layout: config.playerPlaneLayout)
        #expect(abs(x - (-0.59)) < 1e-9) // Unmirrored displacement +0.06; display reflection belongs to Kevin.
        let reversed = SelectedPlayers(firstID: second.playerID, secondID: first.playerID)
        #expect(try config.playerPlaneLayout.centerX(for: first.playerID, selection: reversed) == 0.65)
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
}
