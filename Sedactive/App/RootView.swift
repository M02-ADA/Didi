//
//  ContentView.swift
//  Sedactive
//
//  Created by Edward Geraldo Kristian on 18/10/26.
//

import SwiftUI

struct ContentView: View {
  private let dependencies = AppDependencies.shared
  @Environment(\.scenePhase) private var scenePhase
  #if DEBUG
  @State private var showingLiveWrist = InGameCameraPreviewView.wristRequested(ProcessInfo.processInfo.arguments)
  @State private var showingGameCamera = InGameCameraPreviewView.requested(ProcessInfo.processInfo.arguments)
  #endif
  var body: some View {
    let flow = dependencies.inputFlow
    Group {
      #if DEBUG
      if ProcessInfo.processInfo.arguments.contains("-setupStagePreview") {
        SetupStagePreview()
      } else if LiveAvatarSmokeModel.requested(ProcessInfo.processInfo.arguments) {
        LiveAvatarSmokeView(flow:flow,service:dependencies.bodyInput,bridge:dependencies.visionPoseBridge)
      } else if showingGameCamera || showingLiveWrist {
        InGameCameraPreviewView(flow: flow, service: dependencies.bodyInput,
          bridge: dependencies.visionPoseBridge, offersWristSetup:showingLiveWrist,
          onContinueToGame:{ showingLiveWrist = false;showingGameCamera = false },
          onExit: { showingGameCamera = false;showingLiveWrist = false })
      } else { routedContent(flow:flow) }
      #else
      routedContent(flow:flow)
      #endif
    }
    #if DEBUG
    // Device checks: `-startCameraSetup` opens Camera Setup at launch (same flow as the button).
    .task {
      let arguments = ProcessInfo.processInfo.arguments
      if arguments.contains("-startSoloTest"), flow.canStartSolo {
        await flow.startLiveSetup(solo: true)
      } else if arguments.contains("-startCameraSetup"), flow.canStartLive {
        await flow.startLiveSetup()
      }
    }
    #endif
    .onChange(of: scenePhase) { _, phase in
      if phase == .background { Task { await flow.handleBackground() } }
    }
  }
  @ViewBuilder private func routedContent(flow: LaserInputFlow) -> some View {
      switch flow.route {
      case .selection:
        // Sketch Home and Set Up (Kevin): presentation over the same flow. In
        // DEBUG, Home also offers PR #31's real-camera game scene preview.
        #if DEBUG
        LaserHeistIntroView(flow: flow, onInGameCamera: { showingGameCamera = true })
        #else
        LaserHeistIntroView(flow: flow)
        #endif
      case .replay:
        replayView(flow: flow)
      case .liveSetup:
        liveSetup(flow: flow)
      case .diagnostics:
        #if DEBUG
        LiveInputDiagnosticsView(model: dependencies.cameraDiagnostics)
          .safeAreaInset(edge: .bottom) {
            Button("Close camera diagnostics") { Task { await flow.closeDiagnostics() } }
              .buttonStyle(.borderedProminent).controlSize(.large).disabled(flow.isClosing).padding()
          }
        #else
        LaserInputSelectionView(flow: flow)
        #endif
      }
  }
  /// Camera setup, then the live round over it (co-op, or a DEBUG Solo Test).
  @ViewBuilder private func liveSetup(flow: LaserInputFlow) -> some View {
        // Automatic setup mounts the game scene from the start (hidden behind the camera screen),
        // so its first load does not stall tracking right after calibration (iPad, 11 November).
        ZStack {
          let recovering = flow.session.map { LaserTrackingWarning.Input(session: $0).isTrackingPause } ?? false
          let stageShown = recovering || Self.showsSetupStage(flow.session)
          if let session = flow.session, session.hasLiveRoundPlan || session.automaticSetup {
            PlayView(avatarSource: { try VisionK03MailboxPump(bridge: dependencies.visionPoseBridge, mailbox: $0) },
                     onExit: { Task { await flow.closeLiveSetup() } }, liveSession: session,
                     onLiveRetry: { Task { await flow.retryLiveSetup() } })
              .id(ObjectIdentifier(session)) // a new session (Retry) gets a fresh scene
              .allowsHitTesting(!stageShown)
              .accessibilityHidden(stageShown)
          }
          // The setup stage, with its camera preview, stays MOUNTED for the whole visit and is only
          // hidden over the game: attaching or detaching the preview layer reconfigures the running
          // capture session and stalls frames 220–500 ms (iPad, 11 November 2026), which aborted
          // every countdown and, repeated, lost the player and restarted setup.
          liveSetupStage(flow, preview: cameraPreview, recovering: recovering)
            .opacity(stageShown ? 1 : 0)
            .allowsHitTesting(stageShown)
            .accessibilityHidden(!stageShown)
          // Non-tracking pauses still use the in-game pause presentation.
          if !stageShown, let session = flow.session, session.hasLiveRoundPlan {
            LaserTrackingWarningOverlay(flow: flow, session: session).id(ObjectIdentifier(session))
          }
          // The countdown shows only the session's own remaining time (no second clock).
          if let session = flow.session, session.phase == .countdown,
             let remaining = session.liveReadiness?.countdownRemaining {
            RoundCountdownOverlay(value: Int(remaining.rounded(.up)))
          }
          #if DEBUG
          if !stageShown, let session = flow.session, session.hasLiveRoundPlan, session.state != nil, session.summary == nil {
            DebugRoundControls(session: session)
          }
          #endif
        }
  }
  /// Whether the camera setup stage is in front: always until a live round's game scene is
  /// mounted, then except while counting down, playing or showing results.
  static func showsSetupStage(_ session: GameSessionCoordinator?) -> Bool {
    guard let session, session.hasLiveRoundPlan || session.automaticSetup else { return true }
    // Started rounds use their own recovery check before reusing the calibration stage.
    if session.state != nil && session.summary == nil { return false }
    return session.phase != .countdown && session.phase != .running && session.summary == nil
  }
  /// The live camera image for the setup stage: the pipeline's one retained
  /// session, display only. Nil in the Simulator (no camera).
  private var cameraPreview: AnyView? {
    #if targetEnvironment(simulator)
    nil
    #else
    dependencies.camera.previewSession.map { AnyView(CalibrationCameraPreview(session: $0)) }
    #endif
  }
  @ViewBuilder private func replayView(flow: LaserInputFlow) -> some View {
    #if DEBUG
    if ProcessInfo.processInfo.arguments.contains("--synthetic-gameplay-preview") {
      PlayView(avatarSource: { try SyntheticGameplayAvatarPump(mailbox: $0) },
        onExit: { flow.leaveReplay() })
        .overlay(alignment: .bottomLeading) {
          Text("SEEDED SYNTHETIC / REPLAY · no camera or live calibration")
            .font(.caption2.monospaced()).padding(6).background(.black.opacity(0.7))
            .foregroundStyle(.white).allowsHitTesting(false)
        }
    } else { PlayView(onExit: { flow.leaveReplay() }) }
    #else
    PlayView(onExit: { flow.leaveReplay() })
    #endif
  }

}

