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
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var homeExit: FTUEHomeExit?

  private enum FTUEHomeExit: Equatable {
    case covering(UUID)
    case covered(UUID)
    case revealing(UUID)

    var opacity: Double {
      if case .revealing = self { return 0 }
      return 1
    }

    var hidesOutgoingScene: Bool {
      if case .covering = self { return false }
      return true
    }
  }
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
    .allowsHitTesting(homeExit == nil)
    .accessibilityHidden(homeExit != nil)
    .overlay {
      LaserHeistDesign.night
        .ignoresSafeArea()
        .opacity(homeExit?.opacity ?? 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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
      if phase == .background {
        if case let .covering(generation) = homeExit {
          // A backgrounded app cannot rely on an animation completion to release camera input.
          finishCover(generation, flow: flow)
        } else if case .revealing = homeExit {
          homeExit = nil
        }
        Task { await flow.handleBackground() }
      }
    }
  }
  @ViewBuilder private func routedContent(flow: LaserInputFlow) -> some View {
      if homeExit?.hidesOutgoingScene == true, flow.route != .selection {
        LaserHeistDesign.night.ignoresSafeArea()
      } else {
        routeView(flow: flow)
      }
  }

  @ViewBuilder private func routeView(flow: LaserInputFlow) -> some View {
      switch flow.route {
      case .selection:
        // Sketch Home and Set Up (Kevin): presentation over the same flow. In
        // DEBUG, Home also offers PR #31's real-camera game scene preview.
        Group {
          #if DEBUG
          LaserHeistIntroView(flow: flow, onInGameCamera: { showingGameCamera = true })
          #else
          LaserHeistIntroView(flow: flow)
          #endif
        }
        .task { revealHome() }
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
          let recoveringExploration = (flow.leanTutorial.isPractising || flow.leanTutorial.collection != nil)
            && flow.session.map { Self.showsLeanSetupRecovery(tutorial: flow.leanTutorial, session: $0) } == true
          let recoveringTutorialBonus = flow.leanTutorial.stage == .diamondTimeDemo && flow.session.map {
            $0.tutorialDiamondTimeInputs(generation: $0.inputConfiguration.sessionGeneration) == nil
          } == true
          let recovering = recoveringExploration || recoveringTutorialBonus
          let stageShown = Self.showsSetupStage(flow.session)
            && (!flow.leanTutorial.isActive || recovering)
            && !(flow.leanTutorial.stage == .completed && (flow.session?.preRoundTutorialPending == true || flow.session?.canStartLiveRound == true))
          if let session = flow.session, session.hasLiveRoundPlan || session.automaticSetup {
            PlayView(avatarSource: { try VisionK03MailboxPump(bridge: dependencies.visionPoseBridge, mailbox: $0) },
                     onExit: { Task { await flow.closeLiveSetup() } }, liveSession: session,
                     onLiveRetry: { Task { await flow.retryLiveSetup() } }, leanTutorial: flow.leanTutorial,
                     onTutorialDiamondTimeFinished: { beginHomeExit($0, flow: flow) })
              .blur(radius: (flow.leanTutorial.stage == .introduction || flow.leanTutorial.stage == .jumpDuckIntroduction) && !flow.leanTutorial.isSuspended ? 5 : 0)
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
          // A started round holds on the standing-position warning. Recalibrate opens a fresh setup.
          if !stageShown, let session = flow.session, session.hasLiveRoundPlan {
            LaserTrackingWarningOverlay(flow: flow, session: session).id(ObjectIdentifier(session))
          }
          // The countdown shows only the session's own remaining time (no second clock).
          if let session = flow.session, session.phase == .countdown,
             let remaining = session.liveReadiness?.countdownRemaining {
            RoundCountdownOverlay(value: Int(remaining.rounded(.up)))
          }
          if !stageShown, flow.leanTutorial.isActive, !flow.leanTutorial.isSuspended {
            LeanTutorialOverlay(tutorial: flow.leanTutorial, solo: flow.isSolo)
          }
          #if DEBUG
          if !stageShown, let session = flow.session, session.hasLiveRoundPlan, session.state != nil, session.summary == nil {
            DebugRoundControls(session: session)
          }
          #endif
        }
        .onChange(of: flow.session?.canStartLiveRound, initial: true) { _, _ in
          flow.presentLeanTutorialIfReady()
        }
  }

  private func beginHomeExit(_ generation: UUID, flow: LaserInputFlow) {
    guard homeExit == nil, !flow.isClosing else { return }
    if flow.route == .liveSetup {
      guard flow.session?.inputConfiguration.sessionGeneration == generation,
            flow.leanTutorial.generation == generation, flow.leanTutorial.stage == .completed else { return }
    } else {
      guard flow.route == .replay else { return }
    }

    if reduceMotion {
      homeExit = .covering(generation)
      finishCover(generation, flow: flow)
    } else {
      withAnimation(.easeInOut(duration: 0.18), completionCriteria: .removed) {
        homeExit = .covering(generation)
      } completion: {
        finishCover(generation, flow: flow)
      }
    }
  }

  private func finishCover(_ generation: UUID, flow: LaserInputFlow) {
    guard homeExit == .covering(generation) else { return }
    if flow.route == .liveSetup,
       flow.session?.inputConfiguration.sessionGeneration != generation {
      homeExit = nil
      return
    }
    // Remove the old scene only after purple is opaque. This also retires its renderer.
    homeExit = .covered(generation)
    switch flow.route {
    case .liveSetup:
      Task {
        await flow.closeCompletedLeanTutorial(generation: generation)
        // A replacement session owns its own route. Do not leave it hidden.
        if homeExit == .covered(generation), flow.route == .liveSetup, !flow.isClosing {
          homeExit = nil
        }
      }
    case .replay:
      flow.leaveReplay()
    case .selection:
      revealHome()
    case .diagnostics:
      homeExit = nil
    }
  }

  private func revealHome() {
    guard case let .covered(generation) = homeExit else { return }
    if reduceMotion || scenePhase != .active {
      homeExit = nil
    } else {
      withAnimation(.easeInOut(duration: 0.22), completionCriteria: .removed) {
        homeExit = .revealing(generation)
      } completion: {
        if homeExit == .revealing(generation) { homeExit = nil }
      }
    }
  }
  /// A practice tick may be held during a binding flicker which the existing readiness
  /// policy still admits. Holding practice is not itself a request to return to setup.
  /// Once readiness really blocks, retain the original recovery presentation.
  static func showsLeanSetupRecovery(tutorial: LeanTutorial, session: GameSessionCoordinator) -> Bool {
    guard tutorial.stage == .freeLean else { return !tutorial.canExploreLean(in: session) }
    guard let input = session.inputContext, input.isActive,
          input.sessionGeneration == tutorial.generation,
          tutorial.roster == session.inputConfiguration.roster,
          tutorial.roster.allSatisfy({ input.calibrationRevisions[$0] != nil }),
          session.inputStatus == .running, session.preRoundTutorialPending else { return true }
    return !tutorial.canExploreLean(in: session) && !session.canStartLiveRound
  }
  /// Whether the camera setup stage is in front: always until a live round's game scene is
  /// mounted, then except while counting down, playing or showing results.
  static func showsSetupStage(_ session: GameSessionCoordinator?) -> Bool {
    guard let session, session.hasLiveRoundPlan || session.automaticSetup else { return true }
    // Keep the camera stage behind an active round, including during tracking recovery.
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
    } else {
      PlayView(onExit: { flow.leaveReplay() },
               onTutorialDiamondTimeFinished: FTUEOnboardingPreview.isRequested
                 ? { beginHomeExit($0, flow: flow) } : nil)
    }
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
