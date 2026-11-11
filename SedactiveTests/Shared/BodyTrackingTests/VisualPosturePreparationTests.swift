#if DEBUG
import Foundation
import Testing
@testable import Sedactive

nonisolated struct VisualPosturePreparationTests {
  private func pair(hip: Double = 0.45, shoulder: Double = 0.7) -> [PoseCandidate] {
    [(UInt64(10), 0.75), (UInt64(20), 0.25)].map { id, x in
      var joints: [BodyJoint: PoseJoint] = [:]
      for (name, px, py) in [(BodyJoint.leftShoulder,x-0.04,shoulder),(.rightShoulder,x+0.04,shoulder),
        (.leftHip,x-0.03,hip),(.rightHip,x+0.03,hip),(.leftAnkle,x-0.04,0.1),(.rightAnkle,x+0.04,0.1)] {
        joints[name] = .init(x:px,y:py,confidence:0.9)
      }
      return .init(candidateID:id,joints:joints,maskTopImageY:nil,maskBottomImageY:nil,
        leftFootBottomImageY:nil,rightFootBottomImageY:nil,maskAssociation:.unavailable)
    }
  }
  private func replace(_ candidate: PoseCandidate, joint: BodyJoint, point: PoseJoint?) -> PoseCandidate {
    var joints = candidate.joints; joints[joint] = point
    return .init(candidateID:candidate.candidateID,joints:joints,maskTopImageY:nil,
      maskBottomImageY:nil,leftFootBottomImageY:nil,rightFootBottomImageY:nil,maskAssociation:.unavailable)
  }
  private func delivery(_ candidates: [PoseCandidate], state: PlayerTrackingState = .tracking,
    rebind: Bool = false, duplicate: Bool = false, frame: UInt64 = 3, time: Double = 0.25,
    context: CameraSourceContext? = nil) throws -> VisionNumericPoseDrain {
    let f = try TrackingIntegrationFixture(), pose = try f.result(frame,time,candidates,context:context)
    let original = LiveVisionFixtures.association(pose,revision:2)
    let p1 = PlayerTrackingSlotResult(state:state,reason:.recovering,candidateID:duplicate ? 20 : 10,
      cost:0,requiresRebind:rebind,lastConfirmedAt:time)
    let tracking = PlayerTrackingSnapshot(source:original.source,evaluatedAt:time,controlRevision:2,
      player1:p1,player2:original.player2,assignmentCount:2,confirmedDescriptorCount:4,provisionalDescriptorCount:0)
    let status = VisionNumericPoseStatus(revision:5,active:true,context:tracking.source?.context,
      controlRevision:2,acceptedContextRevision:0,layout:nil,calibrationRevisions:[:],cutovers:[:])
    return .init(status:status,resetAll:false,output:.init(presentationRevision:5,tracking:tracking,
      pose:pose.frame,acceptedCalibrations:[:],cutovers:[:],layout:nil))
  }
  private func prepared(_ d: VisionNumericPoseDrain, now: Double = 0.26) -> ExperimentalVisualPostureFrame? {
    VisualPosturePreparation.prepare(d,at:now,maximumAge:0.25).frame
  }
  @Test func bilateralCompressionIsExperimentalAndIndependentAcrossPlayers() throws {
    let standing = try delivery(pair()), first = try #require(prepared(standing))
    var compressed = pair();compressed[0] = pair(hip:0.35,shoulder:0.6)[0]
    let compressedDelivery = try delivery(compressed)
    let current = try #require(prepared(compressedDelivery))
    #expect(abs(try #require(first.player1.bilateralExtentOverTorso.value)-1.4)<1e-12)
    #expect(abs(try #require(current.player1.bilateralExtentOverTorso.value)-1.0)<1e-12)
    #expect(current.player2.bilateralExtentOverTorso == first.player2.bilateralExtentOverTorso)
    #expect(current.player1.bilateralExtentOverTorso.confidence == 0.9)
    #expect(first.source == standing.output?.tracking.source)
    #expect(current.source == compressedDelivery.output?.tracking.source && current.presentationRevision == 5)
    #expect(current.player1.candidateID == 10 && current.player2.candidateID == 20)
    #expect(current.player1.trackingState == .tracking && !current.player1.requiresRebind)
  }
  @Test func imageTranslationAndUniformScaleDoNotInventCompression() throws {
    let original = try #require(prepared(delivery(pair())))
    for (scale, offset): (Double,Double) in [(1,-0.05),(0.8,0.1)] {
      let transformed = pair().map { c in
        PoseCandidate(candidateID:c.candidateID,joints:c.joints.mapValues {
          .init(x:$0.x*scale+offset,y:$0.y*scale+offset,confidence:$0.confidence)
        },maskTopImageY:nil,maskBottomImageY:nil,leftFootBottomImageY:nil,rightFootBottomImageY:nil,maskAssociation:.unavailable)
      }
      let now = try #require(prepared(delivery(transformed)))
      #expect(abs(try #require(now.player1.bilateralExtentOverTorso.value)
        - (try #require(original.player1.bilateralExtentOverTorso.value)))<1e-12)
    }
  }
  @Test func singleAnkleRaiseDoesNotImplyBilateralCompressionAndMissingStaysMissing() throws {
    var p = pair();p[0] = replace(p[0],joint:.leftAnkle,point:.init(x:0.71,y:0.2,confidence:0.9))
    let raised = try #require(prepared(delivery(p)))
    #expect(raised.player1.leftLegExtentOverTorso.value! < raised.player1.rightLegExtentOverTorso.value!)
    #expect(raised.player1.bilateralExtentOverTorso.value == raised.player1.rightLegExtentOverTorso.value)
    p[0] = replace(p[0],joint:.leftAnkle,point:nil)
    let missing = try #require(prepared(delivery(p)))
    #expect(missing.player1.bilateralExtentOverTorso.refusal == .missingJoint)
    #expect(missing.player1.leftLegExtentOverTorso.value == nil && missing.player1.rightLegExtentOverTorso.value != nil)
    #expect(missing.player1.torsoLeanRadians.value != nil && missing.player2.bilateralExtentOverTorso.value != nil)
  }
  @Test(arguments:["missing","weak","degenerate","crossed"])
  func unsupportedGeometryRefusesWithoutRemovingPeer(_ kind:String) throws {
    var p = pair()
    if kind == "missing" { p[0] = replace(p[0],joint:.leftHip,point:nil) }
    if kind == "weak" { p[0] = replace(p[0],joint:.leftHip,point:.init(x:0.72,y:0.45,confidence:0.49)) }
    if kind == "degenerate" {
      for name in [BodyJoint.leftShoulder,.rightShoulder] {
        p[0] = replace(p[0],joint:name,point:.init(x:0.75,y:0.45,confidence:0.9))
      }
    }
    if kind == "crossed" { p[0] = replace(p[0],joint:.leftAnkle,point:.init(x:0.81,y:0.1,confidence:0.9)) }
    let frame = try #require(prepared(delivery(p)))
    #expect(frame.player1.bilateralExtentOverTorso.value == nil)
    #expect(frame.player1.bilateralExtentOverTorso.refusal == (kind == "missing" ? .missingJoint
      : kind == "weak" ? .lowConfidence : kind == "degenerate" ? .degenerateTorso : .unresolvedLegProjection))
    #expect(frame.player2.bilateralExtentOverTorso.value != nil)
  }
  @Test func leanUsesImageAspectAndCandidateOrderNeverAssignsIdentity() throws {
    var p = pair()
    p[0] = replace(p[0],joint:.leftShoulder,point:.init(x:0.76,y:0.7,confidence:0.9))
    p[0] = replace(p[0],joint:.rightShoulder,point:.init(x:0.84,y:0.7,confidence:0.9))
    let d = try delivery(p), result = try #require(prepared(d)), aspect = 1280.0/720.0
    #expect(abs(result.player1.torsoLeanRadians.value! - atan2(0.05*aspect,0.25))<1e-12)
    let reordered = try delivery(p.reversed(),context:d.output?.tracking.source.map {
      CameraSourceContext(generation:$0.context.generation,epoch:$0.context.epoch,geometryRevision:$0.context.geometryRevision)
    })
    #expect(prepared(reordered)?.player1 == result.player1)
    #expect(result.player2.torsoLeanRadians.value == 0)
  }
  @Test(arguments:[PlayerTrackingState.unbound,.uncertain,.lost])
  func unreliableAssociationNeverLeaksLastPose(_ state:PlayerTrackingState) throws {
    let f = try #require(prepared(delivery(pair(),state:state)))
    #expect(f.player1.torsoLeanRadians.value == nil && f.player1.bilateralExtentOverTorso.value == nil)
    #expect(f.player1.candidateID == nil && f.player2.torsoLeanRadians.value != nil)
  }
  @Test func rebindAndSharedCandidateRefuse() throws {
    #expect(try prepared(delivery(pair(),rebind:true))?.player1.torsoLeanRadians.refusal == .rebindRequired)
    #expect(try prepared(delivery(pair(),duplicate:true)) == nil)
  }
  @Test(arguments:[0.249999,0.25,0.250001])
  func strictPresentationAgeIncludingNoNewCameraFrame(_ age:Double) throws {
    let d = try delivery(pair()), output = try #require(prepared(d))
    let empty = VisionNumericPoseDrain(status:d.status,resetAll:false,output:nil)
    let batch = VisualPosturePreparation.prepare(empty,at:0.25+age,maximumAge:0.25)
    #expect(batch.frame == nil)
    #expect((batch.resolve(held:output,at:0.25+age,maximumAge:0.25) != nil) == (age<0.25))
    #expect((VisualPosturePreparation.prepare(d,at:0.25+age,maximumAge:0.25).frame != nil) == (age<0.25))
  }
  @Test func invalidSourceControlOrderAndPacketFailClosed() throws {
    let d = try delivery(pair()), old = try #require(prepared(d))
    let status = VisionNumericPoseStatus(revision:6,active:true,context:d.status.context,
      controlRevision:3,acceptedContextRevision:0,layout:nil,calibrationRevisions:[:],cutovers:[:])
    let changed = VisualPosturePreparation.prepare(.init(status:status,resetAll:false,output:d.output),at:0.26,maximumAge:0.25)
    #expect(changed.refusal == .invalidPacket && changed.resolve(held:old,at:0.26,maximumAge:0.25)==nil)
    let reset = VisualPosturePreparation.prepare(.init(status:d.status,resetAll:true,output:nil),at:0.26,maximumAge:0.25)
    #expect(reset.resolve(held:old,at:0.26,maximumAge:0.25)==nil)
    #expect(VisualPosturePreparation.prepare(d,at:.nan,maximumAge:0.25).refusal == .invalidTiming)
    #expect(VisualPosturePreparation.prepare(d,at:0.26,maximumAge:0.500001).refusal == .invalidTiming)
    let duplicate = VisualPosturePreparation.prepare(d,at:0.26,maximumAge:0.25)
    #expect(duplicate.resolve(held:old,at:0.26,maximumAge:0.25)==nil)
    var invalid = pair();invalid[0] = replace(invalid[0],joint:.leftHip,point:.init(x:2,y:0.4,confidence:0.9))
    #expect(try prepared(delivery(invalid)) == nil)
  }
  @Test func actualGateDrainResetsOnCancelSourceLossAndRetiredAttachment() throws {
    var f = try TrackingIntegrationFixture();try f.bind()
    let bridge = VisionNumericPoseBridge(gate:f.gate), lease = try bridge.attach()
    let pose = try f.result(3,0.25,LiveVisionFixtures.standingPair)
    let stamp = try #require(f.gate.admit(pose.source));try #require(try f.finish(pose,stamp:stamp))
    f.gate.publishPresentation(pose,admission:stamp,receipt:try #require(f.gate.snapshot.latest))
    let value = VisualPosturePreparation.prepare(bridge.drain(lease),at:0.25,maximumAge:0.25)
    let held = try #require(value.frame)
    #expect(held.source.frameID == 3 && held.source.context.generation == f.context.generation)
    f.gate.revoke()
    #expect(VisualPosturePreparation.prepare(bridge.drain(lease),at:0.26,maximumAge:0.25)
      .resolve(held:held,at:0.26,maximumAge:0.25)==nil)
    f.gate.sourceLost(f.context);f.gate.resume(f.context)
    #expect(VisualPosturePreparation.prepare(bridge.drain(lease),at:0.26,maximumAge:0.25).frame==nil)
    #expect(f.gate.snapshot.requestID == nil && f.gate.snapshot.acknowledgment == nil)
    bridge.cancel(lease)
    #expect(VisualPosturePreparation.prepare(bridge.drain(lease),at:0.26,maximumAge:0.25).refusal == .inactive)
  }
  @MainActor @Test func actualProviderStopRetryRejectsOldPostureWithoutCalibration() async throws {
    let driver = ControlledCameraDriver()
    let camera = CameraPipeline(permission:ControlledCameraPermission(.authorized),driver:driver)
    let provider = BodyInputService(camera:camera)
    try await provider.start(configuration:LiveVisionFixtures.configuration(UUID()))
    let source = try #require(camera.state.context), gate = camera.frames.tracking
    let bridge = VisionNumericPoseBridge(gate:gate), lease = try bridge.attach()
    try provider.armBinding(provider.makeBindingRequest())
    let f = try TrackingIntegrationFixture();var engine = try MotionEngine(policy:B2bExperimentalPolicyV1.value)
    let base = CameraHostClock.now()-0.2
    for i in 1...2 {
      let pose = try f.result(UInt64(i),base+Double(i-1)*0.125,LiveVisionFixtures.standingPair,context:source)
      let stamp = try #require(gate.admit(pose.source)), staged = try engine.staged(pose,admission:stamp)
      try #require(gate.finish(staged,admission:stamp,source:pose.source,mutualCoreCount:4) { engine = staged })
      gate.publishPresentation(pose,admission:stamp,receipt:try #require(gate.snapshot.latest))
    }
    let held = try #require(VisualPosturePreparation.prepare(bridge.drain(lease),at:CameraHostClock.now(),maximumAge:0.25).frame)
    #expect(provider.currentContext?.calibrationRevisions.isEmpty == true)
    await provider.stop()
    #expect(VisualPosturePreparation.prepare(bridge.drain(lease),at:CameraHostClock.now(),maximumAge:0.25).frame==nil)
    #expect(camera.frames.usage.frames==0)
    try await provider.start(configuration:LiveVisionFixtures.configuration(UUID()))
    let fresh = try bridge.attach(), d = bridge.drain(fresh)
    #expect(VisualPosturePreparation.prepare(d,at:CameraHostClock.now(),maximumAge:0.25)
      .resolve(held:held,at:CameraHostClock.now(),maximumAge:0.25)==nil)
    #expect(camera.state.context?.generation != held.source.context.generation)
    #expect(gate.snapshot.acknowledgment == nil && provider.currentContext?.calibrationRevisions.isEmpty == true)
    await provider.stop();bridge.cancel(fresh)
  }
}

#endif
