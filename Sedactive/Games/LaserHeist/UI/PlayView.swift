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
    @State private var generation = UUID()

    var body: some View {
        ReplayRoundView(generation: generation, retry: { generation = UUID() })
            .id(generation)
    }
}

/// Identity replacement disposes the old scene, driver, provider, clock and coordinator on Retry.
private struct ReplayRoundView: View {
    let generation: UUID
    let retry: () -> Void
    @State private var scene = LaserScene()
    @State private var presentation = LaserReplayPresentation()
    @State private var session: GameSessionCoordinator?
    @State private var startupError: String?
    #if DEBUG
    @State private var preview = LaserApproachPreview()
    @State private var environmentPreview = EnvironmentPreview()
    #endif

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
            scene.installVaultDoor(await LaserScene.loadVaultDoorArtwork())
            scene.installDiamondArt(await LaserScene.loadDiamondArtwork())
            content.add(scene.root)
            // Optional world-construction guides. Replay body markers live in the presentation adapter.
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-showWorldGuides") {
                content.add(PoseDebugOverlay.make(for: scene))
            }
            // Launch with `-environmentPreview <mode>` to review the corridor,
            // vault door and diamonds. Each preview replaces the gameplay driver.
            if let mode = EnvironmentPreview.requestedMode {
                environmentPreview.start(on: content, scene: scene, mode: mode)
                return
            }
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("-laserArtworkPreview") || arguments.contains(where: {
                $0 == "-laserGateState" || $0.hasPrefix("-laserPreview")
            }) {
                preview.start(on: content, scene: scene)
                return
            }
            #endif
            do {
                guard !Task.isCancelled else { return }
                let script = try LaserReplayScript.load().freshRound(generation: generation)
                let replay = GameSessionCoordinator(script: script)
                session = replay
                try await replay.start()
                guard !Task.isCancelled else { await replay.stop(); return }
                presentation.start(on: content, scene: scene, session: replay)
            } catch { startupError = String(describing: error) }
        }
        .ignoresSafeArea()
        .background(.black)
        .overlay {
            if let final = session?.summary { ResultsView(summary: final, onRetry: retry) }
        }
        .overlay(alignment: .topLeading) {
            if let session, session.summary == nil { ReplaySliceHUD(session: session) }
            if let startupError { Text("Replay could not start: \(startupError)").padding().background(.black).foregroundStyle(.white) }
        }
        .overlay(alignment: .bottomTrailing) {
            if let session, session.phase == .running {
                Button("End round") { Task { await session.stop() } }
                    .buttonStyle(.borderedProminent)
                    .padding()
                    .accessibilityIdentifier("endRound")
            }
        }
        .onChange(of: session?.summary?.sessionGeneration) { _, final in
            if final != nil { presentation.stop() }
        }
        .onDisappear {
            presentation.stop()
            #if DEBUG
            // Preview subscriptions capture their owners weakly; replacing them releases the subscriptions.
            preview = LaserApproachPreview()
            environmentPreview = EnvironmentPreview()
            #endif
            let previous = session
            Task { await previous?.stop() }
        }
    }
}

#Preview(traits: .landscapeLeft) {
    PlayView()
}
