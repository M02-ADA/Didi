#if DEBUG
import Foundation
import QuartzCore

/// App composition for a labelled synthetic game preview. Presentation fixtures ONLY:
/// the replay coordinator remains the sole CP1 consumer and gameplay authority.
@MainActor final class SyntheticGameplayAvatarPump: AvatarPosePump {
  let mailbox: AvatarPoseMailbox
  private let source: SyntheticAvatarSource
  private let sequence: RobotDemoSequence
  private let now: () -> Double
  private let startedAt: Double
  private var lastFrame: UInt64 = 0
  private var stopped = false

  init(mailbox: AvatarPoseMailbox, now: @escaping () -> Double = { CACurrentMediaTime() }) throws {
    let script = try LaserReplayScript.load().freshRound(generation: UUID())
    self.mailbox = mailbox; self.now = now; startedAt = now()
    source = SyntheticAvatarSource(configuration: script.input.configuration,
      cameraGeometryRevision: script.input.cameraGeometryRevision)
    sequence = RobotDemoSequence(configuration: script.input.configuration,
      cameraGeometryRevision: script.input.cameraGeometryRevision)
    mailbox.publish(source.status)
  }
  func tick() throws -> Bool {
    guard !stopped, !mailbox.isRevoked else { stop(); return false }
    let time = now(), elapsed = time - startedAt
    guard elapsed.isFinite, elapsed >= 0 else { stop(); return false }
    let frame = UInt64(min(elapsed * RobotDemoSequence.frameRate, Double(UInt32.max)))
    guard frame > lastFrame else { return true }
    let fixture = try sequence.frame(frame)
    // The fixture's relative time is placed on this synthetic attachment's host timeline.
    // No live camera timestamp is consumed, changed or reused.
    let value = source.output(fixture.snapshot, joints: fixture.joints)
    let output = AvatarSourceOutput(source: AvatarSourceFrame(context: value.source.context,
      frameID: value.source.frameID, capturedAt: startedAt + fixture.snapshot.capturedAt,
      controlRevision: value.source.controlRevision), contextRevision: value.contextRevision,
      player1: value.player1, player2: value.player2, candidates: value.candidates,
      calibration: value.calibration)
    mailbox.offer(output); lastFrame = frame
    return true
  }
  func stop() {
    guard !stopped else { return }
    stopped = true; mailbox.revoke()
  }
}
#endif
