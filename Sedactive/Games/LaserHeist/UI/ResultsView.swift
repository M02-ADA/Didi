//
//  ResultsView.swift
//  Sedactive
//
//  Created by Edward Geraldo Kristian on 25/10/26.
//

import SwiftUI

struct ResultsView: View {
    let summary: RoundSummary
    let onRetry: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(title).font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                Text("Game results").font(.headline).foregroundStyle(.secondary)
                HStack(spacing: 24) {
                    metric("Team score", "\(summary.teamScore)")
                    metric("Remaining health", "\(summary.remainingTeamHealth)")
                    metric("Vault progress", "\(summary.missionProgress) / \(summary.missionTarget)")
                }
                metric("Active game time", String(format: "%.1f s", summary.gameDuration))
                Text(RoundSummary.durationLimitation).font(.caption).foregroundStyle(.secondary)
                ForEach(summary.playerResults, id: \.playerID) { result in
                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(result.playerID == .player1 ? "Player 1" : "Player 2").font(.title2.bold())
                            Text("High laser avoidances: \(result.successfulHighAvoidances)")
                            Text("Low laser avoidances: \(result.successfulLowAvoidances)")
                            Text(LaserPlayerRoundResult.avoidanceLimitation).font(.caption).foregroundStyle(.secondary)
                            Text("Validated jump cycles: \(result.validatedJumpCycles.map(String.init) ?? "Unavailable")")
                            Text(LaserPlayerRoundResult.jumpCycleLimitation).font(.caption).foregroundStyle(.secondary)
                            Text("Requested challenge time: \(result.movementChallengeSeconds.map { String(format: "%.1f s", $0) } ?? "Unavailable")")
                            Text(LaserPlayerRoundResult.challengeTimeLimitation).font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Text("Vaults opened: \(summary.vaultsOpened) · timed out: \(summary.coopResults.filter { $0.outcome == .timedOut }.count)")
                Button("Retry round", action: onRetry)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("retryRound")
            }
            .padding(28)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }

    private var title: String {
        switch summary.outcome {
        case .completed: "Round complete"
        case .healthDepleted: "Team health depleted"
        case .vaultFailed: "Vault timed out"
        case .aborted: "Round ended early"
        case .technicalInterruption: "Round interrupted"
        }
    }

    private func metric(_ name: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.bold()).monospacedDigit()
        }
    }
}
