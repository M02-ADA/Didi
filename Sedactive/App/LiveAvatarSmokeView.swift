#if DEBUG
import SwiftUI
import RealityKit
import QuartzCore

/// Uses Kevin's unchanged stage and K03 presenter, without PlayView's replay/game driver.
/// Start is explicit. J03 starts the provider BEFORE a scene may attach to E07.
struct LiveAvatarSmokeView: View {
  @State private var model: LiveAvatarSmokeModel
  init(flow: LaserInputFlow, service: BodyInputService, bridge: VisionNumericPoseBridge) {
    _model = State(initialValue: LiveAvatarSmokeModel(flow:flow,service:service,bridge:bridge))
  }
  var body: some View {
    VStack(spacing: 8) {
      Text("REAL CAMERA → AVATARS · DEBUG · NO GAMEPLAY")
        .font(.headline).accessibilityIdentifier("liveAvatarSmokeTitle")
      HStack {
        Button("Start camera setup") { Task { await model.start() } }
          .disabled(!model.flow.canStartLive).accessibilityIdentifier("smokeStart")
        Button("Arm pair binding") { model.arm() }
          .disabled(model.sourceGeneration == nil).accessibilityIdentifier("smokeArm")
        Button("Cancel binding") { model.cancelBinding() }
          .disabled(model.sourceGeneration == nil).accessibilityIdentifier("smokeCancel")
        Button("Stop camera") { Task { await model.stop() } }
          .disabled(model.flow.route != .liveSetup || model.flow.isClosing)
          .accessibilityIdentifier("smokeStop")
      }.buttonStyle(.bordered)
      Text("Two real people required. P1 = canonical image-right; P2 = image-left. Uncalibrated direction-only display; no body measurements authorize gameplay.")
        .font(.caption)
      if let message = model.flow.message { Text(message).foregroundStyle(.orange) }
      if let error = model.error { Text(error).foregroundStyle(.orange) }
      TimelineView(.periodic(from:.now,by:0.2)) { _ in
        let tracking = model.service.camera.frames.tracking.snapshot
        VStack(alignment:.leading) {
          Text("Provider: \(String(describing:model.service.status)) · J03: \(String(describing:model.flow.session?.phase))")
          Text("Request: \(tracking.requestID?.uuidString ?? "DISARMED") · control \(tracking.revision)")
          Text("Pair acknowledgment: \(tracking.acknowledgment == nil ? "NONE" : "received (not a current-tracking guarantee)")")
          Text("Source: \(model.service.camera.state.context.map { "\($0.generation) / \($0.epoch) / geometry \($0.geometryRevision)" } ?? "none")")
          Text("Current frame: \(tracking.latest?.source.map { "\($0.frameID) @ \($0.capturedAt)" } ?? "UNAVAILABLE / expired")")
          ForEach(PlayerID.allCases,id:\.self) { id in
            let slot = tracking.latest?[id]
            Text("\(id.rawValue): \(slot.map { "\($0.state.rawValue) / \($0.reason.rawValue) / rebind \($0.requiresRebind)" } ?? "UNAVAILABLE")")
          }
          Text("Expiry \(tracking.expiries) · invalidation \(tracking.invalidations) · Stop/Start required after lost/rebind/source loss")
        }.font(.caption.monospaced()).frame(maxWidth:.infinity,alignment:.leading)
      }
      if let generation = model.sourceGeneration {
        LiveAvatarSmokeStage(model:model,generation:generation).id(generation)
      } else {
        ContentUnavailableView(model.flow.isStarting ? "Starting camera setup" : "Live avatars unavailable",
          systemImage:"person.2",description:Text("Capture starts disarmed. Stop must finish before another Start. No synthetic fallback."))
      }
    }.padding().background(.black).foregroundStyle(.white)
      .onDisappear { Task { await model.stop() } }
  }
}
private struct LiveAvatarSmokeStage: View {
  let model: LiveAvatarSmokeModel
  let generation: UUID
  @State private var scene = LaserScene()
  @State private var refresh: EventSubscription?
  @State private var error: String?
  var body: some View {
    RealityView { content in
      content.camera = .virtual
      let environment = await LaserScene.loadAuthoredEnvironment()
      let templates: [PlayerID: Entity]
      do { templates = try await RobotAvatarLayer.sharedTemplates() }
      catch { self.error = "Mascot assets unavailable: \(error)"; return }
      guard !Task.isCancelled, model.sourceGeneration == generation else { return }
      scene.installEnvironment(authored:environment)
      scene.isLaserVisible = false
      let mailbox = AvatarPoseMailbox(maxAge:LiveAvatarPresenter.maximumPoseAge)
      do {
        let pump = try model.attach(mailbox:mailbox,generation:generation)
        scene.attachLiveAvatars(mailbox:mailbox,templates:templates,pump:pump)
        content.add(scene.root)
        refresh = content.subscribe(to:SceneEvents.Update.self) { [weak scene] _ in
          scene?.refreshLiveAvatars(now:CACurrentMediaTime())
        }
      } catch { self.error = "Avatar attachment refused: \(error)" }
    }
    .overlay(alignment:.topLeading) {
      if let error { Text(error).padding().background(.black.opacity(0.8)) }
    }
    .onDisappear {
      refresh?.cancel(); refresh = nil
      scene.detachLiveAvatars() // retires only this exact old lease; cannot cancel a Retry attachment
    }
  }
}
#endif
