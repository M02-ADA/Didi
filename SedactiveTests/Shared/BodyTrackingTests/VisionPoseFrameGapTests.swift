import Foundation
import Testing
@testable import Sedactive

nonisolated struct VisionPoseFrameGapTests {
  /// Kevin's exact stall/camera/render ordering, without the separately owned mascot renderer.
  @Test func kevinsCameraStallOrderingDoesNotPermanentlyEndPublication() throws {
    var f = try TrackingIntegrationFixture()
    let bridge = VisionNumericPoseBridge(gate:f.gate), lease = try bridge.attach()
    try f.bind()
    var nextFrame: UInt64 = 3
    var time = 0.25, delivered = 0
    for _ in 0..<4 {
      let p = try f.result(nextFrame,time,LiveVisionFixtures.standingPair)
      let stamp = try #require(f.gate.admit(p.source))
      try #require(try f.finish(p,stamp:stamp))
      f.gate.publishPresentation(p,admission:stamp,receipt:try #require(f.gate.snapshot.latest))
      if bridge.drain(lease)?.output != nil { delivered += 1 }
      time += 0.125; nextFrame += 1
    }
    let before = delivered
    time += 0.6; f.clock.time = time
    let expired = try #require(bridge.drain(lease))
    #expect(!expired.status.active && expired.resetAll && expired.output == nil)
    for _ in 0..<16 {
      let p = try f.result(nextFrame,time,LiveVisionFixtures.standingPair)
      f.clock.time = time
      let stamp = try #require(f.gate.admit(p.source))
      _ = bridge.drain(lease) // real render pump runs while this frame's Vision is in flight
      try #require(try f.finish(p,stamp:stamp))
      f.gate.publishPresentation(p,admission:stamp,receipt:try #require(f.gate.snapshot.latest))
      if let output = bridge.drain(lease)?.output {
        #expect(output.pose.frameID == nextFrame && output.pose.capturedAt == time)
        delivered += 1
      }
      time += 0.125;nextFrame += 1
    }
    #expect(delivered > before, "Fresh frames must resume delivery after the gap")
    #expect(f.gate.snapshot.latest?.player1.state == .tracking)
    #expect(f.gate.snapshot.acknowledgments == 1)
  }

  @Test(arguments:[0.499999,0.5,0.500001])
  func freshAdmissionSurvivesRepeatedDrainsAroundTheFreshnessBoundary(_ gap:Double) throws {
    var f = try TrackingIntegrationFixture()
    let bridge = VisionNumericPoseBridge(gate:f.gate), lease = try bridge.attach()
    try f.bind()
    let previous = try f.result(3,0.25,LiveVisionFixtures.standingPair)
    let initial = try #require(f.gate.admit(previous.source));try #require(try f.finish(previous,stamp:initial))
    f.gate.publishPresentation(previous,admission:initial,receipt:try #require(f.gate.snapshot.latest))
    _ = bridge.drain(lease)
    f.clock.time = 0.25 + gap
    let afterGap = try #require(bridge.drain(lease))
    #expect(afterGap.output == nil)
    #expect(afterGap.status.active == (gap < 0.5))
    let fresh = try f.result(4,f.clock.time,LiveVisionFixtures.standingPair)
    let stamp = try #require(f.gate.admit(fresh.source))
    for _ in 0..<3 {
      let inFlight = try #require(bridge.drain(lease))
      #expect(inFlight.status.active && inFlight.output == nil)
      #expect(inFlight.status.revision == stamp.presentationRevision)
    }
    try #require(try f.finish(fresh,stamp:stamp))
    f.gate.publishPresentation(fresh,admission:stamp,receipt:try #require(f.gate.snapshot.latest))
    let result = try #require(bridge.drain(lease)?.output)
    #expect(result.pose.frameID == 4 && result.tracking.source?.capturedAt == fresh.source.capturedAt)
  }

  private func published() throws -> (TrackingIntegrationFixture,VisionNumericPoseBridge,VisionPoseAttachment) {
    var f = try TrackingIntegrationFixture()
    let bridge = VisionNumericPoseBridge(gate:f.gate), lease = try bridge.attach()
    try f.bind()
    let p = try f.result(3,0.25,LiveVisionFixtures.standingPair)
    let stamp = try #require(f.gate.admit(p.source));try #require(try f.finish(p,stamp:stamp))
    f.gate.publishPresentation(p,admission:stamp,receipt:try #require(f.gate.snapshot.latest))
    _ = bridge.drain(lease)
    return (f,bridge,lease)
  }

  @Test(arguments:[0.499999,0.5,0.500001])
  func inFlightEpochStillExpiresAtTheUnchangedCaptureAge(_ age:Double) throws {
    let (f,bridge,lease) = try published()
    f.clock.time = 0.75;_ = bridge.drain(lease)
    let p = try f.result(4,0.75,LiveVisionFixtures.standingPair)
    _ = try #require(f.gate.admit(p.source))
    f.clock.time = 0.75 + age
    let out = try #require(bridge.drain(lease))
    #expect(out.status.active == (age < 0.5) && out.output == nil)
    if age >= 0.5 { #expect(out.resetAll) }
  }

  @Test func staleTransitionNeverCommitsOrBorrowsNewEpochAndFreshFramesRecoverByDwell() throws {
    var (f,bridge,lease) = try published()
    let stale = try f.result(4,0.375,LiveVisionFixtures.standingPair)
    let stamp = try #require(f.gate.admit(stale.source))
    let staged = try f.engine.staged(stale,admission:stamp)
    let before = f.engine.tracker.snapshot
    f.clock.time = 0.875;f.gate.expireDue(at:f.clock.time)
    var committed = false
    #expect(!f.gate.finish(staged,admission:stamp,source:stale.source,mutualCoreCount:4) { committed = true })
    f.gate.publishPresentation(stale,admission:stamp,receipt:staged.tracker.snapshot)
    #expect(!committed && f.engine.tracker.snapshot == before)
    let expired = try #require(bridge.drain(lease))
    #expect(!expired.status.active && expired.output == nil && expired.resetAll)
    for (id,time) in [(UInt64(5),1.0),(UInt64(6),1.125)] {
      let p = try f.result(id,time,LiveVisionFixtures.standingPair);f.clock.time = time
      let a = try #require(f.gate.admit(p.source))
      _ = bridge.drain(lease)
      try #require(try f.finish(p,stamp:a))
      f.gate.publishPresentation(p,admission:a,receipt:try #require(f.gate.snapshot.latest))
      let current = try #require(bridge.drain(lease)?.output)
      #expect(current.pose.frameID == id && current.presentationRevision != stamp.presentationRevision)
      #expect(current.tracking.player1.state == (id == 5 ? .uncertain : .tracking))
      if id == 5 { #expect(current.tracking.player1.lastConfirmedAt == 0.25) }
    }
    #expect(f.gate.snapshot.acknowledgments == 1)
  }

  @Test func sourceLossResumeIsDisarmedAndCannotReviveAnOldPose() throws {
    let (f,bridge,lease) = try published()
    let revision = f.gate.snapshot.revision
    f.gate.sourceLost(f.context)
    let lost = try #require(bridge.drain(lease))
    #expect(!lost.status.active && lost.output == nil && lost.resetAll)
    let revoked = f.gate.snapshot.revision
    #expect(revoked > revision)
    f.gate.resume(f.context)
    let p = try f.result(4,0.5,LiveVisionFixtures.standingPair);f.clock.time = 0.5
    let a = try #require(f.gate.admit(p.source))
    #expect(a.requestID == nil && f.gate.snapshot.revision == revoked)
    let resumed = try #require(bridge.drain(lease))
    #expect(!resumed.status.active && resumed.output == nil)
    #expect(f.gate.snapshot.acknowledgment == nil)
  }

  @Test func recoveryWindowExpiryCannotTurnFreshNumericBodiesIntoReboundIdentity() throws {
    var (f,bridge,lease) = try published()
    f.clock.time = 2.25;f.gate.expireDue(at:2.25);f.synchronize()
    #expect(f.engine.tracker.snapshot.player1.requiresRebind)
    for (id,time) in [(UInt64(4),2.375),(UInt64(5),2.5)] {
      f.clock.time = time
      let p = try f.result(id,time,LiveVisionFixtures.standingPair)
      let a = try #require(f.gate.admit(p.source));_ = bridge.drain(lease)
      try #require(try f.finish(p,stamp:a))
      f.gate.publishPresentation(p,admission:a,receipt:try #require(f.gate.snapshot.latest))
      let delivery = try #require(bridge.drain(lease))
      let mapped = try VisionAvatarPacketAdapter.map(delivery,using:AdapterTestFactory.self)
      let output = try #require(mapped.output)
      #expect(output.p1.requiresRebind && output.p2.requiresRebind)
      #expect(output.p1.state == .lost && output.p2.state == .lost)
      #expect(output.p1.lastConfirmedAt == 0.25 && output.p2.lastConfirmedAt == 0.25)
    }
    #expect(f.gate.snapshot.acknowledgments == 1)
  }

  @Test func expiryResetSurvivesCoalescingAndNoOldFrameIsRestamped() throws {
    var (f,bridge,lease) = try published()
    f.clock.time = 0.75;f.gate.expireDue(at:0.75)
    // No render drain observes the inactive status before a fresh admitted/published frame.
    let p = try f.result(4,0.75,LiveVisionFixtures.standingPair)
    let a = try #require(f.gate.admit(p.source));try #require(try f.finish(p,stamp:a))
    f.gate.publishPresentation(p,admission:a,receipt:try #require(f.gate.snapshot.latest))
    let delivery = try #require(bridge.drain(lease)), output = try #require(delivery.output)
    #expect(delivery.resetAll && delivery.status.active)
    #expect(output.pose.frameID == 4 && output.pose.capturedAt == 0.75)
    #expect(output.presentationRevision == delivery.status.revision)
    #expect(output.tracking.player1.state == .uncertain)
  }

}
