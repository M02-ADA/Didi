import Foundation
import Testing
@testable import Sedactive

nonisolated enum AdapterTestFactory: VisionAvatarPacketFactory {
  static func status(_ source: VisionNumericPoseStatus) -> VisionNumericPoseStatus { source }
  nonisolated struct Output {
    let source: PlayerTrackingSource
    let revision: UInt64
    let p1: PlayerTrackingSlotResult, p2: PlayerTrackingSlotResult
    let candidates: [PoseCandidate]
    let calibration: [PlayerID: VisionAvatarCalibrationValues]
  }
  static func output(source: PlayerTrackingSource, revision: UInt64,
    player1: PlayerTrackingSlotResult, player2: PlayerTrackingSlotResult,
    candidates: [PoseCandidate], calibration: [PlayerID: VisionAvatarCalibrationValues]) -> Output {
    .init(source:source,revision:revision,p1:player1,p2:player2,candidates:candidates,calibration:calibration)
  }
}
nonisolated struct VisionAvatarPacketAdapterTests {
  func fixture(calibration:Bool = false, mismatch:Bool = false) throws -> VisionNumericPoseDrain {
    let f = try TrackingIntegrationFixture();let p = try f.result(3,0.25,LiveVisionFixtures.standingPair)
    let tracking = LiveVisionFixtures.association(p,revision:2)
    let base = try #require(try LH00TestData.load().configuration.calibrations[.player1])
    let c = LH00TestData.calibration(base,revision:1,generation:f.context.generation)
    let cut = BodyInputCutover(frameID:1,capturedAt:0.1)
    let layout = LiveVisionFixtures.configuration(f.context.generation).playerPlaneLayout
    let status = VisionNumericPoseStatus(revision:5,active:true,context:tracking.source?.context,
      controlRevision:2,acceptedContextRevision:0,layout:calibration ? layout : nil,
      calibrationRevisions:calibration ? [.player1:mismatch ? 2 : 1] : [:],cutovers:calibration ? [.player1:cut] : [:])
    let output = VisionNumericPoseOutput(presentationRevision:5,tracking:tracking,pose:p.frame,
      acceptedCalibrations:calibration ? [.player1:c] : [:],cutovers:status.cutovers,layout:status.layout)
    return .init(status:status,resetAll:true,output:output)
  }
  @Test func directionOnlyKeepsOriginalSourceAndJoints() throws {
    let f = try fixture();let mapped = try VisionAvatarPacketAdapter.map(f,using:AdapterTestFactory.self)
    let out = try #require(mapped.output)
    #expect(out.source == f.output?.tracking.source && out.revision == 5)
    #expect(out.candidates == f.output?.pose.candidates)
    #expect(out.calibration.isEmpty && mapped.resetAll)
    #expect(out.p1.candidateID == 10 && out.p2.candidateID == 20)
    #expect(out.candidates[0].joints[.leftEye] == nil)
  }
  @Test func acceptedReferenceUsesExistingOffsetFormulaAndDoesNotCalibratePeer() throws {
    let f = try fixture(calibration:true)
    let batch = try VisionAvatarPacketAdapter.map(f,using:AdapterTestFactory.self)
    let output = try #require(batch.output);let c = try #require(f.output?.acceptedCalibrations[.player1])
    #expect(output.calibration[.player1]?.standingLeftAnkleImageY == c.standingLeftSoleImageY+c.leftFootOffsetShare*c.standingBodyImageHeight)
    #expect(output.calibration[.player2] == nil)
    let mismatched = try VisionAvatarPacketAdapter.map(fixture(calibration:true,mismatch:true),using:AdapterTestFactory.self)
    #expect(mismatched.output?.calibration.isEmpty == true)
  }
  @Test func inactiveDropsOutputAndForcesReset() throws {
    let f = try fixture()
    let status = VisionNumericPoseStatus(revision:6,active:false,context:f.status.context,
      controlRevision:3,acceptedContextRevision:0,layout:nil,calibrationRevisions:[:],cutovers:[:])
    let batch = try VisionAvatarPacketAdapter.map(VisionNumericPoseDrain(status:status,resetAll:false,output:f.output),using:AdapterTestFactory.self)
    #expect(batch.output == nil && batch.resetAll)
  }
  @Test func olderPresentationRevisionCannotBeRestamped() throws {
    let f = try fixture();let old = try #require(f.output)
    let output = VisionNumericPoseOutput(presentationRevision:4,tracking:old.tracking,pose:old.pose,
      acceptedCalibrations:[:],cutovers:[:],layout:nil)
    #expect(throws:VisionAvatarMappingError.stalePresentation) {
      try VisionAvatarPacketAdapter.map(VisionNumericPoseDrain(status:f.status,resetAll:false,output:output),using:AdapterTestFactory.self)
    }
  }
  @Test func mismatchedSourceControlCannotDrivePacket() throws {
    let f = try fixture();let status = VisionNumericPoseStatus(revision:5,active:true,context:f.status.context,
      controlRevision:99,acceptedContextRevision:0,layout:nil,calibrationRevisions:[:],cutovers:[:])
    #expect(throws:VisionAvatarMappingError.incompatibleSource) {
      try VisionAvatarPacketAdapter.map(VisionNumericPoseDrain(status:status,resetAll:false,output:f.output),using:AdapterTestFactory.self)
    }
  }
}
