//
//  SedactiveApp.swift
//  Sedactive
//
//  Created by Edward Geraldo Kristian on 18/10/26.
//

import OSLog
import SwiftUI
import UIKit

@main
struct SedactiveApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .background { LandscapeSceneRequest() }
        }
    }
}

/// Targets the window SwiftUI actually mounted, including scenes on external displays.
private struct LandscapeSceneRequest: UIViewRepresentable {
    @Environment(\.scenePhase) private var scenePhase

    func makeUIView(context: Context) -> SceneView {
        SceneView()
    }

    func updateUIView(_ view: SceneView, context: Context) {
        view.isSceneActive = scenePhase == .active
    }

    final class SceneView: UIView {
        var isSceneActive = false {
            didSet {
                if isSceneActive && !oldValue { requestLandscape() }
            }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if isSceneActive { requestLandscape() }
        }

        private func requestLandscape() {
            guard let scene = window?.windowScene,
                  !scene.effectiveGeometry.interfaceOrientation.isLandscape else { return }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape)) { error in
                Logger(subsystem: "com.Edward-Kristian.Sedactive", category: "Orientation")
                    .notice("Landscape request declined: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
