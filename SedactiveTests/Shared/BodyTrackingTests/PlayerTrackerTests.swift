import Foundation
import Testing
@testable import Sedactive

/// Synthetic policy only: chosen for simple geometric separation and exact binary-time boundaries.
/// These constants are not a live default or physical confidence/performance acceptance thresholds.
nonisolated enum TrackingFixtures {
  static let generation = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
  static let epoch = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
  static func policy(confidence: Double = 0.5, torso: Double = 0.02,
    separation: Double = 0.12, guardFraction: Double = 0.04,
    acquisition: Double = 0.125, recovery: Double = 0.125,
    gap: Double = 1, window: Double = 2, freshness: Double = 0.5,
    speed: Double = 0.5, position: Double = 0.15, residual: Double = 0.22,
    logScale: Double = 0.35, positionWeight: Double = 0.4, jointWeight: Double = 0.4,
    shapeWeight: Double = 0.2, missingPenalty: Double = 0.3,
    unmatched: Double = 2, margin: Double = 0.15, coreCount: Int = 3
  ) -> PlayerTrackingPolicy {
    PlayerTrackingPolicy(minimumJointConfidence: confidence, minimumTorsoExtent: torso,
      minimumPairSeparation: separation, centerGuardFraction: guardFraction,
      acquisitionDwell: acquisition, recoveryDwell: recovery, maximumObservationGap: gap,
      recoveryWindow: window, freshness: freshness, maximumSpeed: speed, positionGate: position,
      jointResidualGate: residual, maximumLogScaleChange: logScale,
      positionWeight: positionWeight, jointWeight: jointWeight, shapeWeight: shapeWeight,
      missingEvidencePenalty: missingPenalty, unmatchedCost: unmatched, assignmentMargin: margin,
      minimumSharedCoreJoints: coreCount)
  }
  static func context(generation: UUID = generation, epoch: UUID = epoch,
    geometry: UInt64 = 1, width: Int = 1280, height: Int = 720,
    rotation: Double = 0, mirrored: Bool = false) -> PlayerTrackingContext {
    .init(generation: generation, epoch: epoch, geometryRevision: geometry,
      imageWidth: width, imageHeight: height, rotationAngle: rotation, mirrored: mirrored)
  }
  static func candidate(_ id: UInt64, x: Double, y: Double = 0.5, length: Double = 0.2,
    confidence: Double = 0.9, missing: [BodyJoint] = []) -> PoseCandidate {
    var points: [BodyJoint: PoseJoint] = [
      .leftShoulder: .init(x: x - 0.05, y: y + length / 2, confidence: confidence),
      .rightShoulder: .init(x: x + 0.05, y: y + length / 2, confidence: confidence),
      .leftHip: .init(x: x - 0.04, y: y - length / 2, confidence: confidence),
      .rightHip: .init(x: x + 0.04, y: y - length / 2, confidence: confidence),
    ]
    for joint in missing { points.removeValue(forKey: joint) }
    return .init(candidateID: id, joints: points, maskTopImageY: nil, maskBottomImageY: nil,
      leftFootBottomImageY: nil, rightFootBottomImageY: nil, maskAssociation: .unavailable)
  }
  static var pair: [PoseCandidate] { [candidate(10, x: 0.75), candidate(20, x: 0.25)] }
  static func source(_ id: UInt64, _ time: Double,
    context: PlayerTrackingContext = context(), revision: UInt64 = 1) -> PlayerTrackingSource {
    .init(context: context, frameID: id, capturedAt: time, controlRevision: revision)
  }
  static func input(_ id: UInt64, _ time: Double, _ candidates: [PoseCandidate] = pair,
    count: Int? = nil, context: PlayerTrackingContext = context(), revision: UInt64 = 1
  ) -> PlayerTrackingInput {
    .init(source: source(id, time, context: context, revision: revision),
      frame: .init(sessionGeneration: context.generation, frameID: id, capturedAt: time,
        cameraGeometryRevision: context.geometryRevision, imageWidth: context.imageWidth,
        imageHeight: context.imageHeight, candidates: candidates),
      observationCount: count ?? candidates.count)
  }
  static func tracker(policy: PlayerTrackingPolicy = policy(), armed: Bool = true,
    context: PlayerTrackingContext = context()) throws -> PlayerTracker {
    var value = try PlayerTracker(policy: policy)
    try value.reset(context: context, controlRevision: 1)
    if armed { try value.armBinding(controlRevision: 1) }
    return value
  }
  static func bound(policy: PlayerTrackingPolicy = policy(),
    pair: [PoseCandidate] = pair, context: PlayerTrackingContext = context()) throws -> PlayerTracker {
    var value = try tracker(policy: policy, context: context)
    try value.process(input(1, 0, pair, context: context))
    try value.process(input(2, 0.125, pair, context: context))
    #expect(value.snapshot.player1.state == .tracking)
    #expect(value.snapshot.player2.state == .tracking)
    return value
  }
  static func duplicateNearCenter(mirrored: Bool,
    policy: PlayerTrackingPolicy = policy()) throws -> PlayerTracker {
    var tracker = try bound(policy: policy)
    for step in 1...8 {
      let offset = Double(step) * 0.025
      let r = try tracker.process(input(UInt64(step + 2), 0.125 + Double(step) * 0.125,
        [candidate(10, x: 0.75 - offset), candidate(20, x: 0.25 + offset)]))
      #expect(r.player1.state == .tracking && r.player2.state == .tracking)
    }
    let excluded: PlayerID = mirrored ? .player2 : .player1
    let other: PlayerID = mirrored ? .player1 : .player2
    let duplicateX = mirrored ? 0.449 : 0.551
    let duplicate = try tracker.process(input(11, 1.25,
      [candidate(10, x: 0.55), candidate(30, x: duplicateX), candidate(20, x: 0.45)]))
    #expect(duplicate[excluded].state == .uncertain && duplicate[excluded].requiresRebind)
    #expect(duplicate[excluded].candidateID == nil && duplicate[other].state == .tracking)
    return tracker
  }

  static func partialAmbiguityScene(mirrored: Bool,
    missing: BodyJoint = .leftHip) -> [PoseCandidate] {
    let x = mirrored ? 0.45 : 0.55
    return [candidate(30, x: x, missing: [missing]),
      candidate(40, x: x + (mirrored ? -0.001 : 0.001), missing: [missing]),
      candidate(90, x: mirrored ? 0.55 : 0.45)]
  }
  static let threeCandidateOrders = [[0, 1, 2], [0, 2, 1], [1, 0, 2],
    [1, 2, 0], [2, 0, 1], [2, 1, 0]]

  static func opposingDisplacements(mirrored: Bool = false, restored: Bool = false,
    ids: [UInt64] = [30, 40]) -> [PoseCandidate] {
    let raw: [[BodyJoint: (Double, Double)]] = [
      [.leftShoulder: (0.36, 0.60), .rightShoulder: (0.64, 0.60),
        .leftHip: (0.51, 0.40), .rightHip: (0.59, 0.40)],
      [.leftShoulder: (0.44, 0.60), .rightShoulder: (0.56, 0.60),
        .leftHip: (0.41, 0.40), .rightHip: (0.49, 0.40)],
    ]
    return raw.enumerated().map { index, values in
      var joints = values.mapValues { point in
        PoseJoint(x: mirrored ? 1 - point.0 : point.0, y: point.1, confidence: 0.9)
      }
      if !restored { joints.removeValue(forKey: index == 0 ? .leftHip : .rightHip) }
      return PoseCandidate(candidateID: ids[index], joints: joints,
        maskTopImageY: nil, maskBottomImageY: nil, leftFootBottomImageY: nil,
        rightFootBottomImageY: nil, maskAssociation: .unavailable)
    }
  }

  static func opposingBindingPair(mirrored: Bool) -> [PoseCandidate] {
    [candidate(10, x: 0.55), candidate(20, x: 0.45)].map { candidate in
      guard mirrored else { return candidate }
      return PoseCandidate(candidateID: candidate.candidateID,
        joints: candidate.joints.mapValues {
          PoseJoint(x: 1 - $0.x, y: $0.y, confidence: $0.confidence)
        }, maskTopImageY: nil, maskBottomImageY: nil, leftFootBottomImageY: nil,
        rightFootBottomImageY: nil, maskAssociation: .unavailable)
    }
  }

  static func coherentShouldersOppositeTorso(mirrored: Bool, restored: Bool = false,
    ids: [UInt64] = [30, 40]) -> [PoseCandidate] {
    let raw: [[BodyJoint: (Double, Double)]] = [
      [.leftShoulder: (0.49, 0.60), .rightShoulder: (0.59, 0.60),
        .leftHip: (0.42, 0.40), .rightHip: (0.50, 0.40)],
      [.leftShoulder: (0.41, 0.60), .rightShoulder: (0.51, 0.60),
        .leftHip: (0.50, 0.40), .rightHip: (0.58, 0.40)],
    ]
    return raw.enumerated().map { index, points in
      var joints = points.mapValues {
        PoseJoint(x: mirrored ? 1 - $0.0 : $0.0, y: $0.1, confidence: 0.9)
      }
      if !restored { joints.removeValue(forKey: index == 0 ? .leftHip : .rightHip) }
      return PoseCandidate(candidateID: ids[index], joints: joints,
        maskTopImageY: nil, maskBottomImageY: nil, leftFootBottomImageY: nil,
        rightFootBottomImageY: nil, maskAssociation: .unavailable)
    }
  }

}

