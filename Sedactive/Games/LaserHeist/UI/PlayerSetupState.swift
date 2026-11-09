//
//  PlayerSetupState.swift
//  Sedactive
//
//  Created by Edward Geraldo Kristian on 25/10/26.
//

import Foundation

/// A copy/affordance projection, never another source of binding or calibration state.
nonisolated struct PlayerSetupState: Equatable, Sendable {
    enum Action: Equatable, Sendable { case bind, confirmPlayers, calibrate, confirmCandidate }
    let title: String
    let instruction: String
    let action: Action?
    let buttonTitle: String?

    init(phase: LaserSetupPhase) {
        switch phase {
        case .inactive:
            (title, instruction, action, buttonTitle) = ("Camera setup", "Preparing your session.", nil, nil)
        case .awaitingBinding:
            (title, instruction, action, buttonTitle) = ("Find your places", "With the iPad in landscape, face it together: P1 starts on your left and P2 on your right. Keep the iPad centred between you, both bodies fully in view, and stay in these places while linking.", .bind, "Link players")
        case .binding:
            (title, instruction, action, buttonTitle) = ("Linking both players", "Stay in your starting places while we find the pair.", nil, nil)
        case .confirmPlayers:
            (title, instruction, action, buttonTitle) = ("Confirm your lanes", "Both players are linked. The player who started on your left controls P1, the left game lane; the player on your right controls P2. Keep these lanes even when you move.", .confirmPlayers, "Confirm P1 and P2")
        case .waitingForReliablePair:
            (title, instruction, action, buttonTitle) = ("Bring both players into view", "Stand where the iPad can see both of you clearly. Setup will continue when the pair is linked reliably.", nil, nil)
        case .awaitingCalibration:
            (title, instruction, action, buttonTitle) = ("Stand comfortably", "Stand upright and keep your head and both feet visible. Start when both players are ready to hold their standing position.", .calibrate, "Start standing calibration")
        case .calibrating:
            (title, instruction, action, buttonTitle) = ("Measuring your standing positions", "Stay upright together. You can cancel this step at any time.", nil, nil)
        case .reviewCandidate:
            (title, instruction, action, buttonTitle) = ("Review standing calibration", "Both players' standing measurements are ready to confirm. Movement checks come next.", .confirmCandidate, "Confirm standing calibration")
        case .awaitingGameplayReadiness:
            (title, instruction, action, buttonTitle) = ("Waiting for movement checks", "Standing calibration is accepted. A round can start only when both players' movement can be checked reliably.", nil, nil)
        case .blocked(let reason):
            let explanation = reason.contains("Crown and soles")
                ? "Head and foot measurements are not ready for play yet. No round has started. You can cancel calibration or leave setup."
                : "Calibration changed or could not be confirmed. Cancel this step, check both players, and collect standing measurements again. No round has started."
            (title, instruction, action, buttonTitle) = ("Calibration needs more information", explanation, nil, nil)
        case .restartRequired:
            (title, instruction, action, buttonTitle) = ("Start a fresh setup", "The previous player binding or standing measurements are no longer reliable. A fresh setup will link both players and collect standing measurements again.", nil, nil)
        }
    }
}
