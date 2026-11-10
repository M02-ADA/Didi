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
      #if DEBUG
      if LiveAvatarSmokeModel.requested(ProcessInfo.processInfo.arguments) {
        LiveAvatarSmokeView(flow:flow,service:dependencies.bodyInput,bridge:dependencies.visionPoseBridge)
      } else { routedContent(flow:flow) }
      #else
      routedContent(flow:flow)
      #endif
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .background { Task { await flow.handleBackground() } }
    }
  }
  @ViewBuilder private func routedContent(flow: LaserInputFlow) -> some View {
      switch flow.route {
      case .selection:
        LaserInputSelectionView(flow: flow)
      case .replay:
        replayView(flow: flow)
      case .liveSetup:
        if let session = flow.session, session.hasLiveRoundPlan {
          ZStack {
            PlayView(avatarSource: { try VisionK03MailboxPump(bridge: dependencies.visionPoseBridge, mailbox: $0) },
                     onExit: { Task { await flow.closeLiveSetup() } }, liveSession: session,
                     onLiveRetry: { Task { await flow.retryLiveSetup() } })
            if session.phase != .running, session.summary == nil { PlayerSetupView(flow: flow) }
          }
        } else { PlayerSetupView(flow: flow) }
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

#Preview {
  ContentView()
}
