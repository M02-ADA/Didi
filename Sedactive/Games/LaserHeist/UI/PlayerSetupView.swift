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
                } else if let setup = flow.session?.setup {
                    let model = PlayerSetupState(phase: setup.phase)
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
                }
                if let actionError { Text(actionError).foregroundStyle(.orange).accessibilityIdentifier("setupActionError") }
                if !flow.isStarting, flow.message != nil || flow.session?.setup?.phase == .restartRequired {
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
