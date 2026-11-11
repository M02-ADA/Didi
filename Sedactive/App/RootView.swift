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
        #if DEBUG
          .overlay(alignment: .top) {
            if flow.session?.isSoloPractice == true {
              Text("SOLO TEST · P1 only · practice, not a co-op result")
                .font(.system(size: 13, weight: .heavy, design: .monospaced))
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(Color(sketch: 0xFFC83A), in: Capsule())
                .foregroundStyle(Color(sketch: 0x16123A))
                .padding(.top, 4)
                .allowsHitTesting(false)
                .accessibilityIdentifier("soloTestBanner")
            }
          }
        #endif
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
        if let session = flow.session, session.hasLiveRoundPlan || session.automaticSetup {
          ZStack {
            PlayView(avatarSource: { try VisionK03MailboxPump(bridge: dependencies.visionPoseBridge, mailbox: $0) },
                     onExit: { Task { await flow.closeLiveSetup() } }, liveSession: session,
                     onLiveRetry: { Task { await flow.retryLiveSetup() } })
              .id(ObjectIdentifier(session)) // a new session (Retry) gets a fresh scene
            // The countdown shows only the session's own remaining time (no second clock).
            if session.phase == .countdown, let remaining = session.liveReadiness?.countdownRemaining {
              RoundCountdownOverlay(value: Int(remaining.rounded(.up)))
            } else if session.phase != .running, session.summary == nil { liveSetupStage(flow, preview: cameraPreview) }
          }
        } else { liveSetupStage(flow, preview: cameraPreview) }
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
private func liveSetupStage(_ flow: LaserInputFlow, preview: AnyView?) -> some View {
  CalibrationStageView(cameraPreview: preview,
    cameraAspect: AppDependencies.shared.camera.negotiated.map {
      CGFloat($0.outputWidth) / CGFloat(max(1, $0.outputHeight)) } ?? 16 / 9,
    playerStatus: flow.session?.automaticSetup == true ? flow.session?.presence.players ?? [:] : [:],
    solo: flow.session?.isSoloPractice == true,
    onBack: { Task { await flow.closeLiveSetup() } }) {
    PlayerSetupView(flow: flow, isOverlay: true)
  }
  #if DEBUG
  .overlay(alignment: .bottomTrailing) { SetupDiagnosticsToggle(flow: flow) }
  #endif
  #if DEBUG
  // DEBUG only, for testing without an iPad: ends camera setup (nothing is
  // calibrated or marked ready) and opens the seeded synthetic replay through
  // the same flow. Never compiled into Release.
  .overlay(alignment: .bottomLeading) {
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
  #endif
  .onAppear { AudioService.shared.setMusic(.menu) }
}

#Preview {
  ContentView()
}
