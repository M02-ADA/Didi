import Foundation
import Testing
@testable import Sedactive

/// Synthetic same-source fixtures through real association/collection. No physical acceptance.
nonisolated struct CoopCalibrationDiagnosticsTests {
  private func diagnosis(_ pose: CameraPoseResult, shared: Bool = false) -> MaskAssociationDiagnostics {
    let tracking = LiveVisionFixtures.association(pose, revision: 2)
    let labels: [UInt8] = [1, 2], bounds = [[0, 3, 0, 7], [4, 7, 0, 7]]
    func label(_ x: Int, _ y: Int) -> UInt8 { shared ? 1 : (x < 4 ? 1 : 2) }
    let result = PersonSegmenter.associate(pose: pose, association: tracking, labels: labels,
      bounds: bounds, width: 8, height: 8, labelAt: label)
    return PersonSegmenter.diagnoseAssociation(pose: pose, association: tracking, labels: labels,
      bounds: bounds, width: 8, height: 8, result: result, labelAt: label)
  }

  @Test func supportedPairReportsEachActualLabel() throws {
    let f = try TrackingIntegrationFixture()
    let d = diagnosis(try f.result(3, 0.25, LiveVisionFixtures.standingPair))
    #expect(d.global == "supported")
    #expect(d.players[.player1]?.label == 2 && d.players[.player2]?.label == 1)
  }

  @Test(arguments: [true, false]) func firstTorsoBlockerIdentifiesPlayerAndJoint(missing: Bool) throws {
    let f = try TrackingIntegrationFixture()
    let pair = LiveVisionFixtures.standingPair.map { c in
      guard c.candidateID == 20 else { return c }
      var j = c.joints
      if missing { j[.rightHip] = nil }
      else { j[.rightHip] = .init(x: 0.25, y: 0.5, confidence: 0.35) }
      return PoseCandidate(candidateID: c.candidateID, joints: j, maskTopImageY: nil,
        maskBottomImageY: nil, leftFootBottomImageY: nil, rightFootBottomImageY: nil, maskAssociation: .unavailable)
    }
    let d = diagnosis(try f.result(3, 0.25, pair))
    #expect(d.players[.player2]?.reason == (missing ? "torsoMissing" : "torsoLowConfidence"))
    #expect(d.players[.player2]?.joint == .rightHip)
    #expect(d.players[.player1]?.reason == "torsoSupportedPartnerRefused")
    #expect(d.global == "pairAssociationRefused", "Production pair requirement is unchanged")
  }

  @Test func sharedInstanceRemainsRefusedForBoth() throws {
    let f = try TrackingIntegrationFixture()
    let d = diagnosis(try f.result(3, 0.25, LiveVisionFixtures.standingPair), shared: true)
    #expect(d.global == "sharedInstanceLabel")
    #expect(d.players.values.allSatisfy { $0.reason == "sharedInstanceLabel" })
  }

  @Test func wrongOriginalFrameIsGlobalRefusal() throws {
    let f = try TrackingIntegrationFixture()
    let p = try f.result(3, 0.25, LiveVisionFixtures.standingPair)
    let other = try f.result(4, 0.5, LiveVisionFixtures.standingPair)
    let d = PersonSegmenter.diagnoseAssociation(pose: p, association: LiveVisionFixtures.association(other, revision: 2),
      labels: [1, 2], bounds: [[0, 3, 0, 7], [4, 7, 0, 7]], width: 8, height: 8, result: [:]) { _, _ in 0 }
    #expect(d.global == "contextOrRosterMismatch" && d.players.isEmpty)
  }

  private func sample(_ i: Int, missingP2: Bool = false, missingP1: Bool = false,
    session: inout CalibrationSession, f: TrackingIntegrationFixture, stamp: CalibrationAdmission) throws {
    let p = try f.result(UInt64(i + 3), 0.25 + Double(i) * 0.25, LiveVisionFixtures.standingPair)
    let admitted = session.beginSample(stamp, source: p.source, at: p.source.capturedAt)
    try #require(admitted)
    var mask = LiveVisionFixtures.withAnatomy(LiveVisionFixtures.mask(p), pose: p, revision: stamp.bindingRevision)
    if missingP2 { mask.anatomy[.player2] = nil }
    if missingP1 { mask.anatomy[.player1] = nil }
    session.observe(mask, pose: p, association: LiveVisionFixtures.association(p, revision: stamp.bindingRevision),
      stamp: stamp, at: p.source.capturedAt + 0.01)
  }

  @Test func independentAnatomyWindowsRecoverWithoutResettingOtherPlayer() throws {
    let (f, initial, stamp) = try LiveVisionFixtures.sessionFixture(); var session = initial
    for i in 0..<10 { try sample(i, missingP2: i < 3, session: &session, f: f, stamp: stamp) }
    #expect(session.players[.player1]?.samples == 10)
    #expect(session.players[.player2]?.samples == 7)
    #expect(session.candidate == nil, "Incomplete roster cannot be accepted")
    for i in 10..<13 { try sample(i, session: &session, f: f, stamp: stamp) }
    let c = try #require(session.candidate)
    #expect(c.acceptance == .stableEstimate && c.players.count == 2)
    #expect(c.players[.player1]?.anatomy?.quality == .experimental)
    #expect(session.progress.debugCurrent?.windows.count == 2)
  }

  @Test func currentMissingAnkleCannotBorrowPreviousSampleDiagnostics() throws {
    let (f, initial, stamp) = try LiveVisionFixtures.sessionFixture(); var session = initial
    try sample(0, session: &session, f: f, stamp: stamp)
    let pair = LiveVisionFixtures.standingPair.map { c in
      guard c.candidateID == 20 else { return c }
      var joints = c.joints; joints[.rightAnkle] = nil
      return PoseCandidate(candidateID: c.candidateID, joints: joints, maskTopImageY: nil,
        maskBottomImageY: nil, leftFootBottomImageY: nil, rightFootBottomImageY: nil, maskAssociation: .unavailable)
    }
    let pose = try f.result(4, 0.5, pair)
    let admitted = session.beginSample(stamp, source: pose.source, at: 0.5); try #require(admitted)
    session.observe(LiveVisionFixtures.mask(pose), pose: pose,
      association: LiveVisionFixtures.association(pose, revision: stamp.bindingRevision), stamp: stamp, at: 0.51)
    let d = try #require(session.players[.player2]?.last)
    #expect(d.frameID == 4 && d.source == pose.source)
    #expect(d.confidence[.rightAnkle] == 0 && d.bodyHeightPixels == nil)
    #expect(!d.crownSeen && !d.solesSeen && d.crownAboveNose == nil)
    #expect(session.players[.player2]?.samples == 1, "Transient refusal retains evidence without inventing a new sample")
  }

  @Test func expiredPlayerWindowCannotJoinLaterPartnersFreshCandidate() throws {
    let (f, initial, stamp) = try LiveVisionFixtures.sessionFixture(); var session = initial
    // P1 fills their window, then remains tracked but has no eligible anatomy for >10s.
    // P2 only obtains ten valid samples near the end of the SAME 30s request.
    for i in 0..<60 {
      try sample(i, missingP2: i < 50, missingP1: i >= 10, session: &session, f: f, stamp: stamp)
    }
    #expect(session.candidate == nil, "Old P1 readings must not borrow P2's later frame/candidate lifetime")
    #expect(session.players[.player1]?.samples == 0)
    #expect(session.players[.player2]?.samples == 10)
    for i in 60..<70 { try sample(i, session: &session, f: f, stamp: stamp) }
    #expect(session.candidate?.acceptance == .stableEstimate, "Both may complete after genuinely fresh P1 evidence recovers")
  }

  @Test func terminalTimeoutRetainsNumbersButNeverLiveProgressOrCandidate() throws {
    let (f, initial, stamp) = try LiveVisionFixtures.sessionFixture(); var session = initial
    try sample(0, missingP2: true, session: &session, f: f, stamp: stamp)
    session.expire(at: 31)
    let p = session.progress
    #expect(p.phase == .expired && p.players.isEmpty && p.candidate == nil && p.request == nil)
    #expect(p.debugCurrent == nil)
    #expect(p.debugLastAttempt?.players[.player1]?.samples == 1)
    #expect(p.debugLastAttempt?.players[.player2]?.latestIssue == .bodyNotFullyVisible)
    #expect(p.debugLastAttempt?.outcome.contains("expired") == true)
  }

  @Test func candidateExpiryDoesNotReviveAcceptedEvidence() throws {
    let (f, initial, stamp) = try LiveVisionFixtures.sessionFixture(); var session = initial
    for i in 0..<10 { try sample(i, session: &session, f: f, stamp: stamp) }
    let c = try #require(session.candidate)
    session.expire(at: c.expiresAt)
    #expect(session.phase == .expired && session.candidate == nil)
    #expect(session.progress.debugLastAttempt?.candidateExpiresAt == c.expiresAt)
  }

  @Test func newAttemptHasFreshCountersAndDoesNotExtendOldTicket() throws {
    let (f, initial, stamp) = try LiveVisionFixtures.sessionFixture(); var session = initial
    try sample(0, session: &session, f: f, stamp: stamp)
    let deadline = try #require(session.progress.debugCurrent?.deadline)
    _ = try session.request(id: stamp.request.id, source: f.context, revision: stamp.bindingRevision,
      bindingRequest: stamp.bindingRequest, at: 20)
    #expect(session.progress.debugCurrent?.deadline == deadline)
    session.invalidate("Explicit calibration cancel")
    let next = try session.request(id: UUID(), source: f.context, revision: stamp.bindingRevision,
      bindingRequest: stamp.bindingRequest, at: 21)
    #expect(next != stamp.request && session.players.isEmpty && session.candidate == nil)
    #expect(session.progress.debugLastAttempt?.request == stamp.request.id)
  }

  @Test func pairUncertaintyStillRestartsBothAndSessionResetDropsAllDiagnostics() throws {
    let (f, initial, stamp) = try LiveVisionFixtures.sessionFixture(); var session = initial
    try sample(0, session: &session, f: f, stamp: stamp)
    session.uncertain()
    #expect(session.count == 0 && session.phase == .waitingForReliablePair)
    #expect(session.players.values.allSatisfy { $0.samples == 0 })
    session.invalidate("Stop")
    session.resetForNewSession()
    #expect(session.progress.debugCurrent == nil && session.progress.debugLastAttempt == nil)
    #expect(session.players.isEmpty && session.candidate == nil)
  }

  @Test func originalSourceCutoverCannotAdmitNewEpochIntoOldRequest() throws {
    let (f, initial, stamp) = try LiveVisionFixtures.sessionFixture(); var session = initial
    let p = try f.result(3, 0.25, LiveVisionFixtures.standingPair,
      context: .init(generation: f.context.generation, epoch: UUID(), geometryRevision: 1))
    let admitted = session.beginSample(stamp, source: p.source, at: 0.25)
    #expect(!admitted)
    #expect(session.players.isEmpty && session.candidate == nil)
  }

  @Test func atomicConsumptionIsRecordedOnlyAfterAuthorityConsumes() throws {
    let (f, initial, stamp) = try LiveVisionFixtures.sessionFixture(); var session = initial
    for i in 0..<10 { try sample(i, session: &session, f: f, stamp: stamp) }
    #expect(session.phase == .candidateReady)
    session.consumed() // Real E05 calls this only after its full transaction succeeds.
    #expect(session.progress.debugLastAttempt?.outcome == "Atomic roster acceptance committed by E05")
    #expect(session.phase == .accepted && session.candidate == nil && session.progress.debugCurrent == nil)
  }
}
