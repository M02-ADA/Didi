import Foundation
import Testing
@testable import Sedactive

nonisolated struct ExperimentalVisualNeutralReferenceTests {
  // Fixture-only settings, NOT recommended live/production thresholds.
  private let policy = VisualNeutralReferencePolicy(sampleCount: 3, minimumSpan: 0.125,
    collectionTimeout: 1, maximumGap: 0.25, referenceLifetime: 2,
    relativeTolerance: 0.08, centerTolerance: 0.04, angleTolerance: 0.1, asymmetryTolerance: 0.1)

  private func status(_ context: PlayerTrackingContext, revision: UInt64 = 5, control: UInt64 = 2,
    accepted: UInt64 = 0, active: Bool = true) -> VisionNumericPoseStatus {
    .init(revision: revision, active: active, context: context, controlRevision: control,
      acceptedContextRevision: accepted, layout: nil, calibrationRevisions: [:], cutovers: [:])
  }
  private func batch(frame: UInt64, time: Double, context: CameraSourceContext,
    scale: Double = 1, offset: Double = 0, compress: Bool = false, ankleY: Double = 0.1, bad: String? = nil,
    player: PlayerID = .player1) throws -> ExperimentalVisualPostureBatch {
    let candidates: [PoseCandidate] = [(UInt64(10),0.75),(UInt64(20),0.25)].map { id,x in
      var joints: [BodyJoint: PoseJoint] = [:]
      let affected = (player == .player1 ? id == 10 : id == 20)
      let shift = compress && affected ? -0.025 : 0.0
      for (name,px,py) in [(BodyJoint.leftShoulder,x-0.04,0.7+shift),(.rightShoulder,x+0.04,0.7+shift),
        (.leftHip,x-0.03,0.45+shift),(.rightHip,x+0.03,0.45+shift),
        (.leftAnkle,x-0.04,affected ? ankleY : 0.1),(.rightAnkle,x+0.04,affected ? ankleY : 0.1)] {
        let s = affected ? scale : 1, o = affected ? offset : 0
        joints[name] = .init(x:px*s+o,y:py*s+o,confidence:bad == "weak" && affected && name == .leftHip ? 0.49 : 0.9)
      }
      if affected && bad == "missing" { joints[.leftAnkle] = nil }
      if affected && bad == "crossed" { joints[.leftAnkle] = .init(x:x+0.06,y:0.1,confidence:0.9) }
      return .init(candidateID:id,joints:joints,maskTopImageY:nil,maskBottomImageY:nil,
        leftFootBottomImageY:nil,rightFootBottomImageY:nil,maskAssociation:.unavailable)
    }
    let fixture = try TrackingIntegrationFixture(), pose = try fixture.result(frame,time,candidates,context:context)
    let original = LiveVisionFixtures.association(pose,revision:2)
    let p1 = PlayerTrackingSlotResult(state:bad == "lost" ? .lost : .tracking,reason:.matched,candidateID:10,
      cost:0,requiresRebind:bad == "rebind",lastConfirmedAt:time)
    let tracking = PlayerTrackingSnapshot(source:original.source,evaluatedAt:time,controlRevision:2,
      player1:p1,player2:original.player2,assignmentCount:2,confirmedDescriptorCount:4,provisionalDescriptorCount:0)
    let d = VisionNumericPoseDrain(status:status(original.source!.context),resetAll:false,
      output:.init(presentationRevision:5,tracking:tracking,pose:pose.frame,acceptedCalibrations:[:],cutovers:[:],layout:nil))
    return VisualPosturePreparation.prepare(d,at:time,maximumAge:0.25)
  }
  private func ready() throws -> (ExperimentalVisualNeutralReference, CameraSourceContext, ExperimentalVisualPostureBatch) {
    var state = try ExperimentalVisualNeutralReference(policy:policy)
    let c = try TrackingIntegrationFixture().context
    let first = try batch(frame:1,time:1.0625,context:c)
    for id in PlayerID.allCases {
      #expect(state.begin(for:id,userIdentifiedUprightNeutral:true,status:first.status,at:1) == nil)
    }
    var last = first
    for i in 1...3 {
      last = try batch(frame:UInt64(i),time:1+Double(i)*0.0625,context:c)
      _ = state.update(last,at:1+Double(i)*0.0625,maximumAge:0.25)
    }
    return (state,c,last)
  }
  private func empty(_ b: ExperimentalVisualPostureBatch) -> ExperimentalVisualPostureBatch {
    .init(status:b.status,resetAll:false,frame:nil,refusal:nil)
  }
  @Test func stableMedianReferenceAndIndependentExperimentalComparison() throws {
    var (state,c,last) = try ready()
    let candidates = state.update(empty(last),at:1.2,maximumAge:0.25)
    let ref = try #require(candidates[.player1]?.candidate)
    #expect(ref.sampleCount == 3 && ref.firstSource.frameID == 1 && ref.lastSource.frameID == 3)
    #expect(ref.firstCandidateID == 10 && ref.lastCandidateID == 10)
    #expect(ref.playerID == .player1 && ref.requestedAt == 1 && ref.presentationRevision == 5)
    #expect(ref.lastSource.context.generation == c.generation && ref.lastSource.controlRevision == 2)
    #expect(abs(ref.values.bilateral - 1.4) < 1e-12)
    last = try batch(frame:4,time:1.25,context:c,compress:true)
    let result = state.update(last,at:1.25,maximumAge:0.25)
    let p1 = try #require(result[.player1]?.comparison), p2 = try #require(result[.player2]?.comparison)
    #expect(p1.bilateralExtentRatioToNeutral < 1 && abs(p2.bilateralExtentRatioToNeutral - 1) < 1e-12)
    #expect(p1.physicalInterpretationIsAmbiguous && p1.confidence == 0.9)
    #expect(p1.source == last.frame?.source && p1.candidateID == 10 && p2.candidateID == 20)
    #expect(p1.referenceRequestID == ref.requestID)
    // No new sample on a render tick: bounded latest comparison, original timestamp retained.
    let tick = state.update(empty(last),at:1.3,maximumAge:0.25)
    #expect(tick[.player1]?.comparison?.source == p1.source)
  }
  @Test func uprightIntentAndPostRequestSamplesAreMandatory() throws {
    var state = try ExperimentalVisualNeutralReference(policy:policy)
    let c = try TrackingIntegrationFixture().context, b = try batch(frame:1,time:1,context:c)
    #expect(state.begin(for:.player1,userIdentifiedUprightNeutral:false,status:b.status,at:1) == .uprightIntentRequired)
    #expect(state.update(b,at:1,maximumAge:0.25)[.player1]?.candidate == nil)
    state.begin(for:.player1,userIdentifiedUprightNeutral:true,status:b.status,at:1)
    #expect(state.update(b,at:1,maximumAge:0.25)[.player1]?.refusal == .preRequest)
  }
  @Test func unstableCollectionTerminatesWithoutAutomaticRetry() throws {
    var state = try ExperimentalVisualNeutralReference(policy:policy)
    let c = try TrackingIntegrationFixture().context, first = try batch(frame:1,time:1.0625,context:c)
    state.begin(for:.player1,userIdentifiedUprightNeutral:true,status:first.status,at:1)
    _ = state.update(first,at:1.0625,maximumAge:0.25)
    _ = state.update(try batch(frame:2,time:1.125,context:c,offset:0.15),at:1.125,maximumAge:0.25)
    let result = state.update(try batch(frame:3,time:1.1875,context:c),at:1.1875,maximumAge:0.25)
    #expect(result[.player1]?.refusal == .unstable && result[.player1]?.sampleCount == 0)
    #expect(state.update(try batch(frame:4,time:1.25,context:c),at:1.25,maximumAge:0.25)[.player1]?.phase == .unavailable)
  }
  @Test(arguments:["missing","weak","crossed","lost","rebind"])
  func invalidPlayerClearsOnlyItsOwnReference(_ bad:String) throws {
    var (state,c,_) = try ready()
    let r = state.update(try batch(frame:4,time:1.25,context:c,bad:bad),at:1.25,maximumAge:0.25)
    #expect(r[.player1]?.candidate == nil && r[.player1]?.comparison == nil)
    #expect(r[.player1]?.refusal == (bad == "lost" || bad == "rebind" ? .unreliableTracking : .unsupportedFeatures))
    #expect(r[.player2]?.phase == .ready)
  }
  @Test(arguments:["generation","epoch","geometry","control","presentation","accepted"])
  func fenceChangesInvalidateBothPlayersEvenWithoutAFrame(_ kind:String) throws {
    var (state,_,last) = try ready()
    let old = try #require(last.status), c = try #require(old.context)
    let changed = PlayerTrackingContext(generation:kind == "generation" ? UUID() : c.generation,
      epoch:kind == "epoch" ? UUID() : c.epoch,geometryRevision:c.geometryRevision+(kind == "geometry" ? 1 : 0),
      imageWidth:c.imageWidth,imageHeight:c.imageHeight,rotationAngle:c.rotationAngle,mirrored:c.mirrored)
    let s = status(changed,revision:kind == "presentation" ? 6 : 5,control:kind == "control" ? 3 : 2,
      accepted:kind == "accepted" ? 1 : 0)
    let r = state.update(.init(status:s,resetAll:false,frame:nil,refusal:nil),at:1.2,maximumAge:0.25)
    #expect(r.values.allSatisfy { $0.refusal == .contextChanged && $0.candidate == nil })
  }
  @Test(arguments:["inactive","reset","explicit"])
  func stopRetryCannotRevivePreviousReferences(_ event:String) throws {
    var (state,_,last) = try ready()
    if event == "explicit" { state.invalidate() }
    let stop = ExperimentalVisualPostureBatch(status:event == "inactive" ? nil : last.status,
      resetAll:event == "reset",frame:nil,refusal:nil)
    let r = state.update(stop,at:1.2,maximumAge:0.25)
    #expect(r.values.allSatisfy { $0.candidate == nil && $0.comparison == nil })
    let fresh = try batch(frame:1,time:1.25,context:TrackingIntegrationFixture().context)
    #expect(state.update(fresh,at:1.25,maximumAge:0.25).values.allSatisfy { $0.phase == .unavailable })
  }
  @Test(arguments:[0.249999,0.25,0.250001])
  func noFrameExpiryIsStrictAndCannotResurrect(_ gap:Double) throws {
    var (state,c,last) = try ready()
    let now = 1.1875+gap
    let r = state.update(empty(last),at:now,maximumAge:0.25)
    #expect((r[.player1]?.candidate != nil) == (gap < 0.25))
    if gap >= 0.25 {
      #expect(r[.player1]?.refusal == .frameGap)
      #expect(state.update(try batch(frame:4,time:now+0.01,context:c),at:now+0.01,maximumAge:0.25)[.player1]?.candidate == nil)
    }
  }
  @Test func translationAndScaleAreAmbiguousDespiteInvariantExtentRatio() throws {
    for scale in [false,true] {
      var (state,c,_) = try ready()
      let b = try batch(frame:4,time:1.25,context:c,scale:scale ? 0.8 : 1,offset:scale ? 0.1 : 0.08)
      #expect(abs(try #require(b.frame?.player1.bilateralExtentOverTorso.value) - 1.4) < 1e-12)
      #expect(state.update(b,at:1.25,maximumAge:0.25)[.player1]?.refusal == .perspectiveAmbiguous)
    }
  }
  @Test func explicitRecaptureClearsOnlyOnePlayerAndBoundsPendingLifetime() throws {
    var (state,_,last) = try ready()
    state.begin(for:.player1,userIdentifiedUprightNeutral:true,status:last.status,at:1.2)
    let r = state.update(empty(last),at:1.2,maximumAge:0.25)
    #expect(r[.player1]?.phase == .collecting && r[.player1]?.candidate == nil && r[.player1]?.sampleCount == 0)
    #expect(r[.player2]?.candidate != nil)
    #expect(state.update(empty(last),at:2.2,maximumAge:0.25)[.player1]?.refusal == .expired)
  }
  @Test func duplicatesStaleAndReversedHostTimeFailClosed() throws {
    var (state,c,last) = try ready()
    #expect(state.update(last,at:1.2,maximumAge:0.25)[.player1]?.refusal == .outOfOrder)
    (state,c,last) = try ready()
    let b = try batch(frame:4,time:1.25,context:c)
    let stale = ExperimentalVisualPostureBatch(status:b.status,resetAll:false,frame:b.frame,refusal:nil)
    // No old-last deadline masks the actual fresh-frame validator during collection.
    state.begin(for:.player1,userIdentifiedUprightNeutral:true,status:b.status,at:1.2)
    #expect(state.update(stale,at:1.5,maximumAge:0.25)[.player1]?.refusal == .stale)
    (state,_,last) = try ready()
    #expect(state.update(empty(last),at:1.1,maximumAge:0.25)[.player1]?.refusal == .invalidTiming)
  }
  @Test func referenceLifetimeExpiresEvenWithContinuousFreshFrames() throws {
    var (state,c,last) = try ready()
    var r: [PlayerID:ExperimentalVisualNeutralResult] = [:]
    for i in 4...35 {
      let t = 1+Double(i)*0.0625
      last = try batch(frame:UInt64(i),time:t,context:c)
      r = state.update(last,at:t,maximumAge:0.25)
    }
    #expect(r[.player1]?.refusal == .expired && r[.player1]?.candidate == nil)
  }
  @Test func smallNoiseUsesMedianAndReferencesRespectDifferentProportions() throws {
    var state = try ExperimentalVisualNeutralReference(policy:policy)
    let c = try TrackingIntegrationFixture().context, initial = try batch(frame:1,time:1.0625,context:c)
    for id in PlayerID.allCases { state.begin(for:id,userIdentifiedUprightNeutral:true,status:initial.status,at:1) }
    var r: [PlayerID:ExperimentalVisualNeutralResult] = [:]
    for (index,offset) in [0.005,-0.005,0.0].enumerated() {
      let time = 1+Double(index+1)*0.0625
      let b = try batch(frame:UInt64(index+1),time:time,context:c,offset:offset,ankleY:0.2)
      r = state.update(b,at:time,maximumAge:0.25)
    }
    let p1 = try #require(r[.player1]?.candidate), p2 = try #require(r[.player2]?.candidate)
    #expect(abs(p1.values.hipY - 0.45) < 1e-12)
    #expect(abs(p1.values.bilateral - 1) < 1e-12 && abs(p2.values.bilateral - 1.4) < 1e-12)
    let b = try batch(frame:4,time:1.25,context:c,ankleY:0.2)
    let compared = state.update(b,at:1.25,maximumAge:0.25)
    #expect(abs(try #require(compared[.player1]?.comparison?.bilateralExtentRatioToNeutral) - 1) < 1e-12)
    #expect(abs(try #require(compared[.player2]?.comparison?.bilateralExtentRatioToNeutral) - 1) < 1e-12)
  }
  @Test func maximumWindowStaysBoundedAndInsufficientSpanRefuses() throws {
    let c = try TrackingIntegrationFixture().context, initial = try batch(frame:1,time:1.01,context:c)
    var fast = try ExperimentalVisualNeutralReference(policy:policy)
    fast.begin(for:.player1,userIdentifiedUprightNeutral:true,status:initial.status,at:1)
    var result: [PlayerID:ExperimentalVisualNeutralResult] = [:]
    for i in 1...3 {
      let t = 1+Double(i)*0.01
      result = fast.update(try batch(frame:UInt64(i),time:t,context:c),at:t,maximumAge:0.25)
    }
    #expect(result[.player1]?.refusal == .insufficientSpan)
    let p = VisualNeutralReferencePolicy(sampleCount:32,minimumSpan:0.125,collectionTimeout:1,
      maximumGap:0.25,referenceLifetime:2,relativeTolerance:0.08,centerTolerance:0.04,
      angleTolerance:0.1,asymmetryTolerance:0.1)
    var maximum = try ExperimentalVisualNeutralReference(policy:p)
    maximum.begin(for:.player1,userIdentifiedUprightNeutral:true,status:initial.status,at:1)
    for i in 1...40 {
      let t = 1+Double(i)*0.01
      result = maximum.update(try batch(frame:UInt64(i),time:t,context:c),at:t,maximumAge:0.25)
      #expect((result[.player1]?.sampleCount ?? 0) <= 32)
    }
    #expect(result[.player1]?.sampleCount == 32 && result[.player1]?.phase == .ready)
    #expect(result[.player2]?.phase == .idle)
  }
  @Test func sampleBudgetAndUnachievablePolicyAreRejected() {
    for n in [0,2,33,Int.max] {
      let p = VisualNeutralReferencePolicy(sampleCount:n,minimumSpan:0.125,collectionTimeout:1,
        maximumGap:0.25,referenceLifetime:2,relativeTolerance:0.08,centerTolerance:0.04,
        angleTolerance:0.1,asymmetryTolerance:0.1)
      #expect(throws:VisualNeutralRefusal.invalidPolicy) { try ExperimentalVisualNeutralReference(policy:p) }
    }
  }
}
