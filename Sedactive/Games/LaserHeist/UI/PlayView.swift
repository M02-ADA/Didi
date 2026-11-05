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
    #if DEBUG
    /// Debug-only Live Avatar Lab (front camera → rear-view 3D robot). While it is
    /// open the replay round is torn down, and the lab covers the whole app,
    /// so no other camera or round runs at the same time.
    @State private var labOpen = ProcessInfo.processInfo.arguments.contains("-liveAvatarLab")
    #else
    private let labOpen = false
    #endif

    var body: some View {
        Group {
            if labOpen {
                Color.black.ignoresSafeArea()
            } else {
                ReplayRoundView(generation: generation, retry: { generation = UUID() })
                    .id(generation)
            }
        }
        #if DEBUG
        .overlay(alignment: .bottomLeading) {
            if !labOpen {
                Button("Live Avatar Lab") { labOpen = true }
                    .buttonStyle(.borderedProminent)
                    .padding()
            }
        }
        .fullScreenCover(isPresented: $labOpen) {
            LiveAvatarLabView { labOpen = false }
        }
        #endif
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
    /// Per-frame expiry check for live cutouts (`refreshLiveCutouts`).
    @State private var cutoutRefresh: EventSubscription?
    #if DEBUG
    @State private var preview = LaserApproachPreview()
    @State private var environmentPreview = EnvironmentPreview()
    @State private var cutoutFeed: SyntheticCutoutFeed?
    @State private var directorPreview = DirectorLaserPreview()
    @State private var robotDemo = RobotDemoDriver()
    @State private var robotDemoActive = false
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
            // Live cutouts expire on the render loop, on the host clock their capture times use,
            // so a cutout older than its agreed freshness limit falls back without a newer frame.
            cutoutRefresh = content.subscribe(to: SceneEvents.Update.self) { [weak scene] _ in
                scene?.refreshLiveCutouts(now: CACurrentMediaTime())
            }
            // Optional world-construction guides. Replay body markers live in the presentation adapter.
            #if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("-showWorldGuides") {
                content.add(PoseDebugOverlay.make(for: scene))
            }
            // Launch with `-syntheticCutouts <scenario>` to show synthetic CP2 player
            // cutouts through the production presenter. Debug-only preview: its
            // synthetic bodies would disagree with the replay's, so it runs with the
            // laser approach (or environment) preview instead of the replay round.
            // In the game, live cutouts and gameplay run together.
            let wantsCutoutPreview = SyntheticCutoutFeed.requestedScenario != nil
            if wantsCutoutPreview {
                cutoutFeed = SyntheticCutoutFeed.startIfRequested(
                    on: scene, debugMarkers: !arguments.contains("-hideDebugOverlay"))
            }
            // Launch with `-environmentPreview <mode>` to review the corridor,
            // vault door and diamonds. Each preview replaces the gameplay driver.
            if let mode = EnvironmentPreview.requestedMode {
                environmentPreview.start(on: content, scene: scene, mode: mode)
                return
            }
            // Launch with `-directorLaserPreview` to drive the gameplay presenter from
            // real LaserWaveDirector output (per-player bands, offsets, overlap).
            if DirectorLaserPreview.isRequested {
                directorPreview.start(on: content, scene: scene)
                return
            }
            // 3D robot demo: `-robotDemo [scenario]` drives both robots with SYNTHETIC,
            // time-varying body and joint data (no camera, no session, no lasers); see `RobotDemo`.
            if let only = RobotDemoDriver.requested() {
                scene.isLaserVisible = false
                if let input = try? LaserReplayScript.load().input, let template = await RobotAvatarLayer.loadTemplate() {
                    let robots = RobotAvatarLayer(scene: scene, calibrations: input.configuration.calibrations,
                                                  layout: input.configuration.playerPlaneLayout, template: template)
                    scene.robotAvatars = robots
                    robotDemo.start(on: content, sequence: RobotDemoSequence(
                        configuration: input.configuration, cameraGeometryRevision: input.cameraGeometryRevision, only: only)) {
                        robots.apply($0, joints: $1)
                    }
                    robotDemoActive = true
                }
                return
            }
            if wantsCutoutPreview || arguments.contains("-laserArtworkPreview") || arguments.contains(where: {
                $0 == "-laserGateState" || $0.hasPrefix("-laserPreview")
            }) {
                preview.start(on: content, scene: scene)
                return
            }
            #endif
            do {
                guard !Task.isCancelled else { return }
                let script = try LaserReplayScript.load().freshRound(generation: generation)
                #if DEBUG
                // 3D robot in the replay round: `-robotReplay` stands the robots in place of the
                // pictograms, driven by the replay's body snapshots through the gameplay presenter.
                if arguments.contains("-robotReplay"), let template = await RobotAvatarLayer.loadTemplate() {
                    scene.robotAvatars = RobotAvatarLayer(scene: scene, calibrations: script.input.configuration.calibrations,
                                                          layout: script.input.configuration.playerPlaneLayout, template: template)
                }
                #endif
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
            #if DEBUG
            if robotDemoActive {
                TimelineView(.periodic(from: .now, by: 0.2)) { _ in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("SYNTHETIC POSE DEMO · not live tracking")
                            .font(.caption.monospaced().bold())
                        Text("\(robotDemo.scenario.rawValue + 1)/\(RobotDemoScenario.allCases.count)  \(robotDemo.scenario.title)")
                            .font(.callout.bold())
                    }
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(.black.opacity(0.6), in: .rect(cornerRadius: 8))
                    .padding()
                }
            }
            if cutoutFeed != nil, !ProcessInfo.processInfo.arguments.contains("-hideDebugOverlay") {
                TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                    Text(cutoutStatus)
                        .font(.caption.monospaced())
                        .foregroundStyle(.white)
                        .padding(8)
                        .background(.black.opacity(0.6), in: .rect(cornerRadius: 6))
                        .padding()
                }
            }
            #endif
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
            cutoutRefresh?.cancel()
            cutoutRefresh = nil
            // Release the cutout consumer and revoke any upload still on the GPU
            // before this scene is replaced (Retry).
            scene.detachLiveCutouts()
            #if DEBUG
            cutoutFeed?.stop()
            cutoutFeed = nil
            directorPreview.stop()
            directorPreview = DirectorLaserPreview()
            robotDemo.stop()
            scene.robotAvatars?.remove()
            // Preview subscriptions capture their owners weakly; replacing them releases the subscriptions.
            preview = LaserApproachPreview()
            environmentPreview = EnvironmentPreview()
            #endif
            let previous = session
            Task { await previous?.stop() }
        }
    }

    #if DEBUG
    /// Which source frame each player shows, for the synthetic cutout preview.
    private var cutoutStatus: String {
        guard let presenter = scene.liveCutouts else { return "cutouts detached" }
        let players = PlayerID.allCases.map { id in
            "\(id == .player1 ? "P1" : "P2") \(presenter.displayed[id].map { "frame \($0.frameID)" } ?? "pictogram")"
        }
        let d = presenter.diagnostics
        return (players + ["shown \(d.activations)  not current \(d.notCurrent)  fallbacks \(d.fallbacks)  rejected \(cutoutFeed?.rejectedOffers ?? 0)"])
            .joined(separator: "\n")
    }
    #endif
}

#Preview(traits: .landscapeLeft) {
    PlayView()
}