nonisolated struct PlayerTrackerTests {
  typealias F = TrackingFixtures

  @Test(arguments: [0, 1, 2])
  func disarmedNeverAutomaticallyBinds(_ count: Int) throws {
    var tracker = try F.tracker(armed: false)
    for i in 1...4 {
      let result = try tracker.process(F.input(UInt64(i), Double(i), Array(F.pair.prefix(count))))
      #expect(result.player1.state == .unbound && result.player2.state == .unbound)
      #expect(result.player1.reason == .disarmed && result.provisionalDescriptorCount == 0)
    }
  }
  @Test(arguments: [0, 1])
  func armedAcquisitionNeedsTwoPeople(_ count: Int) throws {
    var tracker = try F.tracker()
    for i in 1...4 {
      let r = try tracker.process(F.input(UInt64(i), Double(i), Array(F.pair.prefix(count))))
      #expect(r.player1.state == .unbound && r.player2.state == .unbound)
      #expect(r.provisionalDescriptorCount == 0)
    }
  }
  @Test func acquisitionIsAtomicCaptureTimeDwellAndMirroredExactlyOnce() throws {
    var tracker = try F.tracker()
    let first = try tracker.process(F.input(1, 0, F.pair.reversed()))
    #expect(first.player1.state == .unbound && first.player2.state == .unbound)
    #expect(first.provisionalDescriptorCount == 2 && first.confirmedDescriptorCount == 0)
    try tracker.armBinding(controlRevision: 1) // Idempotent; does not reset dwell.
    let second = try tracker.process(F.input(8, 0.0625))
    #expect(second.player1.state == .unbound)
    let third = try tracker.process(F.input(99, 0.125))
    #expect(third.player1.candidateID == 10) // Canonical right = DISPLAYED LEFT.
    #expect(third.player2.candidateID == 20)
    #expect(third.confirmedDescriptorCount == 2 && third.provisionalDescriptorCount == 0)
  }
  @Test func evenZeroDwellRequiresMultipleSupportedObservations() throws {
    var tracker = try F.tracker(policy: F.policy(acquisition: 0, recovery: 0))
    let a = try tracker.process(F.input(1, 0))
    #expect(a.player1.state == .unbound)
    let b = try tracker.process(F.input(2, 0.01))
    #expect(b.player1.state == .tracking)
  }
  @Test(arguments: [0, 1, 2, 3, 4])
  func ambiguousExtraDuplicatePartialOrWeakAcquisitionRefuses(_ variant: Int) throws {
    let cases: [[PoseCandidate]] = [
      [F.candidate(1, x: 0.5), F.candidate(2, x: 0.51)],
      F.pair + [F.candidate(30, x: 0.5)],
      [F.candidate(1, x: 0.75), F.candidate(2, x: 0.751)],
      [F.candidate(1, x: 0.75, missing: [.leftHip]), F.candidate(2, x: 0.25)],
      [F.candidate(1, x: 0.75, confidence: 0.49), F.candidate(2, x: 0.25)],
    ]
    var tracker = try F.tracker()
    try tracker.process(F.input(1, 0, cases[variant]))
    let r = try tracker.process(F.input(2, 0.25, cases[variant]))
    #expect(r.player1.state == .unbound && r.player2.state == .unbound)
    #expect(r.player1.candidateID == nil && r.player2.candidateID == nil)
  }
  @Test func acquisitionCannotAccumulateDwellAcrossRefusalOrLongGap() throws {
    var tracker = try F.tracker()
    try tracker.process(F.input(1, 0))
    try tracker.process(F.input(2, 0.0625, []))
    #expect(try tracker.process(F.input(3, 0.25)).player1.state == .unbound)
    #expect(try tracker.process(F.input(4, 1.5)).player1.state == .unbound)
    #expect(try tracker.process(F.input(5, 1.625)).player1.state == .tracking)
  }
  @Test func frameLocalIDsAndObservationArrayOrderNeverIdentifyThePerson() throws {
    var tracker = try F.bound()
    let r = try tracker.process(F.input(3, 0.25,
      [F.candidate(10, x: 0.25), F.candidate(20, x: 0.75)]))
    #expect(r.player1.candidateID == 20 && r.player2.candidateID == 10)
    #expect(r.player1.state == .tracking && r.player2.state == .tracking)
  }
  @Test func distinguishablePathsExchangeScreenSidesWithoutRenamingSlots() throws {
    let pair = [F.candidate(10, x: 0.75, y: 0.7), F.candidate(20, x: 0.25, y: 0.3)]
    var tracker = try F.bound(pair: pair)
    for i in 1...20 {
      let x = 0.75 - Double(i) * 0.025
      let current = [F.candidate(90, x: 1 - x, y: 0.3), F.candidate(40, x: x, y: 0.7)]
      let r = try tracker.process(F.input(UInt64(i + 2), 0.125 + Double(i) * 0.125, current))
      #expect(r.player1.candidateID == 40 && r.player2.candidateID == 90)
      #expect(r.player1.state == .tracking && r.player2.state == .tracking)
    }
  }
  @Test func differentTorsoGeometryCanDisambiguateCrossing() throws {
    let pair = [F.candidate(10, x: 0.75, length: 0.18), F.candidate(20, x: 0.25, length: 0.32)]
    var tracker = try F.bound(pair: pair)
    for i in 1...20 {
      let x = 0.75 - Double(i) * 0.025
      let r = try tracker.process(F.input(UInt64(i + 2), 0.125 + Double(i) * 0.125,
        [F.candidate(1, x: x, length: 0.18), F.candidate(2, x: 1 - x, length: 0.32)]))
      #expect(r.player1.candidateID == 1 && r.player2.candidateID == 2)
    }
  }
  @Test func indistinguishableCrossingLatchesLostAndDoesNotRecoverBySorting() throws {
    var tracker = try F.bound(policy: F.policy(position: 0.6, residual: 0.6))
    let overlap = try tracker.process(F.input(3, 0.25, [F.candidate(4, x: 0.5)]))
    #expect(overlap.player1.state == .lost && overlap.player2.state == .lost)
    #expect(overlap.player1.reason == .ambiguous)
    for i in 4...8 {
      let r = try tracker.process(F.input(UInt64(i), Double(i) * 0.125))
      #expect(r.player1.state == .lost && r.player2.state == .lost)
      #expect(r.player1.candidateID == nil && r.player2.candidateID == nil)
    }
  }
  @Test func positionSwapWithoutObservableContinuousPathIsNotForced() throws {
    var tracker = try F.bound()
    // Identical people teleported to exchanged positions are unobservable to a pose-only system.
    // A too-large temporal gap refuses both rather than claiming knowledge of this substitution.
    let r = try tracker.process(F.input(3, 1.25,
      [F.candidate(1, x: 0.25), F.candidate(2, x: 0.75)]))
    #expect(r.player1.state == .lost && r.player2.state == .lost)
    #expect(r.player1.reason == .observationGap)
  }
  @Test(arguments: [BodyJoint.leftHip, .rightHip, .leftShoulder, .rightShoulder])
  func partialTorsoUsesComparableAnatomicalSupport(_ missing: BodyJoint) throws {
    var tracker = try F.bound()
    let r = try tracker.process(F.input(3, 0.25,
      [F.candidate(1, x: 0.75, missing: [missing]), F.candidate(2, x: 0.25)]))
    #expect(r.player1.state == .tracking && r.player1.candidateID == 1)
    #expect(r.player1.cost! > 0) // Missing shared joint AND shape term have real penalties.
    #expect(r.player2.cost == 0)
  }
  @Test func changingPartialAnchorKindsCannotCreateCheapMatch() throws {
    var tracker = try F.bound()
    try tracker.process(F.input(3, 0.25,
      [F.candidate(1, x: 0.75, missing: [.leftHip]), F.candidate(2, x: 0.25)]))
    let r = try tracker.process(F.input(4, 0.375,
      [F.candidate(1, x: 0.75, missing: [.rightShoulder]), F.candidate(2, x: 0.25)]))
    #expect(r.player1.state == .uncertain) // Only two common joints; no false center comparison.
    #expect(r.player2.state == .tracking)
  }
  @Test(arguments: [0.0, 0.01, 0.49])
  func weakCoreDoesNotBecomeReliableByAveragingOtherJoints(_ confidence: Double) throws {
    var tracker = try F.bound()
    let r = try tracker.process(F.input(3, 0.25,
      [F.candidate(1, x: 0.75, confidence: confidence), F.candidate(2, x: 0.25)]))
    #expect(r.player1.state == .uncertain && r.player1.candidateID == nil)
    #expect(r.player2.state == .tracking)
  }

  @Test func degeneratePartialTorsoIsNotIndependentSupportJustBecauseThreeJointsExist() throws {
    var tracker = try F.bound()
    let point = PoseJoint(x: 0.75, y: 0.5, confidence: 1)
    let bad = PoseCandidate(candidateID: 1,
      joints: [.leftShoulder: point, .rightShoulder: point, .leftHip: point],
      maskTopImageY: nil, maskBottomImageY: nil, leftFootBottomImageY: nil,
      rightFootBottomImageY: nil, maskAssociation: .unavailable)
    let r = try tracker.process(F.input(3, 0.25, [bad, F.candidate(2, x: 0.25)]))
    #expect(r.player1.state == .uncertain && r.player1.candidateID == nil)
    #expect(r.player2.state == .tracking)
  }
  @Test func absentPeripheralJointsDoNotInvalidateStrongTorso() throws {
    var tracker = try F.bound() // Fixtures intentionally have no wrists, ankles, neck or face.
    let r = try tracker.process(F.input(3, 0.25))
    #expect(r.player1.state == .tracking && r.player2.state == .tracking)
  }
  @Test func temporaryLossRequiresRecoveryDwellWithoutTentativeHistoryUpdates() throws {
    var tracker = try F.bound()
    let missing = try tracker.process(F.input(3, 0.25, [F.candidate(2, x: 0.25)]))
    #expect(missing.player1.state == .uncertain && missing.player2.state == .tracking)
    let historyCount = missing.confirmedDescriptorCount
    let tentative = try tracker.process(F.input(4, 0.375))
    #expect(tentative.player1.state == .uncertain && tentative.player1.reason == .recovering)
    #expect(tentative.player1.candidateID == nil && tentative.provisionalDescriptorCount == 1)
    #expect(tentative.confirmedDescriptorCount == historyCount)
    let recovered = try tracker.process(F.input(5, 0.5))
    #expect(recovered.player1.state == .tracking && recovered.player1.candidateID == 10)
  }
  @Test func conflictingRecoveryLatchesRebindWithoutUpdatingConfirmedHistory() throws {
    var tracker = try F.bound()
    try tracker.process(F.input(3, 0.25, []))
    try tracker.process(F.input(4, 0.375))
    let conflict = try tracker.process(F.input(5, 0.4375,
      F.pair + [F.candidate(31, x: 0.751)]))
    #expect(conflict.player1.state == .uncertain && conflict.player1.candidateID == nil)
    #expect(conflict.provisionalDescriptorCount == 1) // P2 recovery remains supported.
    let next = try tracker.process(F.input(6, 0.5))
    #expect(next.player1.state == .uncertain)
    let unresolved = try tracker.process(F.input(7, 0.625))
    #expect(unresolved.player1.state == .uncertain && unresolved.player1.requiresRebind)
    #expect(unresolved.player1.reason == .ambiguous && unresolved.player1.candidateID == nil)
  }
  @Test func lostIdentityNeverAutomaticallyAcceptsReturningOrThirdPerson() throws {
    var tracker = try F.bound()
    try tracker.expire(at: 2.125, controlRevision: 1)
    let r = try tracker.process(F.input(3, 2.25))
    #expect(r.player1.state == .lost && r.player2.state == .lost)
    #expect(throws: PlayerTrackingError.bindingRequiresNewGeneration) {
      try tracker.armBinding(controlRevision: 1)
    }
  }
  @Test func distantThirdPersonDoesNotReplaceOrDisruptUniqueTracks() throws {
    var tracker = try F.bound()
    let r = try tracker.process(F.input(3, 0.25, F.pair + [F.candidate(30, x: 0.5)]))
    #expect(r.player1.candidateID == 10 && r.player2.candidateID == 20)
    #expect(r.player1.state == .tracking && r.player2.state == .tracking)
  }
  @Test func nearbyExtraOrDuplicateIsUncertaintyForAffectedSlotOnly() throws {
    var tracker = try F.bound()
    let r = try tracker.process(F.input(3, 0.25, F.pair + [F.candidate(30, x: 0.751)]))
    #expect(r.player1.state == .uncertain && r.player1.reason == .ambiguous)
    #expect(r.player1.candidateID == nil && r.player2.candidateID == 20)
  }

  @Test func thirdEntrantCannotInheritIdentityWhenOriginalAlternativeDisappears() throws {
    var tracker = try F.bound()
    let challenged = try tracker.process(F.input(3, 0.25,
      F.pair + [F.candidate(30, x: 0.751)]))
    #expect(challenged.player1.state == .uncertain && challenged.player1.requiresRebind)
    // The original has disappeared; the indistinguishable entrant stays in its old location.
    for i in 4...8 {
      let r = try tracker.process(F.input(UInt64(i), Double(i) * 0.125,
        [F.candidate(30, x: 0.751), F.candidate(20, x: 0.25)]))
      #expect(r.player1.state == .uncertain && r.player1.candidateID == nil)
      #expect(r.player1.requiresRebind && r.player2.state == .tracking)
    }
  }
  @Test(arguments: [false, true])
  func excludedIdentityMustNotBeClaimedByOtherSlot(_ mirrored: Bool) throws {
    var tracker = try F.duplicateNearCenter(mirrored: mirrored)
    let excluded: PlayerID = mirrored ? .player2 : .player1
    let other: PlayerID = mirrored ? .player1 : .player2
    let remaining = mirrored ? F.candidate(20, x: 0.45) : F.candidate(10, x: 0.55)
    let r = try tracker.process(F.input(12, 1.375, [remaining]))
    #expect(r[other].state == .uncertain && r[other].reason == .missingOrWeak)
    #expect(r[other].candidateID == nil && !r[other].requiresRebind)
    #expect(r[other].lastConfirmedAt == 1.25 && r[excluded].lastConfirmedAt == 1.125)
    #expect(r[excluded].state == .uncertain && r[excluded].requiresRebind)
    #expect(r[excluded].candidateID == nil)
  }

  @Test func lostSlotNotReplacedAndExpiredCompetitorRequiresExplicitRebind() throws {
    var tracker = try F.bound()
    for i in 3...20 {
      try tracker.process(F.input(UInt64(i), Double(i) * 0.125, [F.candidate(2, x: 0.25)]))
    }
    let r = try tracker.process(F.input(21, 2.75,
      [F.candidate(3, x: 0.7), F.candidate(2, x: 0.25)]))
    #expect(r.player1.state == .lost && r.player1.candidateID == nil && r.player1.requiresRebind)
    // P1's evidence is no longer fresh enough to exclude it from P2's observation.
    #expect(r.player2.state == .uncertain && r.player2.requiresRebind)
    #expect(r.player2.candidateID == nil && r.player2.lastConfirmedAt == 1.125)
  }
  @Test func overflowCannotBeTreatedAsHarmlessDiscardedCandidates() throws {
    let eight = (0..<8).map { F.candidate(UInt64($0), x: 0.1 + Double($0) * 0.1) }
    var tracker = try F.bound()
    let r = try tracker.process(F.input(3, 0.25, eight, count: 12))
    #expect(r.player1.state == .uncertain && r.player2.state == .uncertain)
    #expect(r.player1.reason == .overflow && r.assignmentCount == 0)
    var acquiring = try F.tracker()
    let refused = try acquiring.process(F.input(1, 0, eight, count: 9))
    #expect(refused.player1.state == .unbound && refused.provisionalDescriptorCount == 0)
  }
  @Test func globalAssignmentsIncludeUnmatchedAndStayWithin73Hypotheses() throws {
    var tracker = try F.bound(policy: F.policy(speed: 2, residual: 2))
    let eight = (0..<8).map { F.candidate(UInt64($0), x: 0.465 + Double($0) * 0.01) }
    // Acquisition stays narrow; a larger elapsed interval expands the matching gate only.
    let r = try tracker.process(F.input(3, 0.75, eight))
    #expect(r.assignmentCount == 73)
    #expect(r.player1.state == .lost && r.player2.state == .lost)
  }
  @Test func incompleteEvidenceCannotWinThroughMissingCostTerms() throws {
    var tracker = try F.bound(policy: F.policy(separation: 0.01, margin: 0.05))
    let r = try tracker.process(F.input(3, 0.25,
      [F.candidate(1, x: 0.81), F.candidate(2, x: 0.25),
        F.candidate(3, x: 0.75, missing: [.rightHip])]))
    #expect(r.player1.state == .tracking && r.player1.candidateID == 1)
    #expect(r.player1.cost! > 0 && r.player1.cost! < 0.6)
  }
  @Test func unmatchedAlternativeCanBeatAnIncompleteMatch() throws {
    var tracker = try F.bound(policy: F.policy(unmatched: 0.5, margin: 0.05))
    let r = try tracker.process(F.input(3, 0.25,
      [F.candidate(1, x: 0.75, missing: [.rightHip]), F.candidate(2, x: 0.25)]))
    #expect(r.player1.state == .uncertain && r.player1.candidateID == nil)
    #expect(r.player2.state == .tracking)
  }
  @Test func trueTiesAreNotBrokenByCandidateArrayIndex() throws {
    let candidates = [F.candidate(1, x: 0.70), F.candidate(2, x: 0.80), F.candidate(3, x: 0.25)]
    var a = try F.bound(), b = try F.bound()
    let ar = try a.process(F.input(3, 0.25, candidates))
    let br = try b.process(F.input(3, 0.25, candidates.reversed()))
    #expect(ar.player1.state == .uncertain && br.player1.state == .uncertain)
    #expect(ar.player1.candidateID == nil && br.player1.candidateID == nil)
    #expect(ar.player2.candidateID == 3 && br.player2.candidateID == 3)
  }
  @Test(arguments: [Double.nan, .infinity, -.infinity, -0.1, 0])
  func rejectsInvalidPositivePolicyValues(_ bad: Double) {
    #expect(throws: PlayerTrackingError.invalidPolicy) { try PlayerTracker(policy: F.policy(confidence: bad)) }
    #expect(throws: PlayerTrackingError.invalidPolicy) { try PlayerTracker(policy: F.policy(gap: bad)) }
    #expect(throws: PlayerTrackingError.invalidPolicy) { try PlayerTracker(policy: F.policy(missingPenalty: bad)) }
    #expect(throws: PlayerTrackingError.invalidPolicy) { try PlayerTracker(policy: F.policy(positionWeight: bad)) }
    #expect(throws: PlayerTrackingError.invalidPolicy) { try PlayerTracker(policy: F.policy(residual: bad)) }
    #expect(throws: PlayerTrackingError.invalidPolicy) { try PlayerTracker(policy: F.policy(speed: bad)) }
    #expect(throws: PlayerTrackingError.invalidPolicy) { try PlayerTracker(policy: F.policy(torso: bad)) }
    #expect(throws: PlayerTrackingError.invalidPolicy) { try PlayerTracker(policy: F.policy(separation: bad)) }
    #expect(throws: PlayerTrackingError.invalidPolicy) { try PlayerTracker(policy: F.policy(window: bad)) }
    #expect(throws: PlayerTrackingError.invalidPolicy) { try PlayerTracker(policy: F.policy(freshness: bad)) }
    #expect(throws: PlayerTrackingError.invalidPolicy) { try PlayerTracker(policy: F.policy(position: bad)) }
    #expect(throws: PlayerTrackingError.invalidPolicy) { try PlayerTracker(policy: F.policy(logScale: bad)) }
    #expect(throws: PlayerTrackingError.invalidPolicy) { try PlayerTracker(policy: F.policy(jointWeight: bad)) }
    #expect(throws: PlayerTrackingError.invalidPolicy) { try PlayerTracker(policy: F.policy(unmatched: bad)) }
    #expect(throws: PlayerTrackingError.invalidPolicy) { try PlayerTracker(policy: F.policy(margin: bad)) }
  }
  @Test func rejectsInconsistentOrInvalidPolicyWithoutProductionDefaults() {
    let invalid = [F.policy(confidence: 1.1), F.policy(guardFraction: 0.5),
      F.policy(acquisition: -1), F.policy(recovery: .nan), F.policy(window: 0.5),
      F.policy(freshness: 2), F.policy(recovery: 2), F.policy(shapeWeight: -1),
      F.policy(margin: 2), F.policy(coreCount: 2), F.policy(coreCount: 5),
      F.policy(speed: .greatestFiniteMagnitude, position: .greatestFiniteMagnitude)]
    for p in invalid {
      #expect(throws: PlayerTrackingError.invalidPolicy) { try PlayerTracker(policy: p) }
    }
  }
  @Test func irregularCaptureTimesDrivePredictionInsteadOfAssumedFPS() throws {
    var tracker = try F.bound()
    let r = try tracker.process(F.input(400, 0.625,
      [F.candidate(1, x: 0.78), F.candidate(2, x: 0.22)]))
    #expect(r.player1.state == .tracking && r.player2.state == .tracking)
    #expect(r.source?.frameID == 400 && r.source?.capturedAt == 0.625)
    #expect(try tracker.process(F.input(401, 1.75)).player1.state == .lost)
  }
  @Test(arguments: [0, 1, 2, 3, 4])
  func staleAndInvalidFramesAreTransactional(_ variant: Int) throws {
    let invalid = [F.input(2, 0.25), F.input(1, 0.375), F.input(3, 0.125),
      F.input(3, .nan), F.input(3, -.infinity)]
    var tracker = try F.bound()
    let before = tracker.snapshot
    #expect(throws: (any Error).self) { try tracker.process(invalid[variant]) }
    #expect(tracker.snapshot == before)
  }
  @Test(arguments: [0, 1, 2, 3, 4, 5])
  func mismatchedFrameAndSourceProvenanceCannotBorrowNewMetadata(_ variant: Int) throws {
    let contexts = [F.context(generation: UUID()), F.context(epoch: UUID()),
      F.context(geometry: 2), F.context(width: 720, height: 1280),
      F.context(rotation: 180), F.context()]
    var tracker = try F.bound()
    let value = F.input(3, 0.25, context: contexts[variant], revision: variant == 5 ? 2 : 1)
    let before = tracker.snapshot
    #expect(throws: (any Error).self) { try tracker.process(value) }
    #expect(tracker.snapshot == before)
  }
  @Test func frameEnvelopeAndCountValidationRejectsBeforeMutation() throws {
    var tracker = try F.bound()
    let source = F.source(3, 0.25)
    let wrongFrame = F.input(4, 0.5).frame
    let before = tracker.snapshot
    #expect(throws: PlayerTrackingError.incompatibleSource) {
      try tracker.process(.init(source: source, frame: wrongFrame, observationCount: 2))
    }
    #expect(throws: PlayerTrackingError.incompatibleSource) {
      try tracker.process(F.input(3, 0.25, count: 1))
    }
    #expect(tracker.snapshot == before)
  }
  @Test func exactSourceAndOriginalNormalizedValuesRemainUnchanged() throws {
    let context = F.context(rotation: 180)
    var tracker = try F.bound(context: context)
    let input = F.input(7, 0.5, context: context)
    let result = try tracker.process(input)
    #expect(result.source == input.source)
    #expect(result.source?.context.epoch == F.epoch)
    #expect(input.frame.candidates[0].joints[.leftShoulder]?.x == 0.7)
    #expect(input.frame.candidates[0].joints[.rightShoulder]?.x == 0.8)
  }
  @Test func aspectRatioChangesGeometricMetricWithoutMutatingInputCoordinates() throws {
    let wide = F.context(), square = F.context(width: 720, height: 720)
    var a = try F.bound(context: wide), b = try F.bound(context: square)
    let candidates = [F.candidate(1, x: 0.90), F.candidate(2, x: 0.25)]
    let ar = try a.process(F.input(3, 0.25, candidates, context: wide))
    let br = try b.process(F.input(3, 0.25, candidates, context: square))
    #expect(ar.player1.state == .uncertain) // 0.15 X * 16/9 exceeds the geometric gate.
    #expect(br.player1.state == .tracking)
    #expect(candidates[0].joints[.leftShoulder]?.x == 0.85)
  }
  @Test func noFrameExpiryInvalidatesWithoutFabricatingCameraObservation() throws {
    var tracker = try F.bound()
    let before = tracker.snapshot.source
    let r = try tracker.expire(at: 0.625, controlRevision: 1)
    #expect(r.source == before && r.evaluatedAt == 0.625)
    #expect(r.player1.state == .uncertain && r.player2.state == .uncertain)
    #expect(r.player1.candidateID == nil && r.player2.candidateID == nil)
    #expect(try tracker.expire(at: 2.125, controlRevision: 1).player1.state == .lost)
    let stopped = tracker.snapshot
    #expect(throws: PlayerTrackingError.invalidTime) { try tracker.expire(at: 1, controlRevision: 1) }
    #expect(throws: PlayerTrackingError.invalidTime) { try tracker.expire(at: .nan, controlRevision: 1) }
    #expect(tracker.snapshot == stopped)
  }
  @Test func contextResetClearsStateButSameGenerationCannotRebind() throws {
    var tracker = try F.bound()
    let next = F.context(epoch: UUID(), geometry: 2)
    try tracker.reset(context: next, controlRevision: 2)
    #expect(tracker.snapshot.source == nil && tracker.snapshot.confirmedDescriptorCount == 0)
    #expect(tracker.snapshot.player1.state == .unbound && tracker.snapshot.provisionalDescriptorCount == 0)
    #expect(throws: PlayerTrackingError.bindingRequiresNewGeneration) {
      try tracker.armBinding(controlRevision: 2)
    }
    #expect(throws: PlayerTrackingError.staleControl) { try tracker.process(F.input(3, 0.25)) }
  }
  @Test func newGenerationExternalAuthorizationAllowsFreshAtomicPair() throws {
    var tracker = try F.bound()
    try tracker.invalidate(controlRevision: 2)
    #expect(tracker.snapshot.source == nil && tracker.snapshot.player1.state == .unbound)
    let next = F.context(generation: UUID(), epoch: UUID(), geometry: 2, rotation: 180)
    try tracker.reset(context: next, controlRevision: 3)
    let unarmed = try tracker.process(F.input(1, 10, context: next, revision: 3))
    #expect(unarmed.player1.state == .unbound)
    try tracker.armBinding(controlRevision: 3)
    try tracker.process(F.input(2, 10.125, context: next, revision: 3))
    let rebound = try tracker.process(F.input(3, 10.25, context: next, revision: 3))
    #expect(rebound.player1.state == .tracking && rebound.player2.state == .tracking)
    #expect(rebound.source?.context == next && rebound.controlRevision == 3)
  }
  @Test func oldControlAndDelayedCompletionsCannotRestoreResetIdentity() throws {
    var tracker = try F.tracker()
    try tracker.process(F.input(1, 0))
    try tracker.reset(context: F.context(), controlRevision: 2)
    let before = tracker.snapshot
    #expect(throws: PlayerTrackingError.staleControl) { try tracker.process(F.input(2, 0.25)) }
    #expect(throws: PlayerTrackingError.staleControl) { try tracker.armBinding(controlRevision: 1) }
    #expect(throws: PlayerTrackingError.staleControl) { try tracker.expire(at: 1, controlRevision: 1) }
    #expect(throws: PlayerTrackingError.staleControl) {
      try tracker.reset(context: F.context(), controlRevision: 2)
    }
    #expect(tracker.snapshot == before)
    try tracker.armBinding(controlRevision: 2)
    #expect(try tracker.process(F.input(1, 0.25, revision: 2)).player1.state == .unbound)
  }
  @Test(arguments: [0, 1, 2, 3])
  func invalidContextReplacementLeavesExistingStateUntouched(_ variant: Int) throws {
    let contexts = [F.context(mirrored: true), F.context(rotation: 90),
      F.context(geometry: 0), F.context(width: 0)]
    var tracker = try F.bound()
    let before = tracker.snapshot
    #expect(throws: PlayerTrackingError.invalidContext) {
      try tracker.reset(context: contexts[variant], controlRevision: 2)
    }
    #expect(tracker.snapshot == before)
  }
  @Test func inferenceFailureDiffersFromZeroDetectionsButNeverProducesAConfidentPose() throws {
    var failed = try F.bound(), empty = try F.bound()
    let a = try failed.inferenceFailed(source: F.source(3, 0.25))
    let b = try empty.process(F.input(3, 0.25, []))
    #expect(a.player1.state == .uncertain && a.player1.reason == .inferenceFailed)
    #expect(b.player1.state == .uncertain && b.player1.reason == .missingOrWeak)
    #expect(a.source == b.source && a.player1.candidateID == nil && b.player1.candidateID == nil)
  }

  @Test func expiredPredictionDoesNotWidenForeverWhileRawFramesStillArrive() throws {
    var tracker = try F.bound()
    for i in 3...16 {
      let r = try tracker.process(F.input(UInt64(i), Double(i) * 0.125, []))
      #expect(r.player1.state == .uncertain && r.player1.candidateID == nil)
    }
    let expired = try tracker.process(F.input(17, 2.125, []))
    #expect(expired.player1.state == .lost && expired.player1.reason == .expired)
    #expect(try tracker.process(F.input(18, 2.25)).player1.state == .lost)
  }
  @Test func positiveZeroCoordinateIsEvidenceWhileMissingRemainsAbsent() throws {
    let raw = F.candidate(20, x: 0.05, y: 0.1)
    var points = raw.joints
    points[.leftHip] = PoseJoint(x: 0, y: 0, confidence: 0.9)
    let corner = PoseCandidate(candidateID: 20, joints: points,
      maskTopImageY: nil, maskBottomImageY: nil, leftFootBottomImageY: nil,
      rightFootBottomImageY: nil, maskAssociation: .unavailable)
    let pair = [F.candidate(10, x: 0.75), corner]
    var tracker = try F.bound(pair: pair)
    let r = try tracker.process(F.input(3, 0.25, pair))
    #expect(r.player2.state == .tracking && r.player2.candidateID == 20)
    #expect(points[.leftHip]?.x == 0 && points[.leftHip]?.y == 0)
    #expect(points[.leftAnkle] == nil)
  }
  @Test func malformedJointsAndExcessRetainedValuesAreRejectedTransactionally() throws {
    var tracker = try F.bound()
    let before = tracker.snapshot
    #expect(throws: (any Error).self) {
      try tracker.process(F.input(3, 0.25,
        [F.candidate(1, x: .nan), F.candidate(2, x: 0.25)]))
    }
    let nine = (0..<9).map { F.candidate(UInt64($0), x: 0.1 + Double($0) * 0.08) }
    #expect(throws: PlayerTrackingError.incompatibleSource) {
      try tracker.process(F.input(3, 0.25, nine))
    }
    #expect(tracker.snapshot == before)
  }
  @Test(arguments: [0, 1, 2, 3, 4])
  func explicitContextChangesClearAllHistoryAndDisarm(_ variant: Int) throws {
    let contexts = [F.context(generation: UUID()), F.context(epoch: UUID()),
      F.context(geometry: 2), F.context(width: 720, height: 720), F.context(rotation: 180)]
    var tracker = try F.bound()
    try tracker.reset(context: contexts[variant], controlRevision: 2)
    #expect(tracker.snapshot.source == nil && tracker.snapshot.confirmedDescriptorCount == 0)
    #expect(tracker.snapshot.provisionalDescriptorCount == 0)
    let r = try tracker.process(F.input(3, 0.25, context: contexts[variant], revision: 2))
    #expect(r.player1.state == .unbound && r.player1.reason == .disarmed)
    #expect(throws: PlayerTrackingError.staleControl) { try tracker.process(F.input(4, 0.5)) }
  }

  @Test(arguments: [false, true])
  func lostIdentityStillExcludesItsBodyFromOtherPlayer(_ mirrored: Bool) throws {
    let policy = F.policy(gap: 0.5, window: 0.5)
    var tracker = try F.duplicateNearCenter(mirrored: mirrored, policy: policy)
    let excluded: PlayerID = mirrored ? .player2 : .player1
    let other: PlayerID = mirrored ? .player1 : .player2
    for (id, time) in [(UInt64(12), 1.375), (13, 1.5)] {
      let r = try tracker.process(F.input(id, time,
        [F.candidate(10, x: 0.55), F.candidate(20, x: 0.45)]))
      #expect(r[other].state == .tracking)
      #expect(r[other].candidateID == (mirrored ? 10 : 20))
    }
    let expired = try tracker.expire(at: 1.625, controlRevision: 1)
    #expect(expired[excluded].state == .lost && expired[excluded].requiresRebind)
    #expect(expired[other].state == .tracking)
    let remaining = mirrored ? F.candidate(90, x: 0.45) : F.candidate(90, x: 0.55)
    let r = try tracker.process(F.input(14, 1.625, [remaining]))
    #expect(r[excluded].state == .lost && r[excluded].candidateID == nil)
    // The ghost identity wins the explanation uniquely; P2 is missing, not reacquired or guessed.
    #expect(r[other].state == .uncertain && !r[other].requiresRebind)
    #expect(r[other].reason == .missingOrWeak)
    #expect(r[other].candidateID == nil && r[other].lastConfirmedAt == 1.5)
    let stale = try tracker.process(F.input(15, 1.75, [remaining]))
    #expect(stale[excluded].state == .lost && stale[excluded].requiresRebind)
    #expect(stale[other].state == .uncertain && stale[other].requiresRebind)
    #expect(stale[other].candidateID == nil && stale[other].lastConfirmedAt == 1.5)
  }
  @Test(arguments: [false, true])
  func distinctOtherBodySurvivesDespiteFreshExcludedIdentityAndDistantExtra(_ mirrored: Bool) throws {
    var tracker = try F.duplicateNearCenter(mirrored: mirrored)
    let excluded: PlayerID = mirrored ? .player2 : .player1
    let other: PlayerID = mirrored ? .player1 : .player2
    // The excluded person's body is explained separately from the healthy person's unique body.
    // Changing IDs, array order and a distant extra never become identity evidence.
    let first = try tracker.process(F.input(12, 1.375,
      [F.candidate(81, x: 0.45), F.candidate(55, x: 0.9), F.candidate(19, x: 0.55)]))
    #expect(first[excluded].state == .uncertain && first[excluded].requiresRebind)
    #expect(first[excluded].candidateID == nil && first[excluded].lastConfirmedAt == 1.125)
    #expect(first[other].state == .tracking && !first[other].requiresRebind)
    #expect(first[other].candidateID == (mirrored ? 19 : 81) && first[other].lastConfirmedAt == 1.375)
  }
  @Test(arguments: [false, true])
  func competitorDisappearanceDoesNotRestoreWrongIdentity(_ mirrored: Bool) throws {
    var tracker = try F.duplicateNearCenter(mirrored: mirrored)
    let excluded: PlayerID = mirrored ? .player2 : .player1
    let other: PlayerID = mirrored ? .player1 : .player2
    for id in 12...20 {
      let time = 1.375 + Double(id - 12) * 0.125
      let body = F.candidate(UInt64(100 - id), x: mirrored ? 0.45 : 0.55)
      let r = try tracker.process(F.input(UInt64(id), time, [body]))
      #expect(r[other].state == .uncertain || r[other].state == .lost)
      #expect(r[other].candidateID == nil && r[other].lastConfirmedAt == 1.25)
      #expect(r[excluded].candidateID == nil && r[excluded].requiresRebind)
      #expect(r[excluded].lastConfirmedAt == 1.125)
    }
    #expect(tracker.snapshot[other].requiresRebind)
  }

  @Test func lowerCostPositiveMatchCannotEraseExcludedButPlausibleOtherIdentity() throws {
    let pair = [F.candidate(10, x: 0.55), F.candidate(20, x: 0.45)]
    var tracker = try F.bound(pair: pair)
    let duplicate = try tracker.process(F.input(3, 0.25,
      pair + [F.candidate(30, x: 0.551)]))
    #expect(duplicate.player1.requiresRebind && duplicate.player2.state == .tracking)
    // P2's unchanged position costs zero, but the forbidden P1 identity still plausibly explains it.
    // No separately explained P1 body is present. A cost advantage alone is not exclusion proof.
    let r = try tracker.process(F.input(4, 0.375, [F.candidate(90, x: 0.45)]))
    #expect(r.player1.state == .uncertain && r.player1.requiresRebind)
    #expect(r.player2.state == .uncertain && r.player2.reason == .ambiguous)
    #expect(r.player2.requiresRebind && r.player2.candidateID == nil)
    #expect(r.player2.lastConfirmedAt == 0.25)
  }
  @Test func independentlyExplainedExcludedBodyAllowsHealthyMatchInsideBothMotionGates() throws {
    let pair = [F.candidate(10, x: 0.55), F.candidate(20, x: 0.45)]
    var tracker = try F.bound(pair: pair)
    try tracker.process(F.input(3, 0.25, pair + [F.candidate(30, x: 0.551)]))
    let r = try tracker.process(F.input(4, 0.375,
      [F.candidate(90, x: 0.45), F.candidate(80, x: 0.55)]))
    #expect(r.player1.state == .uncertain && r.player1.requiresRebind && r.player1.candidateID == nil)
    #expect(r.player1.lastConfirmedAt == 0.125)
    #expect(r.player2.state == .tracking && !r.player2.requiresRebind)
    #expect(r.player2.candidateID == 90 && r.player2.lastConfirmedAt == 0.375)
  }
  @Test func expiredCompetitorIsUnknownRatherThanEvidenceOfAbsence() throws {
    var tracker = try F.bound()
    for id in 3...9 {
      let r = try tracker.process(F.input(UInt64(id), Double(id) * 0.125,
        [F.candidate(20, x: 0.25)]))
      #expect(r.player2.state == .tracking && !r.player2.requiresRebind)
    }
    let before = tracker.snapshot.player2.lastConfirmedAt
    // P1 last confirmed at .125; at 1.25 its prediction evidence has expired (> 1 second).
    let r = try tracker.process(F.input(10, 1.25, [F.candidate(20, x: 0.25)]))
    #expect(r.player2.state == .uncertain && r.player2.reason == .ambiguous)
    #expect(r.player2.requiresRebind && r.player2.candidateID == nil)
    #expect(r.player2.lastConfirmedAt == before)
    let next = try tracker.process(F.input(11, 1.375))
    #expect(next.player2.state == .uncertain && next.player2.requiresRebind)
    #expect(next.player2.lastConfirmedAt == before && next.player2.candidateID == nil)
  }
  @Test func incomparableCompetitorTorsoCannotBePricedAsHarmlessMissingGeometry() throws {
    var tracker = try F.bound()
    try tracker.process(F.input(3, 0.25,
      [F.candidate(10, x: 0.75, missing: [.leftHip]), F.candidate(20, x: 0.25)]))
    let r = try tracker.process(F.input(4, 0.375,
      [F.candidate(10, x: 0.75, missing: [.rightHip]),
        F.candidate(20, x: 0.25, missing: [.rightHip])]))
    // P1's previous three-joint anchor and this P2 candidate share only two joints.
    #expect(r.player2.state == .uncertain && r.player2.requiresRebind)
    #expect(r.player2.reason == .ambiguous && r.player2.candidateID == nil)
    #expect(r.player2.lastConfirmedAt == 0.25)
  }
  @Test func resetClearsExclusionEvidenceOnlyWithNewGenerationAuthorization() throws {
    var tracker = try F.duplicateNearCenter(mirrored: false)
    try tracker.process(F.input(12, 1.375, [F.candidate(10, x: 0.55)]))
    let next = F.context(generation: UUID(), epoch: UUID(), geometry: 2)
    try tracker.reset(context: next, controlRevision: 2)
    #expect(tracker.snapshot.confirmedDescriptorCount == 0)
    #expect(tracker.snapshot.player1.state == .unbound && !tracker.snapshot.player1.requiresRebind)
    #expect(tracker.snapshot.player2.state == .unbound && !tracker.snapshot.player2.requiresRebind)
    #expect(tracker.snapshot.player1.lastConfirmedAt == nil && tracker.snapshot.player2.lastConfirmedAt == nil)
    try tracker.armBinding(controlRevision: 2)
    try tracker.process(F.input(1, 5, context: next, revision: 2))
    let r = try tracker.process(F.input(2, 5.125, context: next, revision: 2))
    #expect(r.player1.state == .tracking && r.player2.state == .tracking)
    #expect(r.player1.candidateID == 10 && r.player2.candidateID == 20)
    #expect(r.player1.lastConfirmedAt == 5.125 && r.player2.lastConfirmedAt == 5.125)
    let before = tracker.snapshot
    #expect(throws: PlayerTrackingError.staleControl) { try tracker.process(F.input(13, 1.5)) }
    #expect(tracker.snapshot == before)
  }
  @Test func overflowAndThirdPartyNeverEraseExcludedIdentityEvidence() throws {
    var tracker = try F.duplicateNearCenter(mirrored: false)
    let eight = (0..<8).map { F.candidate(UInt64($0), x: 0.1 + Double($0) * 0.1) }
    let overflow = try tracker.process(F.input(12, 1.375, eight, count: 11))
    #expect(overflow.player1.requiresRebind && overflow.player1.candidateID == nil)
    #expect(overflow.player1.lastConfirmedAt == 1.125 && overflow.player2.lastConfirmedAt == 1.25)
    let r = try tracker.process(F.input(13, 1.5,
      [F.candidate(77, x: 0.55), F.candidate(78, x: 0.9)]))
    #expect(r.player1.requiresRebind && r.player1.candidateID == nil)
    #expect(r.player2.state != .tracking && r.player2.candidateID == nil)
    #expect(r.player2.lastConfirmedAt == 1.25)
  }
  @Test func longExcludedSequencesKeepFiniteStateWithoutLearningRefusedBodies() throws {
    var a = try F.duplicateNearCenter(mirrored: false)
    var b = try F.duplicateNearCenter(mirrored: false)
    for id in 12...1000 {
      let input = F.input(UInt64(id), 1.375 + Double(id - 12) * 0.125,
        [F.candidate(UInt64(id % 3), x: 0.55)])
      let ar = try a.process(input), br = try b.process(input)
      #expect(ar == br)
      #expect(ar.player1.candidateID == nil && ar.player2.candidateID == nil)
      #expect(ar.player1.lastConfirmedAt == 1.125 && ar.player2.lastConfirmedAt == 1.25)
      #expect(ar.confirmedDescriptorCount <= 4 && ar.provisionalDescriptorCount <= 2)
      #expect(ar.assignmentCount <= 73)
    }
    #expect(a.snapshot.player1.state == .lost && a.snapshot.player2.state == .lost)
  }

  @Test(arguments: [false, true])
  func sameFrameNewAmbiguityMustVetoOtherConfirmation(_ mirrored: Bool) throws {
    let policy = F.policy(unmatched: 0.5, margin: 0.15)
    let pair = [F.candidate(10, x: 0.55), F.candidate(20, x: 0.45)]
    var tracker = try F.bound(policy: policy, pair: pair)
    let affected: PlayerID = mirrored ? .player2 : .player1
    let other: PlayerID = mirrored ? .player1 : .player2
    let x = mirrored ? 0.45 : 0.55
    let scene = [F.candidate(30, x: x, missing: [.leftHip]),
      F.candidate(40, x: x + (mirrored ? -0.001 : 0.001), missing: [.leftHip]),
      F.candidate(90, x: mirrored ? 0.55 : 0.45)]
    let r = try tracker.process(F.input(3, 0.25, scene))
    #expect(r[affected].state == .uncertain && r[affected].reason == .ambiguous)
    #expect(r[affected].requiresRebind && r[affected].candidateID == nil)
    #expect(r[other].state == .uncertain && r[other].reason == .ambiguous)
    #expect(r[other].requiresRebind && r[other].candidateID == nil)
    #expect(r[affected].lastConfirmedAt == 0.125 && r[other].lastConfirmedAt == 0.125)
    #expect(r.confirmedDescriptorCount == 2 && r.provisionalDescriptorCount == 0)
  }


  @Test(arguments: [0.5, 0.6, 0.7], [false, true])
  func frameResolutionIsInvariantAcrossAllThreeCandidateOrders(_ unmatched: Double,
    mirrored: Bool) throws {
    let pair = [F.candidate(10, x: 0.55), F.candidate(20, x: 0.45)]
    let scene = F.partialAmbiguityScene(mirrored: mirrored)
    for order in F.threeCandidateOrders {
      var tracker = try F.bound(policy: F.policy(unmatched: unmatched), pair: pair)
      let r = try tracker.process(F.input(3, 0.25, order.map { scene[$0] }))
      for player in PlayerID.allCases {
        #expect(r[player].state == .uncertain && r[player].reason == .ambiguous)
        #expect(r[player].requiresRebind && r[player].candidateID == nil)
        #expect(r[player].lastConfirmedAt == 0.125)
      }
      #expect(r.confirmedDescriptorCount == 2 && r.provisionalDescriptorCount == 0)
    }
  }
  @Test(arguments: [(0.25, true), (0.3, true), (0.35, false)], [false, true])
  func missingCostRelationshipsNeverPermitSameFrameHistoryLeak(_ variant: (Double, Bool),
    mirrored: Bool) throws {
    let pair = [F.candidate(10, x: 0.55), F.candidate(20, x: 0.45)]
    var tracker = try F.bound(policy: F.policy(missingPenalty: variant.0, unmatched: 0.5), pair: pair)
    let affected: PlayerID = mirrored ? .player2 : .player1
    let other: PlayerID = mirrored ? .player1 : .player2
    let r = try tracker.process(F.input(3, 0.25, F.partialAmbiguityScene(mirrored: mirrored)))
    #expect(r[affected].state == .uncertain && r[affected].candidateID == nil)
    #expect(r[affected].requiresRebind == variant.1)
    #expect(r[other].state == .uncertain && r[other].reason == .ambiguous)
    #expect(r[other].requiresRebind && r[other].candidateID == nil)
    #expect(r[other].lastConfirmedAt == 0.125 && r[affected].lastConfirmedAt == 0.125)
  }
  @Test(arguments: [0.8, 2.0], [false, true])
  func ambiguityWithGuaranteedIndependentBodyDoesNotBlanketRejectBoth(_ unmatched: Double,
    mirrored: Bool) throws {
    let pair = [F.candidate(10, x: 0.55), F.candidate(20, x: 0.45)]
    var tracker = try F.bound(policy: F.policy(unmatched: unmatched), pair: pair)
    let affected: PlayerID = mirrored ? .player2 : .player1
    let other: PlayerID = mirrored ? .player1 : .player2
    let r = try tracker.process(F.input(3, 0.25, F.partialAmbiguityScene(mirrored: mirrored)))
    #expect(r[affected].state == .uncertain && r[affected].reason == .ambiguous)
    #expect(r[affected].requiresRebind && r[affected].candidateID == nil)
    #expect(r[affected].lastConfirmedAt == 0.125)
    #expect(r[other].state == .tracking && !r[other].requiresRebind)
    #expect(r[other].candidateID == 90 && r[other].lastConfirmedAt == 0.25)
  }
  @Test(arguments: [false, true])
  func sameFrameRefusalAlsoAppliesToPreviouslyRecoverableUncertainty(_ mirrored: Bool) throws {
    let pair = [F.candidate(10, x: 0.55), F.candidate(20, x: 0.45)]
    var tracker = try F.bound(policy: F.policy(unmatched: 0.5), pair: pair)
    let missing = try tracker.process(F.input(3, 0.25, []))
    #expect(!missing.player1.requiresRebind && !missing.player2.requiresRebind)
    let r = try tracker.process(F.input(4, 0.375, F.partialAmbiguityScene(mirrored: mirrored)))
    #expect(r.player1.state == .uncertain && r.player2.state == .uncertain)
    #expect(r.player1.requiresRebind && r.player2.requiresRebind)
    #expect(r.player1.candidateID == nil && r.player2.candidateID == nil)
    #expect(r.player1.lastConfirmedAt == 0.125 && r.player2.lastConfirmedAt == 0.125)
    #expect(r.provisionalDescriptorCount == 0)
  }
  @Test(arguments: [false, true])
  func newlyUnsafeFrameCannotMaturePendingRecoveryIntoConfirmation(_ mirrored: Bool) throws {
    let pair = [F.candidate(10, x: 0.55), F.candidate(20, x: 0.45)]
    var tracker = try F.bound(policy: F.policy(unmatched: 0.5), pair: pair)
    try tracker.process(F.input(3, 0.25, []))
    let pending = try tracker.process(F.input(4, 0.375, pair))
    #expect(pending.player1.reason == .recovering && pending.player2.reason == .recovering)
    #expect(pending.provisionalDescriptorCount == 2)
    let r = try tracker.process(F.input(5, 0.5, F.partialAmbiguityScene(mirrored: mirrored)))
    #expect(r.player1.state == .uncertain && r.player2.state == .uncertain)
    #expect(r.player1.requiresRebind && r.player2.requiresRebind)
    #expect(r.player1.candidateID == nil && r.player2.candidateID == nil)
    #expect(r.player1.lastConfirmedAt == 0.125 && r.player2.lastConfirmedAt == 0.125)
    #expect(r.provisionalDescriptorCount == 0)
  }
  @Test func circularIndependentBodyExplanationWithUnknownReverseEdgeRefusesBoth() throws {
    let pair = [F.candidate(10, x: 0.55), F.candidate(20, x: 0.45)]
    var tracker = try F.bound(pair: pair)
    try tracker.process(F.input(3, 0.25,
      [F.candidate(10, x: 0.55, missing: [.leftHip]), F.candidate(20, x: 0.45)]))
    let r = try tracker.process(F.input(4, 0.375,
      [F.candidate(10, x: 0.55), F.candidate(20, x: 0.45, missing: [.rightHip])]))
    for player in PlayerID.allCases {
      #expect(r[player].state == .uncertain && r[player].reason == .ambiguous)
      #expect(r[player].requiresRebind && r[player].candidateID == nil)
      #expect(r[player].lastConfirmedAt == 0.25)
    }
    #expect(r.confirmedDescriptorCount == 4 && r.provisionalDescriptorCount == 0)
  }
  @Test func unknownCrossComparisonOnlyRefusesAffectedSideWhenOtherIsExcludedGeometrically() throws {
    var tracker = try F.bound()
    try tracker.process(F.input(3, 0.25,
      [F.candidate(10, x: 0.75, missing: [.leftHip]), F.candidate(20, x: 0.25)]))
    let r = try tracker.process(F.input(4, 0.375,
      [F.candidate(10, x: 0.75), F.candidate(20, x: 0.25, missing: [.rightHip])]))
    #expect(r.player1.state == .tracking && !r.player1.requiresRebind)
    #expect(r.player1.candidateID == 10 && r.player1.lastConfirmedAt == 0.375)
    #expect(r.player2.state == .uncertain && r.player2.requiresRebind)
    #expect(r.player2.candidateID == nil && r.player2.lastConfirmedAt == 0.25)
  }
  @Test func newFrameLatchesClearOnlyThroughAuthorizedNewGenerationReset() throws {
    let pair = [F.candidate(10, x: 0.55), F.candidate(20, x: 0.45)]
    var tracker = try F.bound(policy: F.policy(unmatched: 0.5), pair: pair)
    try tracker.process(F.input(3, 0.25, F.partialAmbiguityScene(mirrored: false)))
    #expect(tracker.snapshot.player1.requiresRebind && tracker.snapshot.player2.requiresRebind)
    let context = F.context(generation: UUID(), epoch: UUID(), geometry: 2)
    try tracker.reset(context: context, controlRevision: 2)
    #expect(tracker.snapshot.confirmedDescriptorCount == 0)
    #expect(!tracker.snapshot.player1.requiresRebind && !tracker.snapshot.player2.requiresRebind)
    #expect(try tracker.process(F.input(1, 5, pair, context: context, revision: 2)).player1.state == .unbound)
    try tracker.armBinding(controlRevision: 2)
    try tracker.process(F.input(2, 5.125, pair, context: context, revision: 2))
    let r = try tracker.process(F.input(3, 5.25, pair, context: context, revision: 2))
    #expect(r.player1.state == .tracking && r.player2.state == .tracking)
    #expect(r.player1.lastConfirmedAt == 5.25 && r.player2.lastConfirmedAt == 5.25)
    let before = tracker.snapshot
    #expect(throws: PlayerTrackingError.staleControl) {
      try tracker.process(F.input(4, 0.375, F.partialAmbiguityScene(mirrored: true)))
    }
    #expect(tracker.snapshot == before)
  }
  @Test func repeatedFrameAmbiguityCannotAdvanceHistoryAndRemainsBounded() throws {
    let pair = [F.candidate(10, x: 0.55), F.candidate(20, x: 0.45)]
    var a = try F.bound(policy: F.policy(unmatched: 0.5), pair: pair)
    var b = try F.bound(policy: F.policy(unmatched: 0.5), pair: pair)
    let scene = F.partialAmbiguityScene(mirrored: false)
    for id in 3...1000 {
      let time = Double(id - 1) * 0.125
      let order = F.threeCandidateOrders[id % 6]
      let ar = try a.process(F.input(UInt64(id), time, order.map { scene[$0] }))
      let br = try b.process(F.input(UInt64(id), time, scene))
      #expect(ar == br)
      #expect(ar.player1.candidateID == nil && ar.player2.candidateID == nil)
      #expect(ar.player1.requiresRebind && ar.player2.requiresRebind)
      #expect(ar.player1.lastConfirmedAt == 0.125 && ar.player2.lastConfirmedAt == 0.125)
      #expect(ar.confirmedDescriptorCount == 2 && ar.provisionalDescriptorCount == 0)
      #expect(ar.assignmentCount <= 73)
    }
    #expect(a.snapshot.player1.state == .lost && a.snapshot.player2.state == .lost)
  }

  @Test(arguments: [false, true])
  func coherentShouldersCannotProveOppositeTorsoIndependence(_ mirrored: Bool) throws {
    let idPairs: [[UInt64]] = [[30, 40], [10, 20], [90, 2]]
    for ids in idPairs {
      let scene = F.coherentShouldersOppositeTorso(mirrored: mirrored, ids: ids)
      for order in [[0, 1], [1, 0]] {
        var tracker = try F.bound(pair: F.opposingBindingPair(mirrored: mirrored))
        let r = try tracker.process(F.input(3, 0.25, order.map { scene[$0] }))
        for player in PlayerID.allCases {
          #expect(r[player].state == .uncertain && r[player].reason == .ambiguous)
          #expect(!r[player].requiresRebind && r[player].candidateID == nil)
          #expect(r[player].lastConfirmedAt == 0.125)
        }
        #expect(r.confirmedDescriptorCount == 2 && r.provisionalDescriptorCount == 0)
      }
    }
  }

  @Test(arguments: [false, true])
  func restoredOppositeTorsoRetainsGlobalIdentityAmbiguity(_ mirrored: Bool) throws {
    let scene = F.coherentShouldersOppositeTorso(mirrored: mirrored, restored: true)
    for order in [[0, 1], [1, 0]] {
      var tracker = try F.bound(pair: F.opposingBindingPair(mirrored: mirrored))
      let r = try tracker.process(F.input(3, 0.25, order.map { scene[$0] }))
      for player in PlayerID.allCases {
        #expect(r[player].state == .lost && r[player].reason == .ambiguous)
        #expect(r[player].requiresRebind && r[player].candidateID == nil)
        #expect(r[player].lastConfirmedAt == 0.125)
      }
      #expect(r.confirmedDescriptorCount == 2 && r.provisionalDescriptorCount == 0)
    }
  }

  @Test(arguments: [3, 4], [0, 1, 2])
  func mutualCoreCoverageHonorsConfiguredThreeAndFour(_ minimum: Int, _ variant: Int) throws {
    var tracker = try F.bound(policy: F.policy(coreCount: minimum))
    let firstMissing: [BodyJoint] = variant == 0 ? [] : [.leftHip]
    let secondMissing: [BodyJoint] = variant == 2 ? [.leftHip] : []
    let r = try tracker.process(F.input(3, 0.25,
      [F.candidate(30, x: 0.75, missing: firstMissing),
        F.candidate(40, x: 0.25, missing: secondMissing)]))
    let firstSupported = minimum == 3 || variant == 0
    let secondSupported = minimum == 3 || variant != 2
    for (player, supported, id) in [(PlayerID.player1, firstSupported, UInt64(30)),
      (.player2, secondSupported, UInt64(40))] {
      #expect(r[player].state == (supported ? .tracking : .uncertain))
      #expect(r[player].candidateID == (supported ? id : nil))
      #expect(r[player].lastConfirmedAt == (supported ? 0.25 : 0.125))
      #expect(!r[player].requiresRebind)
    }
    // At floor four, the valid full peer may continue while the partial identity refuses.
    #expect(r.provisionalDescriptorCount == 0)
  }

  @Test(arguments: [0, 1, 2, 3])
  func comparablePartialSeparationSupportsDifferentTranslationDirections(_ direction: Int) throws {
    let heights = [(0.5, 0.5), (0.65, 0.35), (0.35, 0.65), (0.55, 0.45)]
    let pair = [F.candidate(10, x: 0.6, y: heights[direction].0),
      F.candidate(20, x: 0.4, y: heights[direction].1)]
    var tracker = try F.bound(pair: pair)
    let scene = [F.candidate(30, x: 0.6, y: heights[direction].0 + 0.01, missing: [.leftHip]),
      F.candidate(40, x: 0.4, y: heights[direction].1 - 0.01, missing: [.leftHip])]
    let r = try tracker.process(F.input(3, 0.25, scene.reversed()))
    #expect(r.player1.state == .tracking && r.player1.candidateID == 30)
    #expect(r.player2.state == .tracking && r.player2.candidateID == 40)
    #expect(r.player1.lastConfirmedAt == 0.25 && r.player2.lastConfirmedAt == 0.25)
    #expect(!r.player1.requiresRebind && !r.player2.requiresRebind)
  }

  @Test(arguments: [BodyJoint.leftHip, .rightHip, .leftShoulder, .rightShoulder])
  func droppingMutualSupportCannotCreateIndependentPair(_ firstMissing: BodyJoint) throws {
    let baseline = try F.bound()
    for secondMissing in [BodyJoint.leftHip, .rightHip, .leftShoulder, .rightShoulder]
      where firstMissing != secondMissing {
      var richer = baseline, poorer = baseline
      let first = F.candidate(30, x: 0.75, missing: [firstMissing])
      let supported = try richer.process(F.input(3, 0.25, [first, F.candidate(40, x: 0.25)]))
      #expect(supported.player1.state == .tracking && supported.player2.state == .tracking)
      // Only delete one observed joint from the second candidate: mutual coverage falls 3 -> 2.
      let refused = try poorer.process(F.input(3, 0.25,
        [first, F.candidate(40, x: 0.25, missing: [secondMissing])]))
      for player in PlayerID.allCases {
        #expect(refused[player].state == .uncertain && refused[player].reason == .ambiguous)
        #expect(!refused[player].requiresRebind && refused[player].candidateID == nil)
        #expect(refused[player].lastConfirmedAt == 0.125)
      }
      #expect(refused.confirmedDescriptorCount == 2 && refused.provisionalDescriptorCount == 0)
    }
  }

  @Test(arguments: [false, true])
  func repeatedBelowCoverageFramesFreezeHistoryThroughExpiry(_ mirrored: Bool) throws {
    var tracker = try F.bound(pair: F.opposingBindingPair(mirrored: mirrored))
    for id in 3...50 {
      let scene = F.coherentShouldersOppositeTorso(mirrored: mirrored,
        ids: [UInt64(id), UInt64(id + 100)])
      let r = try tracker.process(F.input(UInt64(id), Double(id - 1) * 0.125,
        id.isMultiple(of: 2) ? scene.reversed() : scene))
      for player in PlayerID.allCases {
        #expect(r[player].state == .uncertain || r[player].state == .lost)
        #expect(r[player].candidateID == nil && r[player].lastConfirmedAt == 0.125)
      }
      #expect(r.confirmedDescriptorCount == 2 && r.provisionalDescriptorCount == 0)
      #expect(r.assignmentCount <= 73)
    }
    #expect(tracker.snapshot.player1.state == .lost && tracker.snapshot.player2.state == .lost)
    let later = try tracker.process(F.input(51, 6.25, F.opposingBindingPair(mirrored: mirrored)))
    #expect(later.player1.state == .lost && later.player2.state == .lost)
    #expect(later.player1.candidateID == nil && later.player2.candidateID == nil)
  }

  @Test(arguments: [false, true])
  func unavailablePairRecoversOnlyAfterComparablePartialDwell(_ mirrored: Bool) throws {
    let pair = F.opposingBindingPair(mirrored: mirrored)
    var tracker = try F.bound(pair: pair)
    try tracker.process(F.input(3, 0.25, F.coherentShouldersOppositeTorso(mirrored: mirrored)))
    let comparable = pair.map { candidate in
      PoseCandidate(candidateID: candidate.candidateID,
        joints: candidate.joints.filter { $0.key != .leftHip }, maskTopImageY: nil,
        maskBottomImageY: nil, leftFootBottomImageY: nil, rightFootBottomImageY: nil,
        maskAssociation: .unavailable)
    }
    let pending = try tracker.process(F.input(4, 0.375, comparable))
    for player in PlayerID.allCases {
      #expect(pending[player].state == .uncertain && pending[player].reason == .recovering)
      #expect(pending[player].candidateID == nil && pending[player].lastConfirmedAt == 0.125)
    }
    #expect(pending.confirmedDescriptorCount == 2 && pending.provisionalDescriptorCount == 2)
    let r = try tracker.process(F.input(5, 0.5, comparable.reversed()))
    #expect(r.player1.state == .tracking && r.player1.candidateID == (mirrored ? 20 : 10))
    #expect(r.player2.state == .tracking && r.player2.candidateID == (mirrored ? 10 : 20))
    #expect(r.player1.lastConfirmedAt == 0.5 && r.player2.lastConfirmedAt == 0.5)
  }

  @Test(arguments: [false, true])
  func opposingPartialDisplacementsCannotConfirmIndependentBodies(_ mirrored: Bool) throws {
    let pair = F.opposingBindingPair(mirrored: mirrored)
    var tracker = try F.bound(pair: pair)
    let r = try tracker.process(F.input(3, 0.25, F.opposingDisplacements(mirrored: mirrored)))
    for player in PlayerID.allCases {
      #expect(r[player].state == .uncertain)
      #expect(r[player].reason == .ambiguous && !r[player].requiresRebind)
      #expect(r[player].candidateID == nil)
      #expect(r[player].lastConfirmedAt == 0.125)
    }
    #expect(r.confirmedDescriptorCount == 2 && r.provisionalDescriptorCount == 0)
  }

  @Test(arguments: [false, true])
  func restoringOpposingFixtureHipsRetainsSupportedOverlap(_ mirrored: Bool) throws {
    let pair = F.opposingBindingPair(mirrored: mirrored)
    var tracker = try F.bound(pair: pair)
    let r = try tracker.process(F.input(3, 0.25,
      F.opposingDisplacements(mirrored: mirrored, restored: true)))
    for player in PlayerID.allCases {
      #expect(r[player].state == .uncertain && r[player].requiresRebind)
      #expect(r[player].candidateID == nil && r[player].lastConfirmedAt == 0.125)
    }
    #expect(r.confirmedDescriptorCount == 2 && r.provisionalDescriptorCount == 0)
  }

  @Test(arguments: [false, true])
  func opposingPairsAreInvariantUnderCandidateOrderAndLocalIDs(_ mirrored: Bool) throws {
    let idPairs: [[UInt64]] = [[30, 40], [10, 20], [90, 2]]
    for ids in idPairs {
      for order in [[0, 1], [1, 0]] {
        var tracker = try F.bound(pair: F.opposingBindingPair(mirrored: mirrored))
        let scene = F.opposingDisplacements(mirrored: mirrored, ids: ids)
        let r = try tracker.process(F.input(3, 0.25, order.map { scene[$0] }))
        for player in PlayerID.allCases {
          #expect(r[player].state == .uncertain && r[player].reason == .ambiguous)
          #expect(!r[player].requiresRebind && r[player].candidateID == nil)
          #expect(r[player].lastConfirmedAt == 0.125)
        }
        #expect(r.confirmedDescriptorCount == 2 && r.provisionalDescriptorCount == 0)
      }
    }
  }

  @Test("Below-coverage coherent translation remains unavailable", arguments: [0, 1, 2, 3])
  func coherentPartialSeparationSupportsDifferentTranslationDirections(_ direction: Int) throws {
    let heights = [(0.5, 0.5), (0.65, 0.35), (0.35, 0.65), (0.55, 0.45)]
    let pair = [F.candidate(10, x: 0.6, y: heights[direction].0),
      F.candidate(20, x: 0.4, y: heights[direction].1)]
    var tracker = try F.bound(pair: pair)
    let scene = [F.candidate(30, x: 0.6, y: heights[direction].0 + 0.01, missing: [.leftHip]),
      F.candidate(40, x: 0.4, y: heights[direction].1 - 0.01, missing: [.rightHip])]
    let r = try tracker.process(F.input(3, 0.25, scene.reversed()))
    // WP-E01-P1/P2 explicitly approves revising this heuristic positive. Preserve its scenes.
    for player in PlayerID.allCases {
      #expect(r[player].state == .uncertain && r[player].reason == .ambiguous)
      #expect(!r[player].requiresRebind && r[player].candidateID == nil)
      #expect(r[player].lastConfirmedAt == 0.125)
    }
    #expect(r.confirmedDescriptorCount == 2 && r.provisionalDescriptorCount == 0)
  }

  @Test(arguments: [0.0, 0.01, 0.03, 0.06])
  func incompleteCancellationCannotBecomeIndependentTranslation(_ offset: Double) throws {
    var tracker = try F.bound(pair: F.opposingBindingPair(mirrored: false))
    let scene = F.opposingDisplacements()
    var joints = scene[0].joints
    joints[.rightShoulder] = .init(x: 0.64 + offset, y: 0.6, confidence: 0.9)
    let changed = PoseCandidate(candidateID: 30, joints: joints, maskTopImageY: nil,
      maskBottomImageY: nil, leftFootBottomImageY: nil, rightFootBottomImageY: nil,
      maskAssociation: .unavailable)
    let r = try tracker.process(F.input(3, 0.25, [changed, scene[1]]))
    for player in PlayerID.allCases {
      #expect(r[player].state == .uncertain && r[player].candidateID == nil)
      #expect(r[player].lastConfirmedAt == 0.125)
    }
    #expect(r.confirmedDescriptorCount == 2 && r.provisionalDescriptorCount == 0)
  }

  @Test(arguments: [0.3, 0.9])
  func largeMeanDisplacementStillNeedsSupportFromEverySharedJoint(_ shoulderY: Double) throws {
    var tracker = try F.bound(pair: F.opposingBindingPair(mirrored: false))
    let scene = F.opposingDisplacements()
    var joints = scene[1].joints
    // Mean displacement exceeds the gate, but the unchanged shoulder has zero projection
    // along that vertical mean. Neither mean magnitude nor individual magnitudes suffice.
    joints[.rightShoulder] = .init(x: 0.56, y: shoulderY, confidence: 0.9)
    let changed = PoseCandidate(candidateID: 40, joints: joints, maskTopImageY: nil,
      maskBottomImageY: nil, leftFootBottomImageY: nil, rightFootBottomImageY: nil,
      maskAssociation: .unavailable)
    let r = try tracker.process(F.input(3, 0.25, [scene[0], changed]))
    for player in PlayerID.allCases {
      #expect(r[player].state != .tracking && r[player].candidateID == nil)
      #expect(r[player].lastConfirmedAt == 0.125)
    }
    #expect(r.confirmedDescriptorCount == 2 && r.provisionalDescriptorCount == 0)
  }

  @Test(arguments: [false, true])
  func repeatedOpposingObservationsFreezeHistoryThroughExpiration(_ mirrored: Bool) throws {
    var tracker = try F.bound(pair: F.opposingBindingPair(mirrored: mirrored))
    for id in 3...50 {
      let scene = F.opposingDisplacements(mirrored: mirrored, ids: [UInt64(id), UInt64(id + 100)])
      let r = try tracker.process(F.input(UInt64(id), Double(id - 1) * 0.125,
        id.isMultiple(of: 2) ? scene.reversed() : scene))
      for player in PlayerID.allCases {
        #expect(r[player].state == .uncertain || r[player].state == .lost)
        #expect(r[player].candidateID == nil && r[player].lastConfirmedAt == 0.125)
      }
      #expect(r.confirmedDescriptorCount == 2 && r.provisionalDescriptorCount == 0)
      #expect(r.assignmentCount <= 73)
    }
    #expect(tracker.snapshot.player1.state == .lost && tracker.snapshot.player2.state == .lost)
  }

  @Test(arguments: [false, true])
  func opposingUncertaintyRecoversOnlyAfterSupportedSeparationAndDwell(_ mirrored: Bool) throws {
    let pair = F.opposingBindingPair(mirrored: mirrored)
    var tracker = try F.bound(pair: pair)
    try tracker.process(F.input(3, 0.25, F.opposingDisplacements(mirrored: mirrored)))
    let pending = try tracker.process(F.input(4, 0.375, pair))
    for player in PlayerID.allCases {
      #expect(pending[player].state == .uncertain && pending[player].reason == .recovering)
      #expect(pending[player].candidateID == nil && pending[player].lastConfirmedAt == 0.125)
    }
    #expect(pending.provisionalDescriptorCount == 2 && pending.confirmedDescriptorCount == 2)
    let r = try tracker.process(F.input(5, 0.5, pair.reversed()))
    #expect(r.player1.candidateID == (mirrored ? 20 : 10))
    #expect(r.player2.candidateID == (mirrored ? 10 : 20))
    #expect(r.player1.state == .tracking && r.player2.state == .tracking)
    #expect(r.player1.lastConfirmedAt == 0.5 && r.player2.lastConfirmedAt == 0.5)
  }

  @Test(arguments: [false, true])
  func complementaryPartialCandidatesCannotProveIndependentBodies(_ mirrored: Bool) throws {
    let pair = [F.candidate(10, x: 0.55), F.candidate(20, x: 0.45)]
    var tracker = try F.bound(pair: pair) // Unchanged default synthetic policy.
    let scene = [F.candidate(30, x: mirrored ? 0.49 : 0.51, missing: [.leftHip]),
      F.candidate(40, x: mirrored ? 0.51 : 0.49, missing: [.rightHip])]
    let r = try tracker.process(F.input(3, 0.25, scene))
    for player in PlayerID.allCases {
      #expect(r[player].state == .uncertain)
      #expect(r[player].candidateID == nil)
      #expect(r[player].lastConfirmedAt == 0.125)
    }
    #expect(r.confirmedDescriptorCount == 2 && r.provisionalDescriptorCount == 0)
  }

  @Test func inferenceFailureDuringAcquisitionReportsFailureAndClearsDwell() throws {
    var tracker = try F.tracker()
    let pending = try tracker.process(F.input(1, 0))
    #expect(pending.provisionalDescriptorCount == 2)
    let failed = try tracker.inferenceFailed(source: F.source(2, 0.0625))
    for player in PlayerID.allCases {
      #expect(failed[player].state == .unbound)
      #expect(failed[player].reason == .inferenceFailed)
      #expect(failed[player].candidateID == nil && failed[player].lastConfirmedAt == nil)
    }
    #expect(failed.provisionalDescriptorCount == 0 && failed.confirmedDescriptorCount == 0)
    #expect(try tracker.process(F.input(3, 0.125)).player1.state == .unbound)
    #expect(try tracker.process(F.input(4, 0.25)).player1.state == .tracking)
  }

  @Test(arguments: [false, true])
  func partialPairEvidenceIsPermutationAndIDInvariant(_ mirrored: Bool) throws {
    let pair = [F.candidate(10, x: 0.55), F.candidate(20, x: 0.45)]
    let idPairs: [[UInt64]] = [[30, 40], [90, 2], [10, 20]]
    for ids in idPairs {
      let scene = [F.candidate(ids[0], x: mirrored ? 0.49 : 0.51, missing: [.leftHip]),
        F.candidate(ids[1], x: mirrored ? 0.51 : 0.49, missing: [.rightHip])]
      for order in [[0, 1], [1, 0]] {
        var tracker = try F.bound(pair: pair)
        let r = try tracker.process(F.input(3, 0.25, order.map { scene[$0] }))
        for player in PlayerID.allCases {
          #expect(r[player].state == .uncertain && r[player].reason == .ambiguous)
          #expect(!r[player].requiresRebind && r[player].candidateID == nil)
          #expect(r[player].lastConfirmedAt == 0.125)
        }
        #expect(r.confirmedDescriptorCount == 2 && r.provisionalDescriptorCount == 0)
      }
    }
  }

  @Test(arguments: [0, 1, 2])
  func comparableNearCandidatesRetainDuplicateLatch(_ variant: Int) throws {
    let missing: [[BodyJoint]] = [[], [.leftHip], [.rightHip]]
    let pair = [F.candidate(10, x: 0.55), F.candidate(20, x: 0.45)]
    var tracker = try F.bound(pair: pair)
    let r = try tracker.process(F.input(3, 0.25,
      [F.candidate(30, x: 0.51, missing: missing[variant]),
        F.candidate(40, x: 0.49, missing: missing[variant])]))
    for player in PlayerID.allCases {
      #expect(r[player].state == .uncertain && r[player].requiresRebind)
      #expect(r[player].candidateID == nil && r[player].lastConfirmedAt == 0.125)
    }
    // Proven duplicate ambiguity stays latched even after full bodies separate again.
    let later = try tracker.process(F.input(4, 0.375, pair))
    #expect(later.player1.requiresRebind && later.player2.requiresRebind)
    #expect(later.player1.candidateID == nil && later.player2.candidateID == nil)
  }

  @Test(arguments: [BodyJoint.leftHip, .rightHip, .leftShoulder, .rightShoulder])
  func separatedPartialCoverageRemainsSupported(_ firstMissing: BodyJoint) throws {
    for secondMissing in [BodyJoint.leftHip, .rightHip, .leftShoulder, .rightShoulder] {
      var tracker = try F.bound()
      let r = try tracker.process(F.input(3, 0.25,
        [F.candidate(40, x: 0.25, missing: [secondMissing]),
          F.candidate(30, x: 0.75, missing: [firstMissing])]))
      // Approved Option A revision: keep all 16 scenes, but only the four same-missing
      // combinations have three mutual core joints. Distance cannot replace coverage.
      if secondMissing == firstMissing {
        #expect(r.player1.state == .tracking && r.player1.candidateID == 30)
        #expect(r.player2.state == .tracking && r.player2.candidateID == 40)
        #expect(!r.player1.requiresRebind && !r.player2.requiresRebind)
        #expect(r.player1.lastConfirmedAt == 0.25 && r.player2.lastConfirmedAt == 0.25)
      } else {
        for player in PlayerID.allCases {
          #expect(r[player].state == .uncertain && r[player].reason == .ambiguous)
          #expect(!r[player].requiresRebind && r[player].candidateID == nil)
          #expect(r[player].lastConfirmedAt == 0.125)
        }
        #expect(r.confirmedDescriptorCount == 2 && r.provisionalDescriptorCount == 0)
      }
    }
  }

  @Test(arguments: [BodyJoint.leftHip, .rightHip, .leftShoulder, .rightShoulder])
  func unknownPartialCoverageDoesNotLatchOrConfirm(_ firstMissing: BodyJoint) throws {
    let pair = [F.candidate(10, x: 0.55), F.candidate(20, x: 0.45)]
    for secondMissing in [BodyJoint.leftHip, .rightHip, .leftShoulder, .rightShoulder]
      where secondMissing != firstMissing {
      var tracker = try F.bound(pair: pair)
      let r = try tracker.process(F.input(3, 0.25,
        [F.candidate(30, x: 0.51, missing: [firstMissing]),
          F.candidate(40, x: 0.49, missing: [secondMissing])]))
      for player in PlayerID.allCases {
        #expect(r[player].state == .uncertain && r[player].reason == .ambiguous)
        #expect(!r[player].requiresRebind && r[player].candidateID == nil)
        #expect(r[player].lastConfirmedAt == 0.125)
      }
      #expect(r.confirmedDescriptorCount == 2 && r.provisionalDescriptorCount == 0)
    }
  }

  @Test func oneSeparatedSharedJointCannotProvePartialBodiesDistinct() throws {
    let pair = [F.candidate(10, x: 0.55), F.candidate(20, x: 0.45)]
    var tracker = try F.bound(pair: pair)
    let left = F.candidate(30, x: 0.51, missing: [.leftHip])
    let raw = F.candidate(40, x: 0.49, missing: [.rightHip])
    var joints = raw.joints
    // Only one shared shoulder separates; the other stays near the competing observation.
    joints[.leftShoulder] = .init(x: 0.26, y: 0.6, confidence: 0.9)
    let right = PoseCandidate(candidateID: raw.candidateID, joints: joints,
      maskTopImageY: nil, maskBottomImageY: nil, leftFootBottomImageY: nil,
      rightFootBottomImageY: nil, maskAssociation: .unavailable)
    let r = try tracker.process(F.input(3, 0.25, [left, right]))
    for player in PlayerID.allCases {
      #expect(r[player].state == .uncertain && r[player].candidateID == nil)
      #expect(r[player].lastConfirmedAt == 0.125)
    }
    #expect(r.confirmedDescriptorCount == 2 && r.provisionalDescriptorCount == 0)
  }

  @Test(arguments: [false, true])
  func fullTorsoShapeExclusionPreservesIndependentOverlap(_ mirrored: Bool) throws {
    let firstLength = mirrored ? 0.32 : 0.18
    let secondLength = mirrored ? 0.18 : 0.32
    let pair = [F.candidate(10, x: 0.55, length: firstLength),
      F.candidate(20, x: 0.45, length: secondLength)]
    var tracker = try F.bound(pair: pair)
    let r = try tracker.process(F.input(3, 0.25,
      [F.candidate(40, x: 0.5, length: secondLength),
        F.candidate(30, x: 0.5, length: firstLength)]))
    #expect(r.player1.state == .tracking && r.player1.candidateID == 30)
    #expect(r.player2.state == .tracking && r.player2.candidateID == 40)
    #expect(!r.player1.requiresRebind && !r.player2.requiresRebind)
    #expect(r.player1.lastConfirmedAt == 0.25 && r.player2.lastConfirmedAt == 0.25)
  }

  @Test func unknownPairAllowsDwellRecoveryOnlyAfterSeparation() throws {
    let pair = [F.candidate(10, x: 0.55), F.candidate(20, x: 0.45)]
    var tracker = try F.bound(pair: pair)
    try tracker.process(F.input(3, 0.25,
      [F.candidate(30, x: 0.51, missing: [.leftHip]),
        F.candidate(40, x: 0.49, missing: [.rightHip])]))
    let pending = try tracker.process(F.input(4, 0.375, pair))
    #expect(pending.player1.reason == .recovering && pending.player2.reason == .recovering)
    #expect(pending.player1.candidateID == nil && pending.player2.candidateID == nil)
    #expect(pending.player1.lastConfirmedAt == 0.125 && pending.player2.lastConfirmedAt == 0.125)
    #expect(pending.provisionalDescriptorCount == 2)
    let recovered = try tracker.process(F.input(5, 0.5, pair))
    #expect(recovered.player1.state == .tracking && recovered.player1.candidateID == 10)
    #expect(recovered.player2.state == .tracking && recovered.player2.candidateID == 20)
    #expect(recovered.player1.lastConfirmedAt == 0.5 && recovered.player2.lastConfirmedAt == 0.5)
  }

  @Test(arguments: [false, true])
  func independentPlayerSurvivesComplementaryPartialCompetition(_ mirrored: Bool) throws {
    var tracker = try F.bound()
    let affected: PlayerID = mirrored ? .player2 : .player1
    let other: PlayerID = mirrored ? .player1 : .player2
    let x = mirrored ? 0.25 : 0.75
    let scene = [F.candidate(30, x: x, missing: [.leftHip]),
      F.candidate(40, x: x + (mirrored ? -0.001 : 0.001), missing: [.rightHip]),
      F.candidate(90, x: mirrored ? 0.75 : 0.25), F.candidate(99, x: 0.5)]
    let r = try tracker.process(F.input(3, 0.25, scene.reversed()))
    #expect(r[affected].state == .uncertain && r[affected].candidateID == nil)
    #expect(r[affected].lastConfirmedAt == 0.125)
    #expect(r[other].state == .tracking && r[other].candidateID == 90)
    #expect(!r[other].requiresRebind && r[other].lastConfirmedAt == 0.25)
  }

  @Test(arguments: [false, true])
  func repeatedUnknownPairsFreezeHistoryAndCannotResurrect(_ mirrored: Bool) throws {
    let pair = [F.candidate(10, x: 0.55), F.candidate(20, x: 0.45)]
    var tracker = try F.bound(pair: pair)
    for id in 3...50 {
      let scene = [F.candidate(UInt64(id), x: mirrored ? 0.49 : 0.51, missing: [.leftHip]),
        F.candidate(UInt64(id + 100), x: mirrored ? 0.51 : 0.49, missing: [.rightHip])]
      let r = try tracker.process(F.input(UInt64(id), Double(id - 1) * 0.125,
        id.isMultiple(of: 2) ? scene.reversed() : scene))
      for player in PlayerID.allCases {
        #expect(r[player].state == .uncertain || r[player].state == .lost)
        #expect(r[player].candidateID == nil && r[player].lastConfirmedAt == 0.125)
      }
      #expect(r.confirmedDescriptorCount == 2 && r.provisionalDescriptorCount == 0)
      #expect(r.assignmentCount <= 73)
    }
    let later = try tracker.process(F.input(51, 6.25, pair))
    #expect(later.player1.state == .lost && later.player2.state == .lost)
    #expect(later.player1.candidateID == nil && later.player2.candidateID == nil)
  }

  @Test func unknownPairResetRequiresOriginalControlAndNewGeneration() throws {
    let pair = [F.candidate(10, x: 0.55), F.candidate(20, x: 0.45)]
    var tracker = try F.bound(pair: pair)
    let old = F.input(3, 0.25,
      [F.candidate(30, x: 0.51, missing: [.leftHip]),
        F.candidate(40, x: 0.49, missing: [.rightHip])])
    try tracker.process(old)
    let next = F.context(generation: UUID(), epoch: UUID())
    try tracker.reset(context: next, controlRevision: 2)
    let before = tracker.snapshot
    #expect(throws: PlayerTrackingError.staleControl) { try tracker.process(old) }
    #expect(tracker.snapshot == before && before.confirmedDescriptorCount == 0)
    try tracker.armBinding(controlRevision: 2)
    try tracker.process(F.input(1, 5, pair, context: next, revision: 2))
    let rebound = try tracker.process(F.input(2, 5.125, pair, context: next, revision: 2))
    #expect(rebound.player1.state == .tracking && rebound.player2.state == .tracking)
  }

  @Test func longDeterministicSequencesKeepBoundedHistoriesAndRepeatExactly() throws {
    var a = try F.bound(), b = try F.bound()
    for i in 3...5000 {
      let time = Double(i) * 0.125
      let candidates = i.isMultiple(of: 2) ? F.pair : F.pair.reversed()
      let input = F.input(UInt64(i), time, candidates)
      let ar = try a.process(input), br = try b.process(input)
      #expect(ar == br)
      #expect(ar.player1.candidateID == 10 && ar.player2.candidateID == 20)
      #expect(ar.confirmedDescriptorCount <= 4 && ar.provisionalDescriptorCount <= 2)
      #expect(ar.assignmentCount <= 73)
    }
    try a.invalidate(controlRevision: 2)
    #expect(a.snapshot.confirmedDescriptorCount == 0 && a.snapshot.provisionalDescriptorCount == 0)
  }
}
