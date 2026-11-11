import Foundation
import Testing
@testable import Sedactive

nonisolated struct WristEvidenceTests {
  func fixture() throws -> (TrackingIntegrationFixture, LiveBodyInputState, CameraTrackingAdmission) {
    var f = try TrackingIntegrationFixture();try f.bind()
    var body = LiveBodyInputState()
    let config = LiveVisionFixtures.configuration(f.context.generation)
    try body.configure(config,source:f.context)
    let originals = try LH00TestData.load().configuration.calibrations
    body.configuration = config.replacingCalibrations(try originals.mapValues {
      let value = LH00TestData.calibration($0,revision:1,generation:f.context.generation)
      var json = try #require(JSONSerialization.jsonObject(with:JSONEncoder().encode(value)) as? [String:Any])
      var mapping = try #require(json["mapping"] as? [String:Any])
      mapping["imageAspectRatio"] = 1280.0/720.0;json["mapping"] = mapping
      return try JSONDecoder().decode(PlayerCalibration.self,from:JSONSerialization.data(withJSONObject:json))
    }) // synthetic accepted context only; production accept path is never bypassed
    for id in PlayerID.allCases { body.cutovers[id] = .init(frameID:2,capturedAt:0.125) }
    body.acceptedRevision = 1
    let stamp = CameraTrackingAdmission(context:f.context,revision:f.gate.snapshot.revision,
      requestID:f.gate.snapshot.requestID,acceptedBodyRevision:1)
    return (f,body,stamp)
  }
  private func prepare(_ f:TrackingIntegrationFixture,_ body:LiveBodyInputState,_ a:CameraTrackingAdmission,
    candidates:[PoseCandidate] = LiveVisionFixtures.standingPair) throws -> PreparedWristFrame? {
    let p = try f.result(3,0.25,candidates)
    return WristEvidencePreparation.prepare(p,association:LiveVisionFixtures.association(p,revision:a.revision),
      admission:a,acknowledgment:f.gate.snapshot.acknowledgment,body:body)
  }
  @Test func independentWristsPreserveOriginalAndUseExistingMapping() throws {
    let (f,body,a) = try fixture()
    let result = try #require(try prepare(f,body,a))
    #expect(result.source.frameID == 3 && result.source.capturedAt == 0.25)
    #expect(result.source.context == f.context && result.controlRevision == a.revision)
    #expect(result.bindingRequest == a.requestID && result.bindingSource.frameID == 2)
    for id in PlayerID.allCases {
      let wrist = try #require(result.players[id]?.left)
      let joint = try #require(wrist.observed), cal = try #require(body.configuration?.calibrations[id])
      let layout = try #require(body.configuration?.playerPlaneLayout)
      #expect(wrist.playerPlane?.x == cal.mapping.gameX(imageX:joint.x,playerID:id,layout:layout))
      #expect(wrist.playerPlane?.y == cal.mapping.gameY(imageY:joint.y,layout:layout))
      #expect(wrist.contactRefusal == nil)
      #expect(result.players[id]?.calibrationRevision == 1)
    }
    #expect(result.players[.player1]?.left.observed != result.players[.player2]?.left.observed)
  }
  @Test(arguments:["missing","weak","invalid"])
  func rightRefusalDoesNotRemoveLeft(_ reason:String) throws {
    let (f,body,a) = try fixture()
    var values = LiveVisionFixtures.standingPair
    let c = values[0];var joints = c.joints
    joints[.rightWrist] = reason == "missing" ? nil : .init(x:reason == "invalid" ? 2 : 0.5,y:0.4,confidence:reason == "weak" ? 0.49 : 0.9)
    values[0] = .init(candidateID:c.candidateID,joints:joints,maskTopImageY:nil,maskBottomImageY:nil,
      leftFootBottomImageY:nil,rightFootBottomImageY:nil,maskAssociation:.unavailable)
    let out = try #require(try prepare(f,body,a,candidates:values))
    let p = try #require(out.players[.player1])
    #expect(p.left.playerPlane != nil && p.right.playerPlane == nil)
    #expect(p.right.contactRefusal == (reason == "missing" ? .missingJoint : reason == "weak" ? .lowConfidence : .invalidCoordinate))
    #expect(out.players[.player2]?.right.playerPlane != nil)
  }
  @Test func missingCalibrationRetainsOnlyObservedPoint() throws {
    let (f,b,a) = try fixture();var body = b
    body.configuration = body.configuration?.replacingCalibrations([:])
    let out = try #require(try prepare(f,body,a))
    #expect(out.players[.player1]?.left.observed != nil)
    #expect(out.players[.player1]?.left.playerPlane == nil)
    #expect(out.players[.player1]?.left.contactRefusal == .notCalibrated)
  }
  @Test func cutoverAndContextReplacementCannotRestampOldObservations() throws {
    let (f,b,a) = try fixture();var body = b
    body.cutovers[.player1] = .init(frameID:3,capturedAt:0.25)
    #expect(try prepare(f,body,a)?.players[.player1]?.left.contactRefusal == .beforeCutover)
    #expect(try prepare(f,body,a)?.players[.player2]?.left.playerPlane != nil)
    body.acceptedRevision += 1
    #expect(try prepare(f,body,a) == nil)
  }
  @Test func sourceAndBindingMismatchRefusePreparation() throws {
    let (f,b,a) = try fixture();var body = b
    body.source = CameraTestFrames.context()
    #expect(try prepare(f,body,a) == nil)
    var stamp = a;stamp = .init(context:a.context,revision:a.revision+1,requestID:a.requestID,acceptedBodyRevision:1)
    #expect(try prepare(f,b,stamp) == nil)
    let pose = try f.result(3,0.25,LiveVisionFixtures.standingPair)
    #expect(WristEvidencePreparation.prepare(pose,association:LiveVisionFixtures.association(pose,revision:a.revision),
      admission:a,acknowledgment:nil,body:b) == nil)
  }
  @Test(arguments:[0,1,2]) func uncertainLostOrRebindCannotExposeHandsAndDuplicateAssociationRefuses(_ mode:Int) throws {
    let (f,b,a) = try fixture();let p = try f.result(3,0.25,LiveVisionFixtures.standingPair)
    let original = LiveVisionFixtures.association(p,revision:a.revision)
    func association(_ slot:PlayerTrackingSlotResult) -> PlayerTrackingSnapshot {
      .init(source:original.source,evaluatedAt:0.25,controlRevision:a.revision,player1:slot,
        player2:original.player2,assignmentCount:2,confirmedDescriptorCount:4,provisionalDescriptorCount:0)
    }
    let uncertain = PlayerTrackingSlotResult(state:mode == 1 ? .lost : mode == 2 ? .tracking : .uncertain,reason:.recovering,candidateID:10,
      cost:0,requiresRebind:mode == 2,lastConfirmedAt:0.125)
    let out = try #require(WristEvidencePreparation.prepare(p,association:association(uncertain),admission:a,
      acknowledgment:f.gate.snapshot.acknowledgment,body:b))
    #expect(out.players[.player1]?.left.observed == nil)
    #expect(out.players[.player2]?.left.playerPlane != nil)
    #expect(WristEvidencePreparation.prepare(p,association:association(original.player2),admission:a,
      acknowledgment:f.gate.snapshot.acknowledgment,body:b) == nil)
  }
  @Test func realGatePublishesAtomicallyThenRejectsStaleDuplicateAndRevokedResults() throws {
    var f = try TrackingIntegrationFixture();try f.bind()
    try f.gate.configureBody(LiveVisionFixtures.configuration(f.context.generation))
    let p = try f.result(3,0.25,LiveVisionFixtures.standingPair)
    let a = try #require(f.gate.admit(p.source));try #require(try f.finish(p,stamp:a))
    let receipt = try #require(f.gate.snapshot.latest)
    f.gate.publishBody(p,admission:a,receipt:receipt)
    let read = f.gate.readBody()
    #expect(read.wrists?.source.frameID == read.latest?.frameID)
    #expect(read.wrists?.players[.player1]?.left.contactRefusal == .notCalibrated)
    let old = try f.result(2,0.125,LiveVisionFixtures.standingPair)
    f.gate.publishBody(old,admission:a,receipt:receipt)
    #expect(f.gate.readBody().wrists?.source.frameID == 3)
    f.clock.time = 0.75
    #expect(f.gate.readBody().wrists == nil && f.gate.readBody().latest == nil)
    f.gate.publishBody(p,admission:a,receipt:receipt)
    #expect(f.gate.readBody().wrists == nil)
    f.gate.sourceLost(f.context);f.gate.publishBody(p,admission:a,receipt:receipt)
    #expect(f.gate.readBody().wrists == nil)
  }
  @Test func legacyReplayRemainsWithoutAnyWristAttachment() throws {
    let data = try LH00TestData.load()
    #expect(data.configuration.calibrations.count == 2)
    // Public BodySnapshot and its Codable representation were deliberately not extended.
    let snapshot = try #require(data.records.first?.snapshot)
    try snapshot.validate()
    let bytes = try JSONEncoder().encode(snapshot)
    #expect(try JSONDecoder().decode(BodySnapshot.self,from:bytes) == snapshot)
    #expect(!String(decoding:bytes,as:UTF8.self).contains("wrists"))
  }
  @Test func incompatibleAcceptedGeometryRefusesOnlyContactCoordinates() throws {
    let (f,b,a) = try fixture();var body = b
    let originals = try LH00TestData.load().configuration.calibrations
    body.configuration = body.configuration?.replacingCalibrations(originals.mapValues {
      LH00TestData.calibration($0,revision:1,generation:f.context.generation)
    })
    let out = try #require(try prepare(f,body,a))
    #expect(out.players[.player1]?.left.observed != nil)
    #expect(out.players[.player1]?.left.contactRefusal == .incompatibleCalibration)
  }

  @MainActor @Test func actualProviderStopRetryCannotRetainWristFrame() async throws {
    let camera = CameraPipeline(permission:ControlledCameraPermission(.authorized),driver:ControlledCameraDriver())
    let provider = BodyInputService(camera:camera)
    try await provider.start(configuration:LiveVisionFixtures.configuration(UUID()))
    let source = try #require(camera.state.context)
    let request = try provider.makeBindingRequest();try provider.armBinding(request)
    let f = try TrackingIntegrationFixture();var engine = try MotionEngine(policy:B2bExperimentalPolicyV1.value)
    var last:(CameraPoseResult,CameraTrackingAdmission,PlayerTrackingSnapshot)?
    let base = CameraHostClock.now()-0.25
    for i in 1...2 {
      let pose = try f.result(UInt64(i),base+Double(i-1)*0.125,LiveVisionFixtures.standingPair,context:source)
      let a = try #require(camera.frames.tracking.admit(pose.source))
      let staged = try engine.staged(pose,admission:a)
      try #require(camera.frames.tracking.finish(staged,admission:a,source:pose.source,mutualCoreCount:4) { engine = staged })
      let receipt = try #require(camera.frames.tracking.snapshot.latest)
      camera.frames.tracking.publishBody(pose,admission:a,receipt:receipt);last = (pose,a,receipt)
    }
    #expect(camera.frames.tracking.readBody().wrists != nil)
    #expect(provider.latestSnapshot?.wristContact != nil)
    await provider.stop()
    #expect(camera.frames.tracking.readBody().wrists == nil)
    #expect(provider.currentContext?.wristContact == nil)
    try await provider.start(configuration:LiveVisionFixtures.configuration(UUID()))
    let old = try #require(last)
    camera.frames.tracking.publishBody(old.0,admission:old.1,receipt:old.2)
    #expect(camera.frames.tracking.readBody().wrists == nil)
    #expect(provider.currentContext?.wristContact == nil)
    #expect(camera.state.context?.generation != source.generation)
    #expect(camera.frames.tracking.snapshot.acknowledgment == nil)
    await provider.stop()
  }

}
