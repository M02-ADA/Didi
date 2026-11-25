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
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .background { GameWindowPreferences() }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            // Camera play and the tutorial can run for minutes without a touch.
            UIApplication.shared.isIdleTimerDisabled = phase != .background
        }
    }
}

/// Targets the window SwiftUI actually mounted, including scenes on external displays.
private struct GameWindowPreferences: UIViewRepresentable {
    @Environment(\.scenePhase) private var scenePhase

    func makeUIView(context: Context) -> SceneView {
        let view = SceneView()
        view.isUserInteractionEnabled = false
        return view
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
            if traitCollection.userInterfaceIdiom == .pad {
                // Keep the game above 70% of its design size where the window manager allows it.
                let artboard = LaserHeistDesign.artboard
                window?.windowScene?.sizeRestrictions?.minimumSize = CGSize(
                    width: (artboard.width * 0.7).rounded(.up),
                    height: (artboard.height * 0.7).rounded(.up))
            }
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
