#if DEBUG
import SwiftUI
import RealityKit
import QuartzCore
import Observation

/// Read-only view of the existing B1 mailbox. Original source metadata is never restamped.
/// This is NOT a PlayerID association, E07 packet, calibration or CP1 gameplay evidence.
nonisolated struct InGameCameraPoseReadout {
  let completed: UInt64
  let lastSource: CameraFrameMetadata?
  let current: Bool
  let rawObservations: Int?
  let jointCounts: [Int]
  init(_ snapshot: CameraPoseSnapshot, source: CameraSourceContext?, sourceActive: Bool, now: Double) {
    completed = snapshot.statistics.completed
    lastSource = snapshot.latest?.source
    guard sourceActive, let value = snapshot.latest, value.source.context == source,
      value.matchesSource, (try? value.frame.validate()) != nil,
      now.isFinite, now >= value.source.capturedAt,
      now - value.source.capturedAt < LiveAvatarPresenter.maximumPoseAge else {
      current = false; rawObservations = nil; jointCounts = []; return
    }
    current = true; rawObservations = value.observationCount
    jointCounts = value.frame.candidates.prefix(PoseEstimator.maximumCandidates).map { $0.joints.count }
  }
}

/// One presentation attachment over J03 setup. No camera, game clock, CP1 reader or pose authority.
@MainActor @Observable final class InGameCameraStage {
  let scene = LaserScene()
  private var templates: [PlayerID: Entity] = [:]
  private(set) var ready = false
  private(set) var error: String?
  private(set) var attachedGeneration: UUID?
  private(set) var mailbox: AvatarPoseMailbox?
  private var retiredGeneration: UUID?
  private var disposed = false

  func install(environment: Entity?, templates: [PlayerID: Entity]) {
    guard !disposed else { return }
    guard Set(templates.keys) == Set(PlayerID.allCases) else { assetFailure(); return }
    self.templates = templates
    scene.installEnvironment(authored: environment)
    scene.isLaserVisible = false
    neutral()
    ready = true
  }
  func assetFailure() {
    dispose(); error = "Game mascot assets unavailable. No synthetic fallback."
  }
  private func neutral() {
    scene.detachLiveAvatars()
    mailbox = nil; attachedGeneration = nil
    guard !templates.isEmpty, !disposed else { return }
    // A passive renderer mailbox, not an E07 lease or a second input source.
    scene.attachLiveAvatars(mailbox: AvatarPoseMailbox(maxAge: LiveAvatarPresenter.maximumPoseAge),
      templates: templates)
  }
  func endCamera() {
    if let generation = attachedGeneration { retiredGeneration = generation }
    neutral()
  }
  func tick(model: LiveAvatarSmokeModel, now: Double) {
    guard ready, !disposed else { return }
    let desired = model.sourceGeneration
    if let old = attachedGeneration,
      desired != old || scene.liveAvatars?.feedEnded == true {
      retiredGeneration = old
      neutral() // late old assets/continuations cannot reattach this setup generation
    }
    if let desired, attachedGeneration == nil, desired != retiredGeneration {
      let box = AvatarPoseMailbox(maxAge: LiveAvatarPresenter.maximumPoseAge)
      do {
        let pump = try model.attach(mailbox: box, generation: desired)
        scene.attachLiveAvatars(mailbox: box, templates: templates, pump: pump)
        mailbox = box; attachedGeneration = desired; error = nil
      } catch {
        retiredGeneration = desired
        self.error = "E07 attachment unavailable: \(error). Stop before starting a fresh setup."
      }
    }
    scene.refreshLiveAvatars(now: now)
  }
  func dispose() {
    disposed = true; scene.detachLiveAvatars()
    mailbox = nil; attachedGeneration = nil; templates = [:]; ready = false
  }
}

