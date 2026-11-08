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
    /// Per-frame expiry check for live cutouts (`refreshLiveCutouts`).
    @State private var cutoutRefresh: EventSubscription?
    #if DEBUG
    @State private var preview = LaserApproachPreview()
    @State private var environmentPreview = EnvironmentPreview()
    @State private var cutoutFeed: SyntheticCutoutFeed?
    @State private var directorPreview = DirectorLaserPreview()
    @State private var robotDemo = RobotDemoDriver()
    @State private var robotDemoActive = false
    /// The demo's K03 mailbox (`-avatarPackets`); revoked on teardown.
    @State private var avatarMailbox: AvatarPoseMailbox?
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
            // 3D avatar demo: `-robotDemo [scenario]` drives both mascots with SYNTHETIC,
            // time-varying body and joint data (no camera, no session, no lasers); see `RobotDemo`.
            if let only = RobotDemoDriver.requested() {
                scene.isLaserVisible = false
                do {
                    let input = try LaserReplayScript.load().input
                    guard let robots = try await installAvatars(calibrations: input.configuration.calibrations,
                                                                layout: input.configuration.playerPlaneLayout) else { return }
                    // 30 Hz poses shown at render rate, feet diagnostics on.
                    robots.smoothing = 0.03
                    robots.diagnosticsEnabled = true
                    let sequence = RobotDemoSequence(configuration: input.configuration,
                                                     cameraGeometryRevision: input.cameraGeometryRevision, only: only)
                    if arguments.contains("-avatarPackets") {
                        // K03 path: the demo's frames as labelled SYNTHETIC D06 packets through the
                        // bounded latest-only mailbox, drained once per render tick.
                        let source = SyntheticAvatarSource(configuration: input.configuration,
                                                           cameraGeometryRevision: input.cameraGeometryRevision)
                        let mailbox = AvatarPoseMailbox(maxAge: 0.25)
                        mailbox.publish(source.status)
                        avatarMailbox = mailbox
                        robotDemo.start(on: content, sequence: sequence, render: { now in
                            robots.apply(mailbox.drain(now: now), now: now)
                            robots.render(now: now)
                        }) { snapshot, joints in
                            mailbox.offer(source.output(snapshot, joints: joints))
                        }
                    } else {
                        robotDemo.start(on: content, sequence: sequence, render: { robots.render(now: $0) }) {
                            robots.apply($0, joints: $1)
                        }
                    }
                    robotDemoActive = true
                } catch { startupError = String(describing: error) }
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
                // `-robotReplay`: the Lemon (P1) and Tangerine (P2) mascots stand in place of the
                // pictograms in the replay round, driven by its body snapshots through the
                // gameplay presenter, alongside the lasers and the vault. Presentation only.
                if ProcessInfo.processInfo.arguments.contains("-robotReplay") {
                    guard try await installAvatars(calibrations: script.input.configuration.calibrations,
                                                   layout: script.input.configuration.playerPlaneLayout) != nil else { return }
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
            // One HUD at a time: the Sketch gameplay HUD, or (Debug, `-replayDebugHUD`)
            // Jevon's text HUD for replay diagnostics. Results replaces either.
            if let session, session.summary == nil, !Self.showsReplayDebugHUD {
                GameplayHUD(model: hudModel(session), actions: hudActions(session))
            }
        }
        .overlay {
            if let final = session?.summary { ResultsView(summary: final, onRetry: retry) }
        }
        .overlay(alignment: .topLeading) {
            if let session, session.summary == nil, Self.showsReplayDebugHUD { ReplaySliceHUD(session: session) }
            if let startupError { Text("Replay could not start: \(startupError)").padding().background(.black).foregroundStyle(.white) }
            #if DEBUG
            if robotDemoActive {
                TimelineView(.periodic(from: .now, by: 0.2)) { context in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("SYNTHETIC POSE DEMO · not live tracking")
                            .font(.caption.monospaced().bold())
                        Text("\(robotDemo.scenario.rawValue + 1)/\(RobotDemoScenario.allCases.count)  \(robotDemo.scenario.title)")
                            .font(.callout.bold())
                        if let robots = scene.robotAvatars {
                            Text(robots.footPlanting ? "feet: planted + stepping" : "feet: LEGACY (root slides)")
                                .font(.caption.monospaced())
                            ForEach(PlayerID.allCases, id: \.self) { player in
                                if let d = robots.footDiagnostics[player] {
                                    Text("\(player == .player1 ? "P1" : "P2") \(d.line)").font(.caption2.monospaced())
                                }
                            }
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(.black.opacity(0.6), in: .rect(cornerRadius: 8))
                    .padding()
                    // The avatar layer is not observable: re-read it on every timeline tick.
                    .id(context.date)
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
            // Ending a round stays reachable: here while the session offers no pause
            // (the HUD's pause menu, which carries Leave Game, needs one), and always
            // with the debug HUD.
            if let session, session.phase == .running, Self.showsReplayDebugHUD || !hudActions(session).canPause {
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
            // Remove the avatars and their lights before this scene is replaced (Retry).
            scene.robotAvatars?.remove()
            scene.robotAvatars = nil
            #if DEBUG
            cutoutFeed?.stop()
            cutoutFeed = nil
            directorPreview.stop()
            directorPreview = DirectorLaserPreview()
            robotDemo.stop()
            avatarMailbox?.revoke()
            avatarMailbox = nil
            // Preview subscriptions capture their owners weakly; replacing them releases the subscriptions.
            preview = LaserApproachPreview()
            environmentPreview = EnvironmentPreview()
            #endif
            let previous = session
            Task { await previous?.stop() }
        }
    }

    #if DEBUG
    private static let showsReplayDebugHUD = ProcessInfo.processInfo.arguments.contains("-replayDebugHUD")
    #else
    private static let showsReplayDebugHUD = false
    #endif

    /// The session's player intents for the HUD. PENDING Jevon: when the
    /// session exposes pause and resume (its `GameClock`), pass them here; until
    /// then the HUD offers no pause.
    private func hudActions(_ session: GameSessionCoordinator) -> GameplayHUDActions {
        GameplayHUDActions(pause: nil, resume: nil, leave: { Task { await session.stop() } })
    }

    /// The HUD's view of the session's authoritative state and events.
    private func hudModel(_ session: GameSessionCoordinator) -> GameplayHUDModel {
        var collected: Int?
        var fixture = false
        #if DEBUG
        // `-diamondFixture`: the labelled synthetic Diamond Time (J05 pending), counted
        // from the same script the scene's fixture diamonds follow.
        if DiamondTimeFixture.isRequested, let state = session.state, state.phase == .diamondTime,
           let start = session.events.last(where: { $0.kind == .phaseChanged(.diamondTime) })?.gameTime {
            collected = DiamondTimeFixture.collectedCount(elapsed: state.gameTime - start)
            fixture = true
        }
        #endif
        return GameplayHUDModel(state: session.state, events: session.events, configuration: session.script.configuration,
                                activityDuration: session.script.activityDuration,
                                diamondsCollected: collected, diamondsAreFixture: fixture)
    }

    #if DEBUG
    /// Stands the mascots on the players' lanes, from the shared templates
    /// (loaded once per app run). `nil` if this view went away while loading:
    /// nothing is attached to a scene being discarded. Throws if an asset is
    /// missing or invalid, so the failure shows instead of silent pictograms.
    private func installAvatars(calibrations: [PlayerID: PlayerCalibration],
                                layout: PlayerPlaneLayout) async throws -> RobotAvatarLayer? {
        let templates = try await RobotAvatarLayer.sharedTemplates()
        guard !Task.isCancelled else { return nil }
        scene.robotAvatars?.remove()
        let robots = RobotAvatarLayer(scene: scene, calibrations: calibrations, layout: layout, templates: templates)
        // `-avatarFairness` (K04): mark the avatars' head tops, hands and soles beside the
        // human evidence markers and band edges, to compare them at the laser plane.
        robots.showsFairnessMarkers = ProcessInfo.processInfo.arguments.contains("-avatarFairness")
        // `-normalizedLasers` (D07 candidate, not approved): draw each player's laser bands in
        // their normalized avatar space for A/B comparison. Without it, beams stay as judged.
        robots.normalizesLaserBands = ProcessInfo.processInfo.arguments.contains("-normalizedLasers")
        scene.robotAvatars = robots
        return robots
    }

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
