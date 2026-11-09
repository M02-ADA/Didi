import Foundation
import CoreVideo
import Testing
@testable import Sedactive

nonisolated struct VisionNumericPoseBridgeTests {
  @Test func existingWorkerDeliversWithoutStartingCP1Provider() async throws {
    let store = FrameStore();let context = CameraTestFrames.context();_ = store.begin(context)
    let bridge = VisionNumericPoseBridge(gate:store.tracking);let lease = try bridge.attach()
    _ = try store.tracking.arm(request:store.tracking.makeBindingRequest())
    let sink = CameraCopySink(metrics:store.metrics,poses:store.poses,tracking:store.tracking,
      makeDetector:{ SprintPoseDetector() })
    let buffer = try CameraTestFrames.buffer();let base = CameraHostClock.now()-0.3
    for i in 1...2 {
      let source = CameraFrameMetadata(context:context,frameID:try store.nextIdentity(context),
        capturedAt:base+Double(i-1)*0.125,descriptor:try CameraFrameDescriptor(width:8,height:8,
          bytesPerRow:CVPixelBufferGetBytesPerRow(buffer),pixelFormat:kCVPixelFormatType_32BGRA,maximumBytes:1024),rotationAngle:180,mirrored:false)
      try store.copy(buffer,metadata:source);let job = try CameraTestFrames.lease(store,context)
      try await sink.consume(job.frame);store.complete(job)
    }
    let output = try #require(bridge.drain(lease)?.output)
    #expect(output.tracking.player1.state == .tracking && output.tracking.player2.state == .tracking)
    #expect(output.pose.frameID == 2 && output.acceptedCalibrations.isEmpty)
    #expect(store.tracking.readBody().context == nil) // no CP1 lifecycle or subscription required
    store.end(context);await sink.reset()
    let stopped = try #require(bridge.drain(lease))
    #expect(!stopped.status.active && stopped.resetAll && stopped.output == nil)
  }
  @Test func exactSourceJointsAndIndependentHealthySlotSurviveLatestOnlyDelivery() throws {
    var f = try TrackingIntegrationFixture();let bridge = VisionNumericPoseBridge(gate:f.gate)
    let lease = try bridge.attach();try f.bind()
    for i in 3...5 {
      var candidates = LiveVisionFixtures.standingPair
      let c = candidates[0];var j = c.joints
      j.removeValue(forKey:.leftWrist)
      j[.rightWrist] = .init(x:0,y:0,confidence:0.1)
      candidates[0] = .init(candidateID:c.candidateID,joints:j,maskTopImageY:nil,maskBottomImageY:nil,
        leftFootBottomImageY:nil,rightFootBottomImageY:nil,maskAssociation:.unavailable)
      let p = try f.result(UInt64(i),Double(i)*0.125,candidates)
      let admission = try #require(f.gate.admit(p.source));try #require(try f.finish(p,stamp:admission))
      let receipt = try #require(f.gate.snapshot.latest)
      f.gate.publishPresentation(p,admission:admission,receipt:receipt)
    }
    let drain = try #require(bridge.drain(lease));let output = try #require(drain.output)
    #expect(output.pose.frameID == 5 && output.tracking.source?.context.epoch == f.context.epoch)
    #expect(output.presentationRevision == drain.status.revision)
    #expect(output.pose.candidates[0].joints[.leftWrist] == nil)
    #expect(output.pose.candidates[0].joints[.rightWrist] == PoseJoint(x:0,y:0,confidence:0.1))
    #expect(output.acceptedCalibrations.isEmpty && output.layout == nil)
    #expect(bridge.drain(lease)?.output == nil)
  }
  @Test func preAttachmentFrameCannotBorrowNewPresentationRevision() throws {
    var f = try TrackingIntegrationFixture();try f.bind()
    let p = try f.result(3,0.25)
    let old = try #require(f.gate.admit(p.source))
    let bridge = VisionNumericPoseBridge(gate:f.gate);let lease = try bridge.attach()
    try #require(try f.finish(p,stamp:old));let result = try #require(f.gate.snapshot.latest)
    f.gate.publishPresentation(p,admission:old,receipt:result)
    #expect(bridge.drain(lease)?.output == nil)
  }
  @Test func cancelAndSourceLossPreventLatePublicationAndOldLeaseReplay() throws {
    var f = try TrackingIntegrationFixture();let bridge = VisionNumericPoseBridge(gate:f.gate)
    let oldLease = try bridge.attach();try f.bind()
    let p = try f.result(3,0.25)
    let stamp = try #require(f.gate.admit(p.source));try #require(try f.finish(p,stamp:stamp))
    let receipt = try #require(f.gate.snapshot.latest)
    bridge.cancel(oldLease);let lease = try bridge.attach();bridge.cancel(oldLease)
    f.gate.publishPresentation(p,admission:stamp,receipt:receipt)
    #expect(bridge.drain(oldLease) == nil)
    #expect(bridge.drain(lease)?.output == nil)
    f.gate.sourceLost(f.context)
    f.gate.publishPresentation(p,admission:stamp,receipt:receipt)
    let result = try #require(bridge.drain(lease))
    #expect(!result.status.active && result.resetAll && result.output == nil)
  }
  @Test func noFrameExpiryRejectsAtFreshnessBoundaryAndKeepsResetUntilDrain() throws {
    var f = try TrackingIntegrationFixture();let bridge = VisionNumericPoseBridge(gate:f.gate)
    let lease = try bridge.attach();try f.bind()
    let p = try f.result(3,0.25)
    let stamp = try #require(f.gate.admit(p.source));try #require(try f.finish(p,stamp:stamp))
    let receipt = try #require(f.gate.snapshot.latest)
    f.gate.publishPresentation(p,admission:stamp,receipt:receipt)
    _ = bridge.drain(lease)
    f.clock.time = 0.75
    let expired = try #require(bridge.drain(lease))
    #expect(expired.resetAll && !expired.status.active && expired.output == nil)
    #expect(f.gate.snapshot.revision == stamp.revision) // expiry didn't invent control/generation
  }
  @Test func uncertainSlotDoesNotReplaceOrInventObservedJoints() throws {
    var f = try TrackingIntegrationFixture();let bridge = VisionNumericPoseBridge(gate:f.gate)
    let lease = try bridge.attach();try f.bind()
    let p = try f.result(3,0.25,[TrackingFixtures.candidate(10,x:0.75)])
    let stamp = try #require(f.gate.admit(p.source));try #require(try f.finish(p,stamp:stamp))
    let receipt = try #require(f.gate.snapshot.latest)
    f.gate.publishPresentation(p,admission:stamp,receipt:receipt)
    let output = try #require(bridge.drain(lease)?.output)
    #expect(output.tracking.player1.state == .tracking && output.tracking.player2.state != .tracking)
    #expect(output.pose.candidates.count == 1)
    #expect(output.pose.candidates[0].joints[.leftAnkle] == nil)
  }
  @Test func revocationResetIsNotLostWhenNewSourceStatusIsCoalesced() throws {
    var f = try TrackingIntegrationFixture();let bridge = VisionNumericPoseBridge(gate:f.gate)
    let lease = try bridge.attach();try f.bind()
    let p = try f.result(3,0.25)
    let stamp = try #require(f.gate.admit(p.source));try #require(try f.finish(p,stamp:stamp))
    f.gate.revoke();f.gate.resume(f.context)
    _ = f.gate.admit(try f.result(4,0.3).source)
    let result = try #require(bridge.drain(lease))
    #expect(result.resetAll && !result.status.active && result.output == nil)
    #expect(f.gate.snapshot.requestID == nil)
  }
}