/// The actual LaserScene corridor/mascots, without PlayView's replay driver or a live round plan.
/// All source controls still go through the existing J03 setup-only session.
struct InGameCameraPreviewView: View {
  @State private var model: LiveAvatarSmokeModel
  @State private var stage = InGameCameraStage()
  @State private var refresh: EventSubscription?
  let onExit: () -> Void
  init(flow: LaserInputFlow, service: BodyInputService, bridge: VisionNumericPoseBridge,
    onExit: @escaping () -> Void) {
    _model = State(initialValue: LiveAvatarSmokeModel(flow: flow, service: service, bridge: bridge))
    self.onExit = onExit
  }
  nonisolated static func requested(_ args: [String]) -> Bool {
    args.contains("--ingame-camera-preview") && !args.contains("--live-avatar-smoke")
      && !args.contains("--synthetic-gameplay-preview") && !args.contains("--camera-diagnostics")
      && !args.contains("--camera-diagnostics-run") && !args.contains("-robotDemo")
      && !args.contains("-replay")
  }
  var body: some View {
    GeometryReader { geometry in
      VStack(spacing: 8) {
        Text("LASER HEIST · REAL CAMERA GAME SCENE · DEBUG")
          .font(.headline).accessibilityIdentifier("inGameCameraTitle")
        Text("NO GAMEPLAY · no scoring, collision, vaults, diamonds or accepted calibration")
          .font(.caption).foregroundStyle(.orange)
        HStack {
          Button("Start camera setup") { Task { await model.start() } }
            .disabled(!model.flow.canStartLive).accessibilityIdentifier("gameCameraStart")
          Button("Arm genuine P1/P2 pair") { model.arm() }
            .disabled(model.sourceGeneration == nil).accessibilityIdentifier("gameCameraArm")
          Button("Cancel binding") { model.cancelBinding() }
            .disabled(model.sourceGeneration == nil).accessibilityIdentifier("gameCameraCancel")
          Button("Stop camera") {
            stage.endCamera()
            Task { await model.stop() }
          }.disabled(model.flow.route != .liveSetup || model.flow.isClosing)
            .accessibilityIdentifier("gameCameraStop")
          Button("Back to game menu") {
            stage.endCamera()
            Task { await model.stop(); onExit() }
          }.accessibilityIdentifier("gameCameraExit")
        }.buttonStyle(.bordered).font(.callout)
        Text("Two real people + explicit Arm for P1/P2 motion. Alone: inspect raw B1 below; no unbound observation is labelled P1.")
          .font(.caption)
        if let message = model.flow.message { Text(message).font(.caption).foregroundStyle(.orange) }
        if let error = model.error ?? stage.error { Text(error).font(.caption).foregroundStyle(.orange) }
        RealityView { content in
          content.camera = .virtual
          let environment = await LaserScene.loadAuthoredEnvironment()
          do {
            let templates = try await RobotAvatarLayer.sharedTemplates()
            guard !Task.isCancelled else { return }
            stage.install(environment: environment, templates: templates)
            content.add(stage.scene.root)
            refresh = content.subscribe(to: SceneEvents.Update.self) { _ in
              stage.tick(model: model, now: CACurrentMediaTime())
            }
          } catch { stage.assetFailure() }
        }
        .overlay(alignment: .topLeading) {
          Text(stage.ready ? "Lemon · P1   |   Tangerine · P2\nGame environment ready · uncalibrated direction-only when bound" : "Loading game environment / assets unavailable")
            .font(.caption).padding(8).background(.black.opacity(0.75))
            .accessibilityIdentifier(stage.ready ? "gameSceneReady" : "gameSceneLoading")
        }
        // Full window width preserves the game's lane framing; controls do not narrow the 3D viewport.
        .frame(width: max(1, geometry.size.width - 32), height: max(1, geometry.size.height - 350))
        readout.frame(height: 140)
      }.frame(width: max(1, geometry.size.width - 32), height: max(1, geometry.size.height - 32))
        .padding(16)
    }.background(.black).foregroundStyle(.white)
      .onDisappear {
        refresh?.cancel(); refresh = nil; stage.dispose()
        Task { await model.stop() }
      }
  }
  private var readout: some View {
    TimelineView(.periodic(from: .now, by: 0.2)) { _ in
      let camera = model.service.camera
      let context = camera.state.context
      let active = model.sourceGeneration != nil && context.map { camera.frames.isCurrent($0) } == true
      let pose = InGameCameraPoseReadout(camera.frames.poses.snapshot,
        source: context, sourceActive: active, now: CameraHostClock.now())
      let tracking = camera.frames.tracking.snapshot
      let metrics = camera.frames.metrics.snapshot
      ScrollView {
        VStack(alignment: .leading, spacing: 6) {
          Text("Camera: \(String(describing: camera.state.status)) · Provider: \(String(describing: model.service.status))")
          Text("Source: \(context.map { "\($0.generation) / epoch \($0.epoch) / geometry \($0.geometryRevision)" } ?? "none")")
          Text("B1: \(pose.current ? "CURRENT" : "UNAVAILABLE / stale") · completed this run \(pose.completed)")
            .accessibilityIdentifier("gameCameraB1")
          if let source = pose.lastSource {
            Text("\(pose.current ? "Current" : "Historical") B1 frame \(source.frameID) @ \(source.capturedAt)")
          }
          if let count = pose.rawObservations {
            Text("Raw Vision observations \(count) (not human count) · observed joints \(pose.jointCounts.map(String.init).joined(separator: ", ")) / 14")
          }
          Text("B2: \(tracking.requestID == nil ? "DISARMED" : "explicit pair request") · control \(tracking.revision)")
          Text("Acknowledgment: \(tracking.acknowledgment == nil ? "NONE" : "received — current availability below")")
          ForEach(PlayerID.allCases, id: \.self) { id in
            Text("\(id.rawValue): \(tracking.latest.map { "\($0[id].state.rawValue) / \($0[id].reason.rawValue) / rebind \($0[id].requiresRebind)" } ?? "UNAVAILABLE")")
          }
          Text("E07/K03: \(stage.attachedGeneration == nil ? "DETACHED / neutral scene" : "attached; stale poses reset at 0.25 s")")
          Text("K03 accepted packets (attachment total): \(stage.mailbox?.diagnostics.accepted ?? 0)")
          Text("Owned pixels \(metrics.ownedPixelBytes) B · source frames \(camera.frames.usage.frames) · workspace \(metrics.workspaceBytes) B")
          Text("Expiry \(tracking.expiries) · invalidation \(tracking.invalidations)")
          Text("B1 is raw/unbound; no solo K03 slot. Counters are separately synchronized, not one atomic diagnostic snapshot.")
        }.font(.caption2.monospaced()).frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }
}
#endif
