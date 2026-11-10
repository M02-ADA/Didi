//
//  ContentView.swift
//  Sedactive
//
//  Created by Edward Geraldo Kristian on 18/10/26.
//

import SwiftUI

struct ContentView: View {
  #if DEBUG
    @State private var showCameraDiagnostics =
      ProcessInfo.processInfo.arguments.contains("--camera-diagnostics")
      || ProcessInfo.processInfo.arguments.contains("--camera-diagnostics-run")
    private let dependencies = AppDependencies.shared
  #endif
  var body: some View {
    // LaserHeist journey (Kevin): Home, Set Up, calibration, round and Results.
    // PENDING: pass `calibration:` once Edo's producer and Jevon's step exist.
    LaserHeistFlowView()
      #if DEBUG
        .overlay(alignment: .topTrailing) {
          Button("Camera diagnostics") { showCameraDiagnostics = true }
          .buttonStyle(.bordered).padding()
        }
        .fullScreenCover(
          isPresented: $showCameraDiagnostics,
          onDismiss: {
            Task { await dependencies.cameraDiagnostics.stopAndExport() }
          }
        ) {
          LiveInputDiagnosticsView(model: dependencies.cameraDiagnostics)
        }
      #endif
  }
}

#Preview {
  ContentView()
}
