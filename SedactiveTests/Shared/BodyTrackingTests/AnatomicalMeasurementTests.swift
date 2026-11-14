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
      // Ankles at row 84, a few rows above the soles (88/90) as on a person; the earlier row 80
      // put the ankle 16 % of the body above the sole, which policy V2 refuses as a shadow.
      (.leftHip,0.45,0.45),(.rightHip,0.55,0.45),(.leftAnkle,crossed ? 0.57 : 0.43,0.16),(.rightAnkle,crossed ? 0.43 : 0.57,0.16)]
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
  // Policy V2: ears are optional (hair often hides them); nose and both eyes are required.
  @Test(arguments:[BodyJoint.leftEye,.nose,.leftAnkle,.rightAnkle])
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
    // Mask filled between the feet (iPad, 11 November 2026: 100 % of samples): each sole is
    // still its own foot's bottom, read under its own ankle; the fill is not taken as a sole.
    #expect(abs((a.leftSole.imageY ?? 0) - 0.11) < 0.000001 && abs((a.rightSole.imageY ?? 0) - 0.09) < 0.000001)
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
  /// A sample whose head-top/sole reading is missing is skipped for that player; collection
  /// continues without restarting either player. Accepted estimates keep experimental quality.
  @Test(arguments:[false,true]) func calibrationPreservesExperimentalQualityAndSkipsAMissingSample(missing:Bool) throws {
    let (f,initial,stamp) = try LiveVisionFixtures.sessionFixture();var session = initial
    func sample(_ i: Int, anatomy: Bool) throws {
      let pose = try f.result(UInt64(i+3),Double(i)+0.25,LiveVisionFixtures.standingPair)
      let started = session.beginSample(stamp,source:pose.source,at:pose.source.capturedAt)
      try #require(started)
      var mask = LiveVisionFixtures.mask(pose)
      if anatomy { mask = LiveVisionFixtures.withAnatomy(mask, pose: pose, revision: stamp.bindingRevision) }
      session.observe(mask,pose:pose,association:LiveVisionFixtures.association(pose,revision:stamp.bindingRevision),stamp:stamp,at:pose.source.capturedAt+0.01)
    }
    for i in 0..<10 { try sample(i, anatomy: !(missing && i==4)) }
    if missing {
      #expect(session.candidate == nil && session.phase == .collecting)
      for id in PlayerID.allCases {
        #expect(session.players[id]?.samples == 9 && session.players[id]?.rejected[.bodyNotFullyVisible] == 1)
      }
      try sample(10, anatomy: true) // the next good sample completes both windows; nothing restarted
    }
    let candidate = try #require(session.candidate)
    #expect(!candidate.hasValidatedAnatomy)
    #expect(candidate.players.values.allSatisfy { $0.anatomy?.quality == .experimental })
    #expect(candidate.samples == 10 && candidate.lastFrameID == UInt64(missing ? 13 : 12))
    var body = LiveBodyInputState()
    try body.configure(LiveVisionFixtures.configuration(f.context.generation),source:f.context)
    body.calibration = session
    // Owner decision (11 November 2026): stable estimates are accepted AS estimates.
    #expect(candidate.acceptance == .stableEstimate)
    let context = try body.accept(candidateID:candidate.id,expectedRevision:0,at:missing ? 10.3 : 9.3)
    #expect(Set(context.calibrationRevisions.keys) == Set(PlayerID.allCases))
    for id in PlayerID.allCases {
      let value = try #require(body.configuration?.calibrations[id])
      #expect(value.referenceQuality == .experimental, "provenance kept, never promoted to validated")
      #expect(abs(value.standingCrownImageY - 0.9) < 1e-9 && abs(value.standingLeftSoleImageY - 0.1) < 1e-9)
    }
  }
  /// One player moving or cut off never discards the other player's stable samples.
  @Test func eachPlayerCollectsIndependently() throws {
    let (f,initial,stamp) = try LiveVisionFixtures.sessionFixture();var session = initial
    for i in 0..<10 {
      let pose = try f.result(UInt64(i+3),Double(i)*0.25+0.25,LiveVisionFixtures.standingPair)
      let started = session.beginSample(stamp,source:pose.source,at:pose.source.capturedAt); try #require(started)
      var mask = LiveVisionFixtures.withAnatomy(LiveVisionFixtures.mask(pose), pose: pose, revision: stamp.bindingRevision)
      // P2's head-top drifts 20 px per sample (moving), P1 stands still.
      let a = mask.anatomy[.player2]!
      mask.anatomy[.player2] = .init(source:a.source,controlRevision:a.controlRevision,candidateID:a.candidateID,
        crown:.init(imageY:0.9 - Double(i) * 20 / 720,status:.experimental),leftSole:a.leftSole,rightSole:a.rightSole)
      session.observe(mask,pose:pose,association:LiveVisionFixtures.association(pose,revision:stamp.bindingRevision),
        stamp:stamp,at:pose.source.capturedAt+0.01)
    }
    #expect(session.players[.player1]?.samples == 10, "P1 kept every stable sample")
    #expect(session.players[.player2]?.samples == 1 && (session.players[.player2]?.rejected[.moving] ?? 0) == 9)
    #expect(session.candidate == nil, "no candidate until BOTH players are stable")
  }
  /// iPad, 11 November 2026: one jittery head-top reading among still samples is skipped, not
  /// allowed to collapse the window; a real step (two agreeing samples elsewhere) restarts it.
  @Test func anIsolatedOutlierIsSkippedAndARealStepRestartsTheWindow() throws {
    func run(_ crownOffsetPixels: (Int) -> Double, samples: Int) throws -> CalibrationSession {
      let (f,initial,stamp) = try LiveVisionFixtures.sessionFixture();var session = initial
      for i in 0..<samples {
        let pose = try f.result(UInt64(i+3),Double(i)*0.25+0.25,LiveVisionFixtures.standingPair)
        let started = session.beginSample(stamp,source:pose.source,at:pose.source.capturedAt); try #require(started)
        var mask = LiveVisionFixtures.withAnatomy(LiveVisionFixtures.mask(pose), pose: pose, revision: stamp.bindingRevision)
        for id in PlayerID.allCases {
          let a = mask.anatomy[id]!
          mask.anatomy[id] = .init(source:a.source,controlRevision:a.controlRevision,candidateID:a.candidateID,
            crown:.init(imageY:0.9 - crownOffsetPixels(i) / 720,status:.experimental),leftSole:a.leftSole,rightSole:a.rightSole)
        }
        session.observe(mask,pose:pose,association:LiveVisionFixtures.association(pose,revision:stamp.bindingRevision),
          stamp:stamp,at:pose.source.capturedAt+0.01)
      }
      return session
    }
    // Every third reading jumps 10 px and comes straight back: 10 still samples complete the window.
    let jitter = try run({ $0 % 3 == 2 ? 10 : 0 }, samples: 14)
    let candidate = try #require(jitter.candidate, "isolated outliers no longer reset the window")
    #expect(jitter.players[.player1]?.rejected[.moving] == 4)
    #expect(candidate.players.values.allSatisfy { abs(($0.anatomy?.crownY ?? 0) - 0.9) < 1e-9 },
            "skipped outliers never enter the averaged reference")
    // A real step of 10 px after 5 samples: the window restarts from the first two new samples.
    let step = try run({ $0 < 5 ? 0 : 10 }, samples: 9)
    #expect(step.players[.player1]?.samples == 4 && step.players[.player1]?.rejected[.moving] == 2)
    #expect(step.candidate == nil)
  }
  /// The 3 px candidate is never finer than two rows of the mask the estimate was read from
  /// (iPad, 12 November 2026: ±1 row of segmentation noise on a still player is not movement).
  @Test func stabilityToleranceIsNeverBelowTwoMaskRows() throws {
    let (f,initial,stamp) = try LiveVisionFixtures.sessionFixture();var session = initial
    for i in 0..<10 {
      let pose = try f.result(UInt64(i+3),Double(i)*0.25+0.25,LiveVisionFixtures.standingPair)
      let started = session.beginSample(stamp,source:pose.source,at:pose.source.capturedAt); try #require(started)
      var mask = LiveVisionFixtures.withAnatomy(LiveVisionFixtures.mask(pose), pose: pose, revision: stamp.bindingRevision)
      mask.maskHeight = 180 // one mask row = 4 image pixels at 720p
      // Head-top dithers ±1 mask row around a still edge (two rows in all), within no 3 px window.
      for id in PlayerID.allCases {
        let a = mask.anatomy[id]!
        mask.anatomy[id] = .init(source:a.source,controlRevision:a.controlRevision,candidateID:a.candidateID,
          crown:.init(imageY:0.9 - Double(i % 3) / 180,status:.experimental),leftSole:a.leftSole,rightSole:a.rightSole)
      }
      session.observe(mask,pose:pose,association:LiveVisionFixtures.association(pose,revision:stamp.bindingRevision),
        stamp:stamp,at:pose.source.capturedAt+0.01)
    }
    #expect(session.candidate != nil)
    #expect((session.players[.player1]?.rejected[.moving] ?? 0) == 0)
    // Three rows of movement is real movement, not quantization.
    var strict = initial
    for i in 0..<10 {
      let pose = try f.result(UInt64(i+30),Double(i)*0.25+5,LiveVisionFixtures.standingPair)
      let started = strict.beginSample(stamp,source:pose.source,at:pose.source.capturedAt); try #require(started)
      var mask = LiveVisionFixtures.withAnatomy(LiveVisionFixtures.mask(pose), pose: pose, revision: stamp.bindingRevision)
      mask.maskHeight = 180
      for id in PlayerID.allCases {
        let a = mask.anatomy[id]!
        mask.anatomy[id] = .init(source:a.source,controlRevision:a.controlRevision,candidateID:a.candidateID,
          crown:.init(imageY:0.9 - Double(i % 4) / 180,status:.experimental),leftSole:a.leftSole,rightSole:a.rightSole)
      }
      strict.observe(mask,pose:pose,association:LiveVisionFixtures.association(pose,revision:stamp.bindingRevision),
        stamp:stamp,at:pose.source.capturedAt+0.01)
    }
    #expect(strict.candidate == nil)
  }
  @Test func estimatesThatDisagreeWithLandmarksAreRefusedPerPlayer() {
    let ok = StandingPlayerObservation(noseY:0.8,leftAnkleY:0.12,rightAnkleY:0.12,hipY:0.5,torsoLength:0.2,
      originX:0.5,maskMinY:0.05,maskMaxY:0.9,anatomy:.init(crownY:0.9,leftSoleY:0.1,rightSoleY:0.1,quality:.experimental))
    #expect(StandingEstimateAcceptancePolicyV1.refusal(ok, player:.player1) == nil)
    func with(_ a: StandingAnatomicalReferences?, nose: Double? = 0.8) -> StandingPlayerObservation {
      .init(noseY:nose,leftAnkleY:0.12,rightAnkleY:0.12,hipY:0.5,torsoLength:0.2,originX:0.5,
        maskMinY:0.05,maskMaxY:0.9,anatomy:a)
    }
    var bad: [StandingPlayerObservation] = [
      with(nil),                                                                          // missing/cropped/occluded
      with(.init(crownY:0.75,leftSoleY:0.1,rightSoleY:0.1,quality:.experimental)),         // head-top under the nose
      with(.init(crownY:0.9,leftSoleY:0.2,rightSoleY:0.1,quality:.experimental)),          // sole above its ankle
      with(.init(crownY:0.9,leftSoleY:0.1,rightSoleY:0.1,quality:.experimental), nose:nil), // no nose landmark
      with(.init(crownY:0.9,leftSoleY:0.1,rightSoleY:0.1,quality:.unavailable)),
      with(.init(crownY:.nan,leftSoleY:0.1,rightSoleY:0.1,quality:.experimental))]
    // Stable but anatomically wrong: a head-top far above the nose (hands on the head in every
    // sample), or soles far below the ankles (a shadow): refused at acceptance too.
    bad.append(with(.init(crownY:0.98,leftSoleY:0.1,rightSoleY:0.1,quality:.experimental), nose:0.7))
    for (index, value) in bad.enumerated() {
      let reason = StandingEstimateAcceptancePolicyV1.refusal(value, player:.player2)
      #expect(reason?.hasPrefix("P2's") == true, "case \(index)")
      #expect(reason.map(StandingEstimateAcceptancePolicyV1.isPlayerFacing) == true)
    }
  }
}
