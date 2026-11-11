//
//  CalibrationView.swift
//  Sedactive
//
//  Created by Edward Geraldo Kristian on 25/10/26.
//

import SwiftUI

struct CalibrationView: View {
    let setup: LaserSessionSetup
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Standing calibration", systemImage: "figure.stand")
                .font(.headline)
            if setup.phase == .calibrating {
                ProgressView(value: Double(setup.sampleCount), total: Double(StandingCollectionPolicyV1.sampleCount))
                    .accessibilityLabel("Standing calibration progress")
                Text("Keep your standing positions while measurements are collected.")
                    .foregroundStyle(.secondary)
            } else if setup.phase == .awaitingGameplayReadiness {
                Label("Standing calibration accepted", systemImage: "checkmark.circle")
            } else {
                Text("Both players' head and feet must be measured clearly before play.").foregroundStyle(.secondary)
            }
            if setup.canCancelCalibration {
                Button("Cancel calibration") { setup.cancelCalibration() }
                    .buttonStyle(.bordered).controlSize(.large)
                    .accessibilityIdentifier("cancelCalibration")
            }
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.06), in: .rect(cornerRadius: 16))
    }
}
