import CoreVideo
import Foundation
import Testing
@testable import Sedactive

nonisolated struct LiveMeasurementCadenceTests {
  @Test func highRateNumericDoesNotIncreaseMasksOrRenameAnkles() throws {
    let f = try TrackingIntegrationFixture();var flow = LiveMeasurementFlow()
    for i in 1...30 {
      let pose = try f.result(UInt64(i),Double(i)/30,LiveVisionFixtures.standingPair)
      flow.process(pose:pose,association:LiveVisionFixtures.association(pose,revision:2),
        controlRevision:2,acceptedContextRevision:0,calibrations:[:],mask:nil)
    }
    let latest = try #require(flow.latest)
    #expect(latest.samples == 30 && latest.maskCompletions == 0)
    #expect(abs((latest.captureInterval ?? 0)-1/30.0)<0.000001)
    #expect(latest.players[.player1]?.observedLeftAnkleY != nil)
    #expect(latest.players[.player1]?.anatomy.leftSole.imageY == nil)
    #expect(latest.players[.player1]?.temporal.phase == .unknown)
    #expect(latest.players[.player1]?.temporal.reason.contains("reference") == true)
  }
  @Test func maskPersistsOnlyAsHistoricalDiagnosticNotCurrentSoles() throws {
    let f = try TrackingIntegrationFixture();var flow = LiveMeasurementFlow()
    for i in 1...2 {
      let pose = try f.result(UInt64(i),Double(i)/30,LiveVisionFixtures.standingPair)
      var mask = LiveVisionFixtures.mask(pose)
      mask.anatomy[.player1] = try AnatomyFixtures.frame(f,UInt64(i),Double(i)/30,feet:0.1)
      flow.process(pose:pose,association:LiveVisionFixtures.association(pose,revision:2),controlRevision:2,
        acceptedContextRevision:0,calibrations:[:],mask:i==1 ? mask : nil)
    }
    let l = try #require(flow.latest)
    #expect(l.lastMaskSource?.frameID == 1 && l.maskCompletions == 1)
    #expect(l.lastMaskAnatomy[.player1]?.leftSole.status == .experimental)
    #expect(l.players[.player1]?.anatomy.leftSole.status == .missingLandmarks)
    #expect(l.players[.player1]?.anatomy.source.frameID == 2)
  }
  @Test func cancellationCannotPublishLateMaskOrRestoreOldReference() throws {
    var f = try TrackingIntegrationFixture();try f.bind()
    try f.gate.configureBody(LiveVisionFixtures.configuration(f.context.generation))
    let token = try f.gate.requestCalibration(id:UUID())
    let pose = try f.result(3,0.25,LiveVisionFixtures.standingPair)
    let stamp = try #require(f.gate.admit(pose.source));try #require(try f.finish(pose,stamp:stamp))
    let receipt = try #require(f.gate.snapshot.latest)
    f.gate.cancelCalibration(token)
    f.gate.publishMeasurements(pose,admission:stamp,receipt:receipt,mask:LiveVisionFixtures.mask(pose))
    #expect(f.gate.readBody().measurements?.maskCompletions == 0)
    f.gate.sourceLost(f.context)
    f.gate.publishMeasurements(pose,admission:stamp,receipt:receipt,mask:nil)
    #expect(f.gate.readBody().measurements == nil)
  }
  @Test func staleFramesAndContextChangesResetExperiment() throws {
    let f = try TrackingIntegrationFixture();var flow = LiveMeasurementFlow()
    let p = try f.result(1,0.1,LiveVisionFixtures.standingPair)
    let a = LiveVisionFixtures.association(p,revision:2)
    flow.process(pose:p,association:a,controlRevision:2,acceptedContextRevision:0,calibrations:[:],mask:nil)
    flow.process(pose:p,association:a,controlRevision:2,acceptedContextRevision:0,calibrations:[:],mask:nil)
    #expect(flow.latest == nil)
    let next = try f.result(2,0.2,LiveVisionFixtures.standingPair)
    flow.process(pose:next,association:LiveVisionFixtures.association(next,revision:3),
      controlRevision:3,acceptedContextRevision:1,calibrations:[:],mask:nil)
    #expect(flow.latest?.samples == 1 && flow.latest?.captureInterval == nil)
  }
  @Test func syntheticLiveAdapterCanAccumulateOnlyExactFrameFeetWithExplicitReference() throws {
    let f = try TrackingIntegrationFixture();var flow = LiveMeasurementFlow()
    let base = try #require(try LH00TestData.load().configuration.calibrations[.player1])
    let calibration = LH00TestData.calibration(base,revision:1,generation:f.context.generation)
    let ref = ExperimentalStandingSurface(source:f.context,playerID:.player1,controlRevision:2,
      calibrationRevision:1,leftSoleY:0.1,rightSoleY:0.1,hipY:0.4,uncertaintyImageY:0.01)
    for i in 1...6 {
      let t = Double(i)*0.05
      let candidates = LiveVisionFixtures.standingPair.map { c in
        var joints = c.joints
        if i > 3 {
          for name in [BodyJoint.leftHip, .rightHip] {
            if let point = joints[name] { joints[name] = .init(x:point.x,y:point.y+0.05,confidence:point.confidence) }
          }
        }
        return PoseCandidate(candidateID:c.candidateID,joints:joints,maskTopImageY:nil,
          maskBottomImageY:nil,leftFootBottomImageY:nil,rightFootBottomImageY:nil,maskAssociation:.unavailable)
      }
      let pose = try f.result(UInt64(i),t,candidates)
      var mask = LiveVisionFixtures.mask(pose)
      mask.anatomy[.player1] = try AnatomyFixtures.frame(f,UInt64(i),t,feet:i<=3 ? 0.1 : 0.15)
      flow.process(pose:pose,association:LiveVisionFixtures.association(pose,revision:2),controlRevision:2,
        acceptedContextRevision:1,calibrations:[.player1:calibration],mask:mask,
        references:[.player1:ref],stationaryCameraEvidence:true)
    }
    let player = try #require(flow.latest?.players[.player1])
    #expect(player.temporal.phase == .airborneCandidate)
    #expect(player.temporal.authoritative.validity != .valid)
    #expect(flow.latest?.players[.player2]?.temporal.phase == .unknown)
  }
  @Test func existingWorkerPublishesNumericCadenceWhileDisarmedWithoutMaskRequest() async throws {
    let store = FrameStore();let context = CameraTestFrames.context()
    _ = store.begin(context)
    try store.tracking.configureBody(LiveVisionFixtures.configuration(context.generation))
    let sink = CameraCopySink(metrics:store.metrics,poses:store.poses,tracking:store.tracking,
      makeDetector:{ SprintPoseDetector() })
    let buffer = try CameraTestFrames.buffer()
    for _ in 0..<2 {
      let meta = CameraFrameMetadata(context:context,frameID:try store.nextIdentity(context),capturedAt:CameraHostClock.now(),
        descriptor:try CameraFrameDescriptor(width:8,height:8,bytesPerRow:CVPixelBufferGetBytesPerRow(buffer),
          pixelFormat:kCVPixelFormatType_32BGRA,maximumBytes:1024),rotationAngle:180,mirrored:false)
      try store.copy(buffer,metadata:meta);let lease = try CameraTestFrames.lease(store,context)
      try await sink.consume(lease.frame);store.complete(lease)
    }
    let read = store.tracking.readBody()
    #expect(read.measurements?.samples == 2 && read.measurements?.maskCompletions == 0)
    #expect(read.measurements?.players[.player1]?.confirmedAssociation == false)
    store.end(context);await sink.reset()
    #expect(store.tracking.readBody().measurements == nil)
  }
}
