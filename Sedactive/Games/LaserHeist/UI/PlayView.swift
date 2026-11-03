//
//  PlayView.swift
//  Sedactive
//
//  Created by Edward Geraldo Kristian on 25/10/26.
//

import SwiftUI
import RealityKit

/// Hosts the LaserHeist RealityKit world. Uses RealityKit's virtual camera,
/// not the device camera; live input arrives through Edo's pipeline instead.
struct PlayView: View {
    @State private var scene = LaserScene()
    @State private var presentation = LaserReplayPresentation()
    @State private var session: GameSessionCoordinator?
    @State private var startupError: String?

    var body: some View {
        RealityView { content in
            content.camera = .virtual
            let authored = await LaserScene.loadAuthoredEnvironment()
            #if DEBUG
            // Launch with `-showEditorPreviews` to overlay the Reality Composer Pro
            // stand-ins on the runtime players and laser and check that they line up.
            scene.installEnvironment(authored: authored, keepEditorPreviews: ProcessInfo.processInfo.arguments.contains("-showEditorPreviews"))
            #else
            scene.installEnvironment(authored: authored)
            #endif
            scene.installLaserArtwork(await LaserScene.loadLaserGateArtwork())
            content.add(scene.root)
            // Optional world-construction guides. Replay body markers live in the presentation adapter.
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-showWorldGuides") {
                content.add(PoseDebugOverlay.make(for: scene))
            }
            #endif
            do {
                let replay = GameSessionCoordinator(script: try LaserReplayScript.load())
                session = replay
                try await replay.start()
                presentation.start(on: content, scene: scene, session: replay)
            } catch { startupError = String(describing: error) }
        }
        .ignoresSafeArea()
        .background(.black)
        .overlay(alignment: .topLeading) {
            if let session { ReplaySliceHUD(session: session) }
            if let startupError { Text("Replay could not start: \(startupError)").padding().background(.black).foregroundStyle(.white) }
        }
        .onDisappear {
            presentation.stop()
            Task { await session?.stop() }
        }
    }
}

#Preview(traits: .landscapeLeft) {
    PlayView()
}