/// Jevon's setup controls on the Sketch "stand here" stage (Kevin's presentation).
@MainActor
private func liveSetupStage(_ flow: LaserInputFlow, preview: AnyView?, recovering: Bool) -> some View {
  CalibrationStageView(cameraPreview: preview,
    cameraAspect: AppDependencies.shared.camera.negotiated.map {
      CGFloat($0.outputWidth) / CGFloat(max(1, $0.outputHeight)) } ?? 16 / 9,
    playerStatus: flow.session.map { session in
      guard recovering else { return session.presence.players }
      let input = LaserTrackingWarning.Input(session: session)
      return Dictionary(uniqueKeysWithValues: session.inputConfiguration.roster.map { player in
        if let status = session.presence.players[player], case .calibrating = status {
          return (player, status)
        }
        let ready = input.hasPacket && !input.identityLost && !input.awaitsIdentityRecovery
        let status: LaserSetupPlayerStatus = ready && input.attention[player] == nil ? .linked : .searching
        return (player, status)
      })
    } ?? [:],
    solo: flow.session?.isSoloPractice == true,
    showsCameraUnavailableLabel: false,
    onBack: { Task { await flow.closeLiveSetup(returnToPlacement: true) } }) {
    PlayerSetupView(flow: flow, isOverlay: true, isRecovering: recovering)
  }
  #if DEBUG
  // DEBUG only, for testing without an iPad: ends camera setup (nothing is
  // calibrated or marked ready) and opens the seeded synthetic replay through
  // the same flow. Never compiled into Release.
  .overlay(alignment: .bottomLeading) {
    if !recovering, ProcessInfo.processInfo.arguments.contains("-enableCalibrationReplaySkip") {
      Button("DEBUG · Skip camera & play synthetic replay") {
        Task {
          await flow.closeLiveSetup()
          flow.showReplay()
        }
      }
      .font(.system(size: 15, weight: .heavy, design: .monospaced))
      .padding(.horizontal, 14).padding(.vertical, 8)
      .background(Color(sketch: 0xFFC83A), in: Capsule())
      .foregroundStyle(Color(sketch: 0x16123A))
      .buttonStyle(.plain)
      .disabled(flow.isClosing)
      .padding([.leading, .bottom], 16)
      .accessibilityIdentifier("debugSkipToReplay")
    }
  }
  #endif
  .onAppear { AudioService.shared.setMusic(.menu) }
}

#Preview {
  ContentView()
}
