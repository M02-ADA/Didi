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
    /// K05 attachment seam, PENDING E07/J03: given a fresh pose mailbox for
    /// each scene (Retry included), returns the producer's pump, which the
    /// render tick runs before it refreshes the avatars. With a source the
    /// mascots follow it in every configuration; without one, Release keeps
    /// its temporary pictograms. Never a synthetic source outside Debug.
    var avatarSource: (@MainActor (AvatarPoseMailbox) throws -> any AvatarPosePump)?
    /// CP2 attachment seam, PENDING Edo's production composition: shows the
    /// players' live cutouts. A mascot feed takes precedence over it.
    var cutoutSource: LiveCutoutSource?
    var onExit: (() -> Void)?
    var liveSession: GameSessionCoordinator?
    var onLiveRetry: (() -> Void)?

    @State private var generation = UUID()

    var body: some View {
        let roundGeneration = liveSession?.inputConfiguration.sessionGeneration ?? generation
        ReplayRoundView(generation: roundGeneration, avatarSource: avatarSource, cutoutSource: cutoutSource,
                        onExit: onExit, suppliedSession: liveSession,
                        retry: { if let onLiveRetry { onLiveRetry() } else { generation = UUID() } })
            .id(roundGeneration)
    }
}

/// Identity replacement disposes the old scene, driver, provider, clock and coordinator on Retry.
private struct ReplayRoundView: View {
    let generation: UUID
    let avatarSource: (@MainActor (AvatarPoseMailbox) throws -> any AvatarPosePump)?
    let cutoutSource: LiveCutoutSource?
    let onExit: (() -> Void)?
    let suppliedSession: GameSessionCoordinator?
    let retry: () -> Void
    @State private var scene = LaserScene()
    @State private var presentation = LaserReplayPresentation()
    @State private var session: GameSessionCoordinator?
    /// A live session mounted before its round plan exists (scene loaded during setup): starts the
    /// presentation on the first rendered frame after the plan is installed.
    @State private var pendingLiveStart: EventSubscription?
    @State private var startupError: String?
    @State private var leaving = false
    /// The per-frame host-clock tick: live cutout expiry and live avatars.
    @State private var frameRefresh: EventSubscription?
    #if DEBUG
    @State private var diamondReadout = DebugDiamondVisualReadout()
    @State private var preview = LaserApproachPreview()
    @State private var environmentPreview = EnvironmentPreview()
    @State private var hoverboardPreview = HoverboardPreview()
    @State private var cutoutFeed: SyntheticCutoutFeed?
    @State private var directorPreview = DirectorLaserPreview()
    @State private var robotDemo = RobotDemoDriver()
    @State private var robotDemoActive = false
    /// The demo's K03 attachment (`-avatarPackets`); revoked on teardown.
    @State private var demoAvatars: LiveAvatarPresenter?
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
            // Live cutouts and avatars update on the render loop, on the host clock their capture
            // times use, so stale input falls back or relaxes without waiting for a newer frame.
            frameRefresh = content.subscribe(to: SceneEvents.Update.self) { [weak scene] _ in
                let now = CACurrentMediaTime()
                scene?.refreshLiveCutouts(now: now)
                scene?.refreshLiveAvatars(now: now)
            }
            if let avatarSource {
                do {
                    let templates = try await RobotAvatarLayer.sharedTemplates()
                    guard !Task.isCancelled else { return }
                    let mailbox = AvatarPoseMailbox(maxAge: LiveAvatarPresenter.maximumPoseAge)
                    let pump = try avatarSource(mailbox)
                    // A DEBUG Solo Test tracks P1 only: Tangerine's lane is hidden, not shown untracked.
                    scene.attachLiveAvatars(mailbox: mailbox, templates: templates, pump: pump,
                        players: Set(suppliedSession?.inputConfiguration.roster ?? PlayerID.allCases),
                        jumpEvidence: suppliedSession.map { session in { [weak session] player, capturedAt in
                            // The judge's latest evidence, only when it is as fresh as the pose shown.
                            guard let snapshot = session?.latestSnapshot,
                                  abs(snapshot.capturedAt - capturedAt) <= LiveAvatarPresenter.maximumPoseAge,
                                  let sample = snapshot.players[player], sample.trackingStatus == .reliable else { return nil }
                            let g = sample.geometry
                            let soles = [g.leftSoleY, g.rightSoleY].filter { $0.validity == .valid }.compactMap(\.value)
                            return (soles.count == 2 ? soles.min() : nil,
                                    sample.jumpState.validity == .valid && sample.jumpState.phase == .airborne)
                        } })
                } catch {
                    startupError = String(describing: error)
                    return
                }
            } else if let cutoutSource {
                do {
                    try scene.attachLiveCutouts(cutoutSource.provider, layout: cutoutSource.layout,
                                                maximumDisplayAge: cutoutSource.maximumDisplayAge)
                } catch {
                    print("PlayView: live cutouts unavailable, keeping the pictograms: \(error)")
                }
            }
            // A live session is already started by App/flow. This view never constructs its source,
            // claims CP1, or installs replay fixtures/synthetic avatars in the live path.
            if let suppliedSession {
                guard !Task.isCancelled else { return }
                if suppliedSession.hasLiveRoundPlan {
                    session = suppliedSession
                    presentation.start(on: content, scene: scene, session: suppliedSession)
                } else {
                    // Loaded early (behind the camera setup screen), so the first heavy scene load and
                    // shader compile happen before anyone is linked or calibrated, not right after.
                    let liveContent = content
                    pendingLiveStart = content.subscribe(to: SceneEvents.Update.self) { [weak suppliedSession] _ in
                        guard let suppliedSession, suppliedSession.hasLiveRoundPlan, session == nil else { return }
                        session = suppliedSession
                        pendingLiveStart?.cancel(); pendingLiveStart = nil
                        presentation.start(on: liveContent, scene: scene, session: suppliedSession)
                    }
                }
                return
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
            // Launch with `-hoverboardPreview [turntable|bank] -hideDebugOverlay` to review the players' 3D hoverboard alone.
            if let mode = HoverboardPreview.requestedMode {
                await hoverboardPreview.start(on: content, scene: scene, mode: mode)
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
                        let mailbox = AvatarPoseMailbox(maxAge: LiveAvatarPresenter.maximumPoseAge)
                        mailbox.publish(source.status)
                        // The production presenter, ticked on the demo's own timeline.
                        let live = LiveAvatarPresenter(avatars: robots, mailbox: mailbox)
                        demoAvatars = live
                        robotDemo.start(on: content, sequence: sequence, render: { live.tick(now: $0) }) { snapshot, joints in
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
                #if DEBUG
                if DebugWristDiamondControls.requested(ProcessInfo.processInfo.arguments) {
                    let fixture = try DebugWristDiamondFixture.make(generation:generation)
                    let replay = try fixture.makeSession()
                    session = replay
                    try await replay.start()
                    guard !Task.isCancelled else { await replay.stop();return }
                    try await replay.advance(to:0.25) // active target, no outside/inside wrist delivered yet
                    presentation.debugDiamondReadout = diamondReadout
                    presentation.start(on:content,scene:scene,session:replay)
                    return
                }
                #endif
                var useSlice = ProcessInfo.processInfo.arguments.contains("-replaySlice")
                #if DEBUG
                useSlice = useSlice || DiamondTimeFixture.isRequested
                #endif
                let base = try useSlice ? LaserReplayScript.load() : LaserReplayScript.complete()
                let script = try base.freshRound(generation: generation)
                #if DEBUG
                // The Lemon (P1) and Tangerine (P2) mascots stand in place of the pictograms in the
                // replay round, driven by its body snapshots through the gameplay presenter (the
                // DEBUG bridge), alongside the lasers and the vault. Presentation only.
                if scene.liveAvatars == nil, scene.liveCutouts == nil {
                    guard try await installAvatars(calibrations: script.input.configuration.calibrations,
                                                   layout: script.input.configuration.playerPlaneLayout) != nil else { return }
                }
                #endif
                let replay = try LaserReplayDriver.makeSession(script: script)
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
            if let session, session.summary == nil, !Self.showsReplayDebugHUD, let model = hudModel(session) {
                GameplayHUD(model: model, actions: hudActions(session))
            }
        }
        .overlay {
            if let final = session?.summary { ResultsView(summary: final, onRetry: retry, onHome: homeAction) }
        }
        .safeAreaInset(edge: .bottom) {
            // Results carry their own Back to Home (the same `leave`).
            if onExit != nil, session?.summary == nil {
                Button("Back to input selection", systemImage: "chevron.backward") { leave() }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(leaving).accessibilityIdentifier("leaveReplay")
                .padding(.bottom, 8)
            }
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
        .overlay(alignment: .bottom) {
            #if DEBUG
            if let session, session.isDebugWristPreview, session.summary == nil {
                DebugWristDiamondControls(session:session,readout:diamondReadout).padding(.bottom,100)
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
            pendingLiveStart?.cancel(); pendingLiveStart = nil
            presentation.stop()
            // No gameplay sound outlives its scene (Retry, Home, teardown).
            AudioService.shared.stopEffects()
            frameRefresh?.cancel()
            frameRefresh = nil
            // Release the cutout consumer and revoke any upload still on the GPU
            // before this scene is replaced (Retry).
            scene.detachLiveCutouts()
            // Revoke any pose attachment and remove the avatars and their lights
            // before this scene is replaced (Retry).
            scene.detachLiveAvatars()
            #if DEBUG
            cutoutFeed?.stop()
            cutoutFeed = nil
            directorPreview.stop()
            directorPreview = DirectorLaserPreview()
            robotDemo.stop()
            demoAvatars?.stop()
            demoAvatars = nil
            // Preview subscriptions capture their owners weakly; replacing them releases the subscriptions.
            preview = LaserApproachPreview()
            environmentPreview = EnvironmentPreview()
            hoverboardPreview.stop()
            hoverboardPreview = HoverboardPreview()
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

    /// Results › Back to Home, when this round has somewhere to return to.
    private var homeAction: (() -> Void)? {
        guard onExit != nil else { return nil }
        return { leave() }
    }

    /// Leaves the round: the session stops first, then the flow moves on
    /// (Jevon's input-selection exit, also Results › Back to Home). Once only.
    private func leave() {
        guard let onExit, !leaving else { return }
        leaving = true
        AudioService.shared.play(.uiTap)
        Task { @MainActor in
            await session?.stop()
            presentation.stop()
            onExit()
        }
    }

    /// Live pause/continue intents go to the session. Replay retains its fixture-driven controls.
    private func hudActions(_ session: GameSessionCoordinator) -> GameplayHUDActions {
        GameplayHUDActions(pause: session.isReplay ? nil : { session.pauseLiveRound() },
                           resume: session.isReplay ? nil : { session.continueLiveRound() },
                           leave: { Task { await session.stop() } })
    }

    /// The HUD's view of the session's authoritative state and events.
    private func hudModel(_ session: GameSessionCoordinator) -> GameplayHUDModel? {
        guard let configuration = session.configuration else { return nil }
        var collected: Int? = session.isCompleteReplay || session.hasWristDiamondPlan ? session.diamondsCollected : nil
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
        return GameplayHUDModel(state: session.state, events: session.events, configuration: configuration,
                                activityDuration: session.activityDuration,
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
        // D07 presentation: draw each player's laser bands in their normalized avatar
        // space, so beams meet the fixed-size mascots where they meet the players and a
        // shared beam lines up. Display only. DEBUG `-judgedLaserBands` draws the judged
        // bands instead, for A/B comparison.
        #if DEBUG
        robots.normalizesLaserBands = !ProcessInfo.processInfo.arguments.contains("-judgedLaserBands")
        #else
        robots.normalizesLaserBands = true
        #endif
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
