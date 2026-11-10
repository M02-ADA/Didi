import Foundation
import Testing
@testable import Sedactive

nonisolated enum AnatomyFixtures {
  static func extract(missing: BodyJoint? = nil, crossed: Bool = false,
    pixel: (Int, Int) -> UInt8 = mask) throws -> AnatomicalPlayerCandidate {
    let f = try TrackingIntegrationFixture(), source = try f.result(1, 0).source
    var j: [BodyJoint: PoseJoint] = [:]
    let values: [(BodyJoint, Double, Double)] = [(.nose,0.5,0.75),(.leftEye,0.46,0.8),
      (.rightEye,0.54,0.8),(.leftEar,0.4,0.76),(.rightEar,0.6,0.76),(.neck,0.5,0.65),
      (.leftHip,0.45,0.45),(.rightHip,0.55,0.45),(.leftAnkle,crossed ? 0.57 : 0.43,0.2),(.rightAnkle,crossed ? 0.43 : 0.57,0.2)]
    for (name,x,y) in values where name != missing { j[name] = .init(x:x,y:y,confidence:0.9) }
    let c = PoseCandidate(candidateID:10,joints:j,maskTopImageY:nil,maskBottomImageY:nil,
      leftFootBottomImageY:nil,rightFootBottomImageY:nil,maskAssociation:.unavailable)
    let region = PersonMaskRegion(candidateID:10,label:1,minX:0.1,maxX:0.9,minY:0.05,maxY:0.95)
    return BodyMeasurementExtractor.experimentalAnatomy(source:source,controlRevision:2,
      candidate:c,region:region,width:100,height:100,labelAt:pixel)
  }
  static func mask(_ x:Int,_ y:Int) -> UInt8 {
    if (10...22).contains(y) && (42...58).contains(x) { return 1 }
    if (23...65).contains(y) && (40...60).contains(x) { return 1 }
    if (65...88).contains(y) && (40...46).contains(x) { return 1 }
    if (65...90).contains(y) && (54...60).contains(x) { return 1 }
    return 0
  }
  static func frame(_ f:TrackingIntegrationFixture,_ id:UInt64,_ t:Double,
    feet:Double?, revision:UInt64 = 2) throws -> AnatomicalPlayerCandidate {
    let s = try f.result(id,t).source
    let c = AnatomicalCandidateScalar(imageY:0.9,status:.experimental)
    let sole = feet.map { AnatomicalCandidateScalar(imageY:$0,status:.experimental) } ?? .refused(.missingLandmarks)
    return .init(source:s,controlRevision:revision,candidateID:10,crown:c,leftSole:sole,rightSole:sole)
  }
}
nonisolated struct AnatomicalMeasurementTests {
  @Test func headSupportedAndFeetAreIndependentExperimentalValues() throws {
    let a = try AnatomyFixtures.extract()
    #expect(a.crown.imageY == 0.9)
    #expect(abs((a.leftSole.imageY ?? 0)-0.11)<0.000001)
    #expect(abs((a.rightSole.imageY ?? 0)-0.09)<0.000001)
    #expect(a.experimentalReferences?.quality == .experimental)
  }
  @Test func raisedExtremumOutsideHeadDoesNotBecomeCrown() throws {
    let a = try AnatomyFixtures.extract { x,y in
      (5...9).contains(y) && (5...9).contains(x) ? 1 : AnatomyFixtures.mask(x,y)
    }
    #expect(a.crown.imageY == 0.9)
  }
  @Test(arguments:[BodyJoint.leftEye,.rightEar,.leftAnkle,.rightAnkle])
  func missingAnatomicalSupportRefuses(_ joint:BodyJoint) throws {
    let a = try AnatomyFixtures.extract(missing:joint)
    if joint == .leftAnkle || joint == .rightAnkle {
      #expect(a.leftSole.imageY == nil && a.rightSole.imageY == nil)
    } else { #expect(a.crown.imageY == nil) }
  }
  @Test func truncatedHeadAndMergedFeetRefuse() throws {
    let a = try AnatomyFixtures.extract { x,y in
      if y < 10 && (42...58).contains(x) { return 1 }
      if (80...90).contains(y) && (46...54).contains(x) { return 1 }
      return AnatomyFixtures.mask(x,y)
    }
    #expect(a.crown.status == .truncated)
    #expect(a.leftSole.status == .ambiguous && a.rightSole.status == .ambiguous)
    let cross = try AnatomyFixtures.extract(crossed:true)
    #expect(cross.leftSole.imageY == nil && cross.rightSole.imageY == nil)
  }
  @Test func unsupportedFaceAttachmentAndTruncatedSoleRefuse() throws {
    let a = try AnatomyFixtures.extract { x,y in
      if y == 30 { return 0 }
      if y > 88 && (40...46).contains(x) { return 1 }
      return AnatomyFixtures.mask(x,y)
    }
    #expect(a.crown.imageY == nil)
    #expect(a.leftSole.status == .truncated)
  }
  @Test func temporalAirborneNeedsGroundedHistoryDwellAndBothFeet() throws {
    let f = try TrackingIntegrationFixture()
    let baseline = ExperimentalStandingSurface(source:f.context,playerID:.player1,controlRevision:2,calibrationRevision:1,
      leftSoleY:0.1,rightSoleY:0.1,hipY:0.4,uncertaintyImageY:0.01)
    var detector = ExperimentalJumpDetector()
    for i in 0..<3 {
      let a = try AnatomyFixtures.frame(f,UInt64(i+1),Double(i)*0.05,feet:0.1)
      let result = detector.process(a,hipY:0.4,reference:baseline,playerID:.player1,cameraStationaryEvidence:true)
      #expect(result.phase == (i==2 ? .groundedCandidate : .unknown))
      #expect(result.authoritative.validity != .valid)
    }
    for i in 0..<3 {
      let a = try AnatomyFixtures.frame(f,UInt64(i+4),0.15+Double(i)*0.05,feet:0.15)
      let result = detector.process(a,hipY:0.45,reference:baseline,playerID:.player1,cameraStationaryEvidence:true)
      #expect(result.phase == (i==2 ? .airborneCandidate : .unknown))
    }
    let missing = try AnatomyFixtures.frame(f,7,0.3,feet:nil)
    let result = detector.process(missing,hipY:0.45,reference:baseline,playerID:.player1,cameraStationaryEvidence:true)
    #expect(result.phase == .unknown)
    let raised = try AnatomyFixtures.frame(f,8,0.35,feet:0.15)
    let after = detector.process(raised,hipY:0.45,reference:baseline,playerID:.player1,cameraStationaryEvidence:true)
    #expect(after.phase == .unknown)
  }
  @Test(arguments:[false,true]) func ambiguityAndOneHzCadenceCannotProveJump(stationary:Bool) throws {
    let f = try TrackingIntegrationFixture()
    let baseline = ExperimentalStandingSurface(source:f.context,playerID:.player1,controlRevision:2,calibrationRevision:1,
      leftSoleY:0.1,rightSoleY:0.1,hipY:0.4,uncertaintyImageY:0.01)
    var d = ExperimentalJumpDetector()
    for i in 0..<4 {
      let a = try AnatomyFixtures.frame(f,UInt64(i+1),Double(i),feet:0.1)
      let result = d.process(a,hipY:0.4,reference:baseline,playerID:.player1,cameraStationaryEvidence:stationary)
      #expect(result.phase == .unknown)
    }
    let wrong = try AnatomyFixtures.frame(f,10,5,feet:0.15,revision:3)
    let result = d.process(wrong,hipY:0.45,reference:baseline,playerID:.player1,cameraStationaryEvidence:true)
    #expect(result.phase == .unknown)
  }
  @Test func oneFootAndReorderedSamplesCannotAccumulateFlight() throws {
    let f = try TrackingIntegrationFixture()
    let baseline = ExperimentalStandingSurface(source:f.context,playerID:.player1,controlRevision:2,
      calibrationRevision:1,leftSoleY:0.1,rightSoleY:0.1,hipY:0.4,uncertaintyImageY:0.01)
    var d = ExperimentalJumpDetector()
    for i in 0..<3 {
      let a = try AnatomyFixtures.frame(f,UInt64(i+1),Double(i)*0.05,feet:0.1)
      _ = d.process(a,hipY:0.4,reference:baseline,playerID:.player1,cameraStationaryEvidence:true)
    }
    let a = try AnatomyFixtures.frame(f,4,0.15,feet:0.15)
    let one = AnatomicalPlayerCandidate(source:a.source,controlRevision:a.controlRevision,candidateID:10,
      crown:a.crown,leftSole:a.leftSole,rightSole:.init(imageY:0.1,status:.experimental))
    let single = d.process(one,hipY:0.45,reference:baseline,playerID:.player1,cameraStationaryEvidence:true)
    #expect(single.phase == .unknown)
    let stale = try AnatomyFixtures.frame(f,3,0.1,feet:0.15)
    let old = d.process(stale,hipY:0.45,reference:baseline,playerID:.player1,cameraStationaryEvidence:true)
    #expect(old.phase == .unknown)
    let peer = d.process(a,hipY:0.45,reference:baseline,playerID:.player2,cameraStationaryEvidence:true)
    #expect(peer.phase == .unknown)
    let newSource = ExperimentalStandingSurface(source:CameraTestFrames.context(2),playerID:.player1,
      controlRevision:2,calibrationRevision:2,leftSoleY:0.1,rightSoleY:0.1,hipY:0.4,uncertaintyImageY:0.01)
    let mismatch = d.process(a,hipY:0.45,reference:newSource,playerID:.player1,cameraStationaryEvidence:true)
    #expect(mismatch.phase == .unknown)
  }
  @Test(arguments:[false,true]) func calibrationPreservesExperimentalQualityAndRejectsMissingWindow(missing:Bool) throws {
    let (f,initial,stamp) = try LiveVisionFixtures.sessionFixture();var session = initial
    for i in 0..<10 {
      let pose = try f.result(UInt64(i+3),Double(i)+0.25,LiveVisionFixtures.standingPair)
      let started = session.beginSample(stamp,source:pose.source,at:pose.source.capturedAt)
      try #require(started)
      var mask = LiveVisionFixtures.mask(pose)
      if !(missing && i==4) {
        for (id,region) in mask.regions {
          let c = AnatomicalCandidateScalar(imageY:0.9,status:.experimental)
          let sole = AnatomicalCandidateScalar(imageY:0.1,status:.experimental)
          mask.anatomy[id] = .init(source:pose.source,controlRevision:stamp.bindingRevision,
            candidateID:region.candidateID,crown:c,leftSole:sole,rightSole:sole)
        }
      }
      session.observe(mask,pose:pose,association:LiveVisionFixtures.association(pose,revision:stamp.bindingRevision),stamp:stamp,at:pose.source.capturedAt+0.01)
    }
    let candidate = try #require(session.candidate)
    #expect(!candidate.hasValidatedAnatomy)
    #expect(candidate.players.values.allSatisfy { missing ? $0.anatomy == nil : $0.anatomy?.quality == .experimental })
    var body = LiveBodyInputState()
    try body.configure(LiveVisionFixtures.configuration(f.context.generation),source:f.context)
    body.calibration = session
    #expect(throws:LiveVisionError.unsupportedAnatomy) {
      try body.accept(candidateID:candidate.id,expectedRevision:0,at:9.3)
    }
  }
}
