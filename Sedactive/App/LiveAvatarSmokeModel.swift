#if DEBUG
import Foundation
import Observation

/// DEBUG presentation coordinator over J03's existing setup-only lifetime. No provider,
/// camera, CP1 subscriber, gameplay plan, accepted calibration or identity store of its own.
@MainActor @Observable final class LiveAvatarSmokeModel {
  let flow: LaserInputFlow
  let service: BodyInputService
  let bridge: VisionNumericPoseBridge
  private(set) var error: String?
  init(flow: LaserInputFlow, service: BodyInputService, bridge: VisionNumericPoseBridge) {
    self.flow = flow; self.service = service; self.bridge = bridge
  }
  nonisolated static func requested(_ arguments: [String]) -> Bool {
    arguments.contains("--live-avatar-smoke")
      && !arguments.contains("--synthetic-gameplay-preview")
      && !arguments.contains("--camera-diagnostics")
      && !arguments.contains("--camera-diagnostics-run")
      && !arguments.contains("-robotDemo")
  }
  var session: GameSessionCoordinator? {
    guard flow.route == .liveSetup, !flow.isStarting, !flow.isClosing,
      let session = flow.session, !session.isReplay, !session.hasLiveRoundPlan,
      session.phase == .awaitingSetup || session.phase == .restartRequired else { return nil }
    return session
  }
  var sourceGeneration: UUID? {
    guard let session, service.currentContext?.isActive == true,
      service.currentContext?.sessionGeneration == session.inputConfiguration.sessionGeneration else { return nil }
    return session.inputConfiguration.sessionGeneration
  }
  func start() async {
    guard flow.canStartLive else { return }
    error = nil
    await flow.startLiveSetup()
    if let candidate = flow.session, candidate.isReplay || candidate.hasLiveRoundPlan {
      await flow.closeLiveSetup()
      error = "Smoke mode requires setup only; gameplay configuration refused."
    }
  }
  func stop() async { await flow.closeLiveSetup() }
  func arm() {
    guard let setup = session?.setup, sourceGeneration != nil else { return }
    do { try setup.beginBinding(); error = nil }
    catch { self.error = "Binding refused: \(error). Stop, then start a fresh camera session if rebind is required." }
  }
  func cancelBinding() {
    guard session != nil else { return }
    service.cancelBinding() // actual producer revocation; old setup receipt cannot be reused
    flow.session?.refreshLiveReadiness()
  }
  /// Called only after awaited scene assets, against the ORIGINAL setup generation.
  func attach(mailbox: AvatarPoseMailbox, generation: UUID) throws -> VisionK03MailboxPump {
    guard sourceGeneration == generation, service.currentContext?.calibrationRevisions.isEmpty == true else {
      throw LiveVisionError.inactiveSource
    }
    return try VisionK03MailboxPump(bridge: bridge, mailbox: mailbox)
  }
}
#endif
