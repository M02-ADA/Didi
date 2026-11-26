//
//  LaserHeistIntroView.swift
//  Sedactive
//

import SwiftUI

/// Presents Home, the intro video and the iPad placement instructions.
/// The placement check button asks LaserInputFlow to start camera setup.
struct LaserHeistIntroView: View {
    let flow: LaserInputFlow
    @Environment(GameplayHighScore.self) private var highScore
    /// DEBUG: opens the real-camera game scene preview (Edo's PR #31 route,
    /// owned by `ContentView`); `nil` hides the entry.
    var onInGameCamera: (() -> Void)? = nil
    var onCalibrationEntrance: (Bool) -> Void = { _ in }
    @State private var screen: Screen = .home

    enum Screen: Equatable {
        case home
        case introVideo
        case setup
    }

    var body: some View {
        ZStack {
            switch screen {
            case .home:
                HomeView(highScore: highScore.highScore, onStart: {
                    flow.cancelLeanTutorialReplay()
                    show(.introVideo)
                }, onReplayTutorial: {
                    guard flow.requestLeanTutorialReplay() else { return }
                    // The actual corridor/FTUE needs accepted setup. Help skips the story detour,
                    // not mode selection, camera binding, calibration or readiness.
                    show(.setup)
                })
                    .overlay(alignment: .bottom) { homeOptions }
                    .transition(.opacity)
            case .introVideo:
                // The video has its own sound: menu music pauses for it and resumes after.
                IntroVideoView {
                    AudioService.shared.setMusic(.menu)
                    screen = .setup
                }
                .onAppear { AudioService.shared.setMusic(nil) }
                .transition(.opacity)
            case .setup:
                SetupInstructionView(onBack: backFromSetup, onNext: startCalibration)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: screen)
        .background(LaserHeistDesign.night)
        .preferredColorScheme(.dark)
        .onAppear {
            AudioService.shared.setMusic(.menu)
            if flow.consumePlacementReturn() { screen = .setup }
        }
        .onChange(of: flow.tutorialReplayRequested) { _, pending in
            if !pending, flow.route == .selection { screen = .home }
        }
        .onDisappear { flow.cancelLeanTutorialReplay() }
    }

    private func show(_ next: Screen) {
        AudioService.shared.play(.uiTap)
        screen = next
    }

    private func backFromSetup() {
        flow.cancelLeanTutorialReplay()
        show(.home)
    }

    private func startCalibration(showsMascot: Bool) {
        guard flow.canStartLive else { return }
        AudioService.shared.play(.uiTap)
        #if DEBUG
        // Explicit Simulator visual QA only. Reuse the existing synthetic FTUE fixture;
        // production always follows the real setup path below.
        if FTUEOnboardingPreview.isRequested ||
            (ProcessInfo.processInfo.arguments.contains("-homeHelpFTUEPreview") && flow.tutorialReplayRequested) {
            if flow.tutorialReplayRequested { LeanFTUEPreviewLaunch.requestManualReplay() }
            flow.showReplay()
            return
        }
        #endif
        // In the mode chosen on Home (TEMPORARY selector; always co-op in Release).
        onCalibrationEntrance(showsMascot)
        Task { await flow.startSelectedSetup() }
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
            #if DEBUG
            if HomeView.showsDebugTools {
                // TEMPORARY player-mode selector for testing (remove with `LaserInputFlow`'s selector
                // section). Chosen here before starting; the setup and round keep it.
                if flow.canSelectPlayerMode || flow.selectsSoloPractice {
                    Picker("Players", selection: Binding(get: { flow.selectsSoloPractice },
                                                         set: { flow.selectPlayerMode(soloPractice: $0) })) {
                        Text("2 Players · Co-op").tag(false)
                        Text("1 Player · Solo Practice").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 420)
                    .disabled(!flow.canSelectPlayerMode)
                    .accessibilityIdentifier("playerModeSelector")
                    .accessibilityHint("Temporary testing option. Start begins camera setup in this mode.")
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
                    Button("Reset Lean tutorial") { flow.leanTutorial.resetForNextPlay() }
                        .accessibilityIdentifier("resetLeanTutorial")
                    Button("Camera diagnostics") { flow.showDiagnostics() }
                        .accessibilityIdentifier("cameraDiagnostics")
                    if let onInGameCamera {
                        Button("Real camera · game scene preview", action: onInGameCamera)
                            .accessibilityIdentifier("chooseInGameCamera")
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(LaserHeistDesign.cream.opacity(0.85))
                .disabled(!flow.canStartLive)
            }
            #endif
        }
        .padding(.bottom, 28)
    }
}
