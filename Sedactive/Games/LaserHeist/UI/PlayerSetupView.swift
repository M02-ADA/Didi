//
//  PlayerSetupView.swift
//  Sedactive
//
//  Created by Edward Geraldo Kristian on 25/10/26.
//

import SwiftUI

struct PlayerSetupView: View {
    let flow: LaserInputFlow
    @State private var actionError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Label("CAMERA SETUP", systemImage: "person.2.fill")
                    .font(.headline).foregroundStyle(.orange)
                if let message = flow.message {
                    Text("Camera setup unavailable").font(.largeTitle.bold())
                    Text(message).font(.title3).accessibilityIdentifier("liveSetupError")
                } else if flow.isStarting {
                    ProgressView("Starting camera…").font(.title2).accessibilityIdentifier("liveSetupStarting")
                    Text("Allow camera access if prompted. You can leave setup while it starts.")
                } else if flow.session?.phase == .countdown,
                          let remaining = flow.session?.liveReadiness?.countdownRemaining {
                    Text("Get ready").font(.largeTitle.bold())
                    Text(remaining.rounded(.up), format: .number.precision(.fractionLength(0)))
                        .font(.largeTitle.bold()).monospacedDigit().accessibilityIdentifier("liveCountdown")
                } else if let setup = flow.session?.setup {
                    let model = PlayerSetupState(phase: flow.session?.phase == .restartRequired ? .restartRequired : setup.phase)
                    Text(model.title).font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("setupPhase")
                    Text(model.instruction).font(.title3).foregroundStyle(.secondary)
                    HStack(spacing: 16) {
                        lane("P1", side: "Left game lane")
                        lane("P2", side: "Right game lane")
                    }
                    if setup.canCancelCalibration || setup.phase == .awaitingGameplayReadiness {
                        CalibrationView(setup: setup)
                    }
                    if let action = model.action, let title = model.buttonTitle {
                        Button(title) { perform(action, setup: setup) }
                            .buttonStyle(.borderedProminent).tint(.orange).foregroundStyle(.black)
                            .controlSize(.large).accessibilityIdentifier("setupPrimaryAction")
                    }
                    if flow.session?.canStartLiveRound == true {
                        Button("Start round") {
                            do { try flow.session?.beginLiveCountdown() }
                            catch { actionError = "Both players need fresh movement checks before starting." }
                        }
                        .buttonStyle(.borderedProminent).controlSize(.large).accessibilityIdentifier("startLiveRound")
                    }
                    if flow.session?.hasLiveRoundPlan == true,
                       flow.session?.liveReadiness?.phase == .ready, flow.session?.liveFrameHostReady == false {
                        ProgressView("Preparing the corridor…").accessibilityIdentifier("liveScenePreparing")
                    }
                    if flow.session?.phase == .paused {
                        Text("Round paused").font(.title2.bold())
                        Text(flow.session?.recoveryNeedsPlan == true
                             ? "This round cannot continue yet. You can retry camera setup or leave."
                             : "Stand comfortably in your own space. Both players need reliable movement checks before continuing.")
                        Button("Continue") { flow.session?.continueLiveRound() }
                            .buttonStyle(.bordered).controlSize(.large).accessibilityIdentifier("continueLiveRound")
                    }
                }
                if let actionError { Text(actionError).foregroundStyle(.orange).accessibilityIdentifier("setupActionError") }
                if !flow.isStarting, flow.message != nil || flow.session?.setup?.phase == .restartRequired
                    || flow.session?.phase == .restartRequired || flow.session?.recoveryNeedsPlan == true {
                    Button("Retry camera setup") {
                        actionError = nil
                        Task { await flow.retryLiveSetup() }
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(flow.isClosing).accessibilityIdentifier("retryLiveSetup")
                }
                Button(flow.isClosing ? "Stopping camera…" : "Leave camera setup", role: .cancel) {
                    Task { await flow.closeLiveSetup() }
                }
                .buttonStyle(.bordered).controlSize(.large)
                .disabled(flow.isClosing).accessibilityIdentifier("leaveLiveSetup")
            }
            .frame(maxWidth: 680, alignment: .leading).padding(32).frame(maxWidth: .infinity)
        }
        .background(Color(red: 0.035, green: 0.055, blue: 0.11)).preferredColorScheme(.dark)
    }

    private func lane(_ name: String, side: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "figure.stand").font(.title).accessibilityHidden(true)
            Text(name).font(.title2.bold())
            Text(side).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(20)
        .background(.white.opacity(0.06), in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }

    private func perform(_ action: PlayerSetupState.Action, setup: LaserSessionSetup) {
        actionError = nil
        do {
            switch action {
            case .bind: try setup.beginBinding()
            case .confirmPlayers: try setup.confirmPlayers()
            case .calibrate: try setup.requestCalibration(id: UUID())
            case .confirmCandidate:
                guard let id = setup.candidateIDForConfirmation else { return }
                try setup.confirmCandidate(id: id)
            }
        } catch {
            actionError = "The setup conditions changed. Check that both players are in view and follow the current instruction."
        }
    }
}
