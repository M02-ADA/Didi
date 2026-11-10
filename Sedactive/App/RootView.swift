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
  var body: some View {
    let flow = dependencies.inputFlow
    Group {
      switch flow.route {
      case .selection:
        // Sketch Home and Set Up (Kevin): presentation over the same flow.
        LaserHeistIntroView(flow: flow)
      case .replay:
        PlayView(onExit: { flow.leaveReplay() })
      case .liveSetup:
        if let session = flow.session, session.hasLiveRoundPlan {
          ZStack {
            PlayView(onExit: { Task { await flow.closeLiveSetup() } }, liveSession: session,
                     onLiveRetry: { Task { await flow.retryLiveSetup() } })
            // The countdown shows only the session's own remaining time (no second clock).
            if session.phase == .countdown, let remaining = session.liveReadiness?.countdownRemaining {
              RoundCountdownOverlay(value: Int(remaining.rounded(.up)))
            } else if session.phase != .running, session.summary == nil { liveSetupStage(flow) }
          }
        } else { liveSetupStage(flow) }
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
    .onChange(of: scenePhase) { _, phase in
      if phase == .background { Task { await flow.handleBackground() } }
    }
  }
}

/// Jevon's setup controls on the Sketch "stand here" stage (Kevin's presentation).
@MainActor
private func liveSetupStage(_ flow: LaserInputFlow) -> some View {
  CalibrationStageView(onBack: { Task { await flow.closeLiveSetup() } }) {
    PlayerSetupView(flow: flow, isOverlay: true)
  }
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
