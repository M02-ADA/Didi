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
    // Temporary entry for LH-11 until Edo wires real routing here.
    PlayView()
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
