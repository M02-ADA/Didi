//
//  LaserHeistIntroView.swift
//  Sedactive
//

import SwiftUI

/// The Sketch Home and the two "Put your iPad on the Floor" steps, shown on
/// `LaserInputFlow`'s selection route. Which of these screens shows is local
/// presentation state only: the route, the input source and every session
/// belong to `LaserInputFlow` (Jevon). The last step's check button asks the
/// flow to start camera setup; the replay demo and Debug diagnostics stay one
/// tap away on Home.
struct LaserHeistIntroView: View {
    let flow: LaserInputFlow
    /// DEBUG: opens the real-camera game scene preview (Edo's PR #31 route,
    /// owned by `ContentView`); `nil` hides the entry.
    var onInGameCamera: (() -> Void)? = nil
    @State private var screen: Screen = .home

    enum Screen: Equatable {
        case home
        case setup(SetupInstructionView.Step)
    }

    var body: some View {
        ZStack {
            switch screen {
            case .home:
                HomeView(bestScore: nil) { show(.setup(.holdIPad)) }
                    .overlay(alignment: .bottom) { homeOptions }
                    .transition(.opacity)
            case .setup(let step):
                SetupInstructionView(step: step, onBack: { back(from: step) }, onNext: { next(from: step) })
                    .id(step)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: screen)
        .background(LaserHeistDesign.night)
        .preferredColorScheme(.dark)
        .onAppear { AudioService.shared.setMusic(.menu) }
    }

    private func show(_ next: Screen) {
        AudioService.shared.play(.uiTap)
        screen = next
    }

    private func back(from step: SetupInstructionView.Step) {
        show(step == .holdIPad ? .home : .setup(.holdIPad))
    }

    private func next(from step: SetupInstructionView.Step) {
        guard step == .standIPadOnFloor else { return show(.setup(.standIPadOnFloor)) }
        guard flow.canStartLive else { return }
        AudioService.shared.play(.uiTap)
        Task { await flow.startLiveSetup() }
    }

    /// The flow's other choices and its messages (e.g. a camera that could not
    /// start), kept small under the Sketch layout rather than redesigning it.
    private var homeOptions: some View {
        VStack(spacing: 10) {
            if let message = flow.message {
                Label(message, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(LaserHeistDesign.cream)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 640)
                    .accessibilityIdentifier("inputFlowMessage")
            }
            HStack(spacing: 24) {
                Button {
                    AudioService.shared.play(.uiTap)
                    flow.showReplay()
                } label: {
                    Label("Replay demo", systemImage: "play.rectangle")
                }
                .accessibilityIdentifier("chooseReplay")
                .accessibilityHint("A sample round with no camera.")
                #if DEBUG
                Button("Camera diagnostics") { flow.showDiagnostics() }
                    .accessibilityIdentifier("cameraDiagnostics")
                if let onInGameCamera {
                    Button("Real camera · game scene preview", action: onInGameCamera)
                        .accessibilityIdentifier("chooseInGameCamera")
                }
                #endif
            }
            .buttonStyle(.plain)
            .font(.system(size: 17, weight: .semibold, design: .rounded))
            .foregroundStyle(LaserHeistDesign.cream.opacity(0.85))
            .disabled(!flow.canStartLive)
        }
        .padding(.bottom, 28)
    }
}
