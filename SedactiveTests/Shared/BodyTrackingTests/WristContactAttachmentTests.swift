import Foundation
import Testing
@testable import Sedactive

nonisolated struct WristContactAttachmentTests {
  private func fixture() throws -> (BodySnapshot, BodyInputContext, LiveBodyInputState) {
    let (f,b,a) = try WristEvidenceTests().fixture();var body = b
    let pose = try f.result(3,0.25,LiveVisionFixtures.standingPair)
    body.publish(pose,association:LiveVisionFixtures.association(pose,revision:a.revision),
      admission:a,acknowledgment:f.gate.snapshot.acknowledgment)
    let snapshot = try #require(body.latest), value = try #require(snapshot.wristContact)
    let authority = WristContactContextV1(sourceEpoch:value.sourceEpoch,controlRevision:value.controlRevision,
      bindingRequestID:value.bindingRequestID,bindingFrameID:value.bindingFrameID,
      bindingCapturedAt:value.bindingCapturedAt,acceptedContextRevision:value.acceptedContextRevision,freshness:0.5)
    return (snapshot,try #require(body.context(active:true,wristContact:authority)),body)
  }
  @Test func exactAtomicAttachmentAndRoundtrip() throws {
    let (s,c,b) = try fixture();let v = try #require(s.wristContact)
    try s.validate()
    #expect(v.sourceFrameID == s.frameID && v.sourceCapturedAt == s.capturedAt)
    #expect(v.sourceEpoch == b.source?.epoch && v.acceptedContextRevision == b.acceptedRevision)
    #expect(c.acceptsWristContact(s,playerID:.player1,at:0.26,afterFrameID:2,afterCapturedAt:0.125))
    #expect(c.acceptsWristContact(s,playerID:.player2,at:0.26,afterFrameID:2,afterCapturedAt:0.125))
    #expect(try JSONDecoder().decode(BodySnapshot.self,from:JSONEncoder().encode(s)) == s)
  }
  @Test func heldSampleMustNotBecomeANewContactOnResumeOrAfterProcessing() throws {
    let (s,c,_) = try fixture()
    #expect(!c.acceptsWristContact(s,playerID:.player1,at:0.3,afterFrameID:3,afterCapturedAt:0.25))
    #expect(!c.acceptsWristContact(s,playerID:.player1,at:0.3,afterFrameID:2,afterCapturedAt:0.25))
    #expect(!c.acceptsWristContact(s,playerID:.player1,at:0.3,afterFrameID:3,afterCapturedAt:0.125))
  }
  @Test(arguments:[0.499999,0.5,0.500001]) func unchangedFreshnessBoundary(_ age:Double) throws {
    let (s,c,_) = try fixture()
    #expect(c.acceptsWristContact(s,playerID:.player1,at:s.capturedAt+age,afterFrameID:2,afterCapturedAt:0.125) == (age < 0.5))
  }
  @Test(arguments:["epoch","control","request","accepted","binding","calibration","cutover","inactive","generation","geometry"])
  func currentAuthorityChangesRejectOldEvidence(_ change:String) throws {
    let (s,c,_) = try fixture();let a = try #require(c.wristContact)
    let changed = WristContactContextV1(sourceEpoch:change == "epoch" ? UUID() : a.sourceEpoch,
      controlRevision:a.controlRevision+(change == "control" ? 1 : 0),
      bindingRequestID:change == "request" ? UUID() : a.bindingRequestID,
      bindingFrameID:a.bindingFrameID+(change == "binding" ? 1 : 0),bindingCapturedAt:a.bindingCapturedAt,
      acceptedContextRevision:a.acceptedContextRevision+(change == "accepted" ? 1 : 0),freshness:0.5)
    let context = BodyInputContext(sessionGeneration:change == "generation" ? UUID() : c.sessionGeneration,
      cameraGeometryRevision:c.cameraGeometryRevision+(change == "geometry" ? 1 : 0),
      calibrationRevisions:change == "calibration" ? [:] : c.calibrationRevisions,
      cutovers:change == "cutover" ? [:] : c.cutovers,isActive:change != "inactive",wristContact:changed)
    #expect(!context.acceptsWristContact(s,playerID:.player1,at:0.26,afterFrameID:2,afterCapturedAt:0.125))
  }
  @Test func attachmentReuseWithDifferentSnapshotIsInvalid() throws {
    let (s,c,_) = try fixture()
    let mismatch = BodySnapshot(sessionGeneration:s.sessionGeneration,frameID:4,capturedAt:0.3,
      cameraGeometryRevision:s.cameraGeometryRevision,players:s.players,wristContact:s.wristContact)
    #expect(throws:BodyInputContractError.self) { try mismatch.validate() }
    #expect(!c.acceptsWristContact(mismatch,playerID:.player1,at:0.31,afterFrameID:2,afterCapturedAt:0.125))
  }
  @Test func missingAttachmentPreservesLegacyBehaviorButNeverMeansContact() throws {
    let (s,c,_) = try fixture()
    let old = BodySnapshot(sessionGeneration:s.sessionGeneration,frameID:s.frameID,capturedAt:s.capturedAt,
      cameraGeometryRevision:s.cameraGeometryRevision,players:s.players)
    #expect(c.accepts(old))
    #expect(!c.acceptsWristContact(old,playerID:.player1,at:0.26,afterFrameID:2,afterCapturedAt:0.125))
    let encoded = try JSONEncoder().encode(old)
    #expect(!String(decoding:encoded,as:UTF8.self).contains("wristContact"))
    #expect(try JSONDecoder().decode(BodySnapshot.self,from:encoded) == old)
  }
  @Test func lowRightWristDoesNotRemoveEligibleLeftInPublicAttachment() throws {
    let (f,b,a) = try WristEvidenceTests().fixture();var body = b
    var values = LiveVisionFixtures.standingPair;let p = values[0];var joints = p.joints
    joints[.rightWrist] = .init(x:0.5,y:0.4,confidence:0.49)
    values[0] = .init(candidateID:p.candidateID,joints:joints,maskTopImageY:nil,maskBottomImageY:nil,
      leftFootBottomImageY:nil,rightFootBottomImageY:nil,maskAssociation:.unavailable)
    let pose = try f.result(3,0.25,values)
    body.publish(pose,association:LiveVisionFixtures.association(pose,revision:a.revision),admission:a,
      acknowledgment:f.gate.snapshot.acknowledgment)
    let v = try #require(body.latest?.wristContact?.players[.player1])
    #expect(v.left.playerPlane != nil && v.right.playerPlane == nil && v.right.contactRefusal == .lowConfidence)
  }
  @Test func actualGateSingleStreamYieldsAttachedSnapshotThenRevokesContext() async throws {
    var f = try TrackingIntegrationFixture();try f.bind()
    try f.gate.configureBody(LiveVisionFixtures.configuration(f.context.generation))
    let stream = try f.gate.bodyStream(generation:f.context.generation)
    let p = try f.result(3,0.25,LiveVisionFixtures.standingPair)
    let a = try #require(f.gate.admit(p.source));try #require(try f.finish(p,stamp:a))
    let receipt = try #require(f.gate.snapshot.latest)
    f.gate.publishBody(p,admission:a,receipt:receipt)
    var iterator = stream.makeAsyncIterator()
    let s = try #require(await iterator.next())
    #expect(s == f.gate.readBody().latest && s.wristContact != nil)
    #expect(s.wristContact?.players[.player1]?.left.contactRefusal == .notCalibrated)
    let oldContext = try #require(f.gate.readBody().context)
    #expect(oldContext.wristContact?.controlRevision == a.revision)
    f.gate.sourceLost(f.context)
    #expect(f.gate.readBody().latest == nil && f.gate.readBody().context?.wristContact == nil)
    f.gate.resume(f.context)
    #expect(f.gate.readBody().context?.wristContact == nil)
  }
  @Test(arguments:[false,true]) func calibrationRefusalSurvivesAtomicAttachment(_ incompatible:Bool) throws {
    let (f,b,a) = try WristEvidenceTests().fixture();var body = b
    if incompatible {
      let originals = try LH00TestData.load().configuration.calibrations
      body.configuration = body.configuration?.replacingCalibrations(originals.mapValues {
        LH00TestData.calibration($0,revision:1,generation:f.context.generation)
      })
    } else { body.cutovers[.player1] = .init(frameID:3,capturedAt:0.25) }
    let pose = try f.result(3,0.25,LiveVisionFixtures.standingPair)
    body.publish(pose,association:LiveVisionFixtures.association(pose,revision:a.revision),admission:a,
      acknowledgment:f.gate.snapshot.acknowledgment)
    let snapshot = try #require(body.latest);try snapshot.validate()
    let p = try #require(snapshot.wristContact?.players[.player1])
    #expect(p.left.observed != nil && p.left.playerPlane == nil)
    #expect(p.left.contactRefusal == (incompatible ? .incompatibleCalibration : .beforeCutover))
  }

}
