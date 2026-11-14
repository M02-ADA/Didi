import Foundation

/// PROPOSED App-owned hookup between Edo's numeric pose bridge and Kevin's K03
/// mailbox. The presenter calls `tick` once per render tick, before it drains.
///
/// - A drain with no output is normal: most render ticks have no new result.
/// - A nil drain means the lease was retired, for example when the body
///   session stopped. That ends this pump; Retry attaches a new one.
/// - A refused packet changes nothing in the mailbox and is counted in its
///   diagnostics. A newer packet can still be accepted, and with none the
///   mascots relax by age, so a refusal doesn't end the feed.
/// - A mapping error can lose a coalesced reset, so it does end the feed. The
///   presenter then forgets any held pose.
@MainActor final class VisionK03MailboxPump: AvatarPosePump {
  private let bridge: VisionNumericPoseBridge
  private let attachment: VisionPoseAttachment
  let mailbox: AvatarPoseMailbox
  private var stopped = false
  init(bridge: VisionNumericPoseBridge, mailbox: AvatarPoseMailbox) throws {
    self.bridge = bridge; self.mailbox = mailbox
    attachment = try bridge.attach()
  }
  func tick() throws -> Bool {
    guard !stopped, !mailbox.isRevoked else { stop(); return false }
    guard let drain = bridge.drain(attachment) else { stop(); return false }
    do {
      let batch = try VisionAvatarPacketAdapter.map(drain, using: VisionK03PacketFactory.self)
      mailbox.publish(batch.status, forceResetAll: batch.resetAll)
      if let output = batch.output { mailbox.offer(output) }
      return true
    } catch { stop(); throw error }
  }
  func stop() {
    guard !stopped else { return }
    stopped = true; bridge.cancel(attachment); mailbox.revoke()
  }
}
