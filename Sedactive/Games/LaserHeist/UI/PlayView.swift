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
    var leanTutorial: LeanTutorial?

    @State private var generation = UUID()

    var body: some View {
        let roundGeneration = liveSession?.inputConfiguration.sessionGeneration ?? generation
        ReplayRoundView(generation: roundGeneration, avatarSource: avatarSource, cutoutSource: cutoutSource,
                        onExit: onExit, suppliedSession: liveSession, tutorial: leanTutorial,
                        retry: { if let onLiveRetry { onLiveRetry() } else { generation = UUID() } })
            .id(roundGeneration)
    }
}

/// The round view's heavy objects, each built on first use and kept for the view's identity.
///
/// PERFORMANCE (Kevin, 22 November 2026): SwiftUI evaluates a view's `@State` initial values every time
/// it re-creates the view VALUE, keeping only the first. During a live round the root view re-renders
/// on every frame (it reads the session's state, written each tick), so it re-created this view each
/// frame, and `@State private var scene = LaserScene()` built and threw away a whole scene and its
/// presentation every frame (about 30 ms in a Debug Simulator build,
/// `LaserSceneConstructionCostTests`). Behind one `@State` holder they are built once, lazily.
@MainActor
private final class RoundObjects {
    /// The live round's start, waiting for its plan (`pendingLiveStart`), with the content and the avatar
    /// feed it needs; all cleared once it fires or the view closes.
    var pendingLiveStart: EventSubscription?
    var liveContent: RealityViewCameraContent?
    var deferredAvatarFeed: (() throws -> any AvatarPosePump)?
    /// The FTUE's per-frame work (lean travel, practices, tutorial vault and Diamond Time), which needs
    /// the view's tutorial state. The render loop reaches it only through a weak `RoundObjects`, and the
    /// view clears it when it closes, so a finished round is never kept alive by it.
    var onFrame: ((_ now: Double, _ scene: LaserScene?) -> Void)?
    lazy var scene = LaserScene()
    lazy var presentation = LaserReplayPresentation()
    lazy var diamondFlights = DiamondHUDFlightModel()
    lazy var teamCallouts = LaserTeamCalloutModel()
    #if DEBUG
    lazy var heartPreview = HeartAnimationPreview()
    lazy var diamondReadout = DebugDiamondVisualReadout()
    lazy var preview = LaserApproachPreview()
    lazy var environmentPreview = EnvironmentPreview()
    lazy var hoverboardPreview = HoverboardPreview()
    lazy var finalVaultPreview = FinalVaultPreview()
    lazy var hitReactionPreview = LaserHitReactionPreview()
    lazy var gateConsolePreview = GateConsolePreview()
    lazy var directorPreview = DirectorLaserPreview()
    lazy var robotDemo = RobotDemoDriver()
    #endif
    init() {
        #if DEBUG
        LaserPerfMonitor.alive("RoundObjects.made", 1)
        #endif
    }
}

/// The round view's session, observable (the HUD and overlays follow it) and held apart from the
/// view so the RealityKit closures that set it capture it weakly.
@MainActor @Observable
private final class RoundSessionSlot {
    var session: GameSessionCoordinator?
}

/// Identity replacement disposes the old scene, driver, provider, clock and coordinator on Retry.
private struct ReplayRoundView: View {
    let generation: UUID
    let avatarSource: (@MainActor (AvatarPoseMailbox) throws -> any AvatarPosePump)?
    let cutoutSource: LiveCutoutSource?
    let onExit: (() -> Void)?
    let suppliedSession: GameSessionCoordinator?
    let tutorial: LeanTutorial?
    @State private var needsLeanProjection = true
    @Environment(\.scenePhase) private var scenePhase
    // Render subscriptions outlive the SwiftUI value that installed them. Read current lifecycle
    // through State storage instead of capturing that value's startup (inactive) environment.
    @State private var trainingSceneActive = false
    @State private var practicePresentation = FTUEPracticePresentation()
    @State private var heartTutorialDemo = HeartTutorialDemo()
    @State private var leanTravel = LeanTutorialTravel()
    @State private var collectiblePresentation = FTUECollectiblePresentation()
    @State private var tutorialVaultPractice: FTUEVaultPractice?
    @State private var tutorialVaultPresenter: GameplayScenePresenter?
    #if DEBUG
    @State private var vaultDiagnosticStart: Double?
    @State private var vaultDiagnosticInspected = false
    @State private var vaultPreviewSceneStatus = ""
    #endif
    @State private var tutorialDiamondTime: FTUEDiamondTimeSession?
    @State private var tutorialDiamondPresentation = LaserReplayPresentation()
    @State private var tutorialDiamondFlights = DiamondHUDFlightModel()
    @State private var tutorialHeartArt: HeartArt?
    let retry: () -> Void
    /// The round's scene, presentation and models, built once per round view (`RoundObjects`).
    @State private var objects = RoundObjects()
    private var scene: LaserScene { objects.scene }
    private var presentation: LaserReplayPresentation { objects.presentation }
    private var diamondFlights: DiamondHUDFlightModel { objects.diamondFlights }
    private var teamCallouts: LaserTeamCalloutModel { objects.teamCallouts }
    /// The round's session, in an observable holder that RealityKit closures capture weakly.
    @State private var sessionSlot = RoundSessionSlot()
    private var session: GameSessionCoordinator? {
        get { sessionSlot.session } nonmutating set { sessionSlot.session = newValue }
    }
    /// A live session mounted before its round plan exists (scene loaded during setup): starts the
    /// presentation on the first rendered frame after the plan is installed.
    private var pendingLiveStart: EventSubscription? {
        get { objects.pendingLiveStart } nonmutating set { objects.pendingLiveStart = newValue }
    }
    /// The live avatars' pose feed, attached with the round plan (see the avatar setup).
    private var deferredAvatarFeed: (() throws -> any AvatarPosePump)? {
        get { objects.deferredAvatarFeed } nonmutating set { objects.deferredAvatarFeed = newValue }
    }
    @State private var startupError: String?
    @State private var leaving = false
    /// The per-frame host-clock tick: live cutout expiry and live avatars.
    @State private var frameRefresh: EventSubscription?
    #if DEBUG
    @State private var leanPreview = LeanTutorial(defaults: FTUEOnboardingPreview.defaults ?? UserDefaults(suiteName: "LaserHeist.LeanFTUEPreview")!)
    @State private var previewLaserPractice: FTUELaserPractice?
    @State private var previewHeartTraining: HeartTrainingEncounter?
    @State private var leanPreviewConfiguration: LaserRoundConfiguration?
    @State private var leanPreviewInput: LeanFTUESyntheticInput?
    @State private var leanPreviewStart: (() -> Void)?
    @State private var leanPreviewTask: Task<Void, Never>?
    @State private var leanPreviewAudit = ""
    @State private var leanPreviewLayoutDone = false
    private var leanHeldStage: LeanTutorial.Stage? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-leanFTUEHold"), args.indices.contains(i + 1) else { return nil }
        return ["left", "right", "free"].contains(args[i + 1]) ? .freeLean : .introduction
    }
    private var leanRequestedLayout: Int {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-leanFTUELayout"), args.indices.contains(i + 1) else { return 0 }
        return args[i + 1] == "left" ? 1 : args[i + 1] == "right" ? 2 : 0
    }
    private var leanPreviewStatus: String {
        if leanPreview.isActive { return "SYNTHETIC FTUE PREVIEW · no camera · game not started" }
        if leanPreview.stage == .completed, session?.state != nil { return "SYNTHETIC replay · tutorial complete" }
        return "Preparing synthetic corridor…"
    }
    private var isLeanPreview: Bool {
        ProcessInfo.processInfo.arguments.contains("-leanFTUEPreview") || ProcessInfo.processInfo.arguments.contains("-homeHelpFTUEPreview")
    }
    private var isLeanPreviewSolo: Bool { ProcessInfo.processInfo.arguments.contains("-leanFTUESolo") }
    private var heartPreview: HeartAnimationPreview { objects.heartPreview }
    private var diamondReadout: DebugDiamondVisualReadout { objects.diamondReadout }
    private var preview: LaserApproachPreview { get { objects.preview } nonmutating set { objects.preview = newValue } }
    private var environmentPreview: EnvironmentPreview {
        get { objects.environmentPreview } nonmutating set { objects.environmentPreview = newValue }
    }
    private var hoverboardPreview: HoverboardPreview { get { objects.hoverboardPreview } nonmutating set { objects.hoverboardPreview = newValue } }
    private var finalVaultPreview: FinalVaultPreview { objects.finalVaultPreview }
    private var hitReactionPreview: LaserHitReactionPreview { objects.hitReactionPreview }
    private var gateConsolePreview: GateConsolePreview { objects.gateConsolePreview }
    @State private var cutoutFeed: SyntheticCutoutFeed?
    private var directorPreview: DirectorLaserPreview { get { objects.directorPreview } nonmutating set { objects.directorPreview = newValue } }
    @State private var verticalLaserPreview: VerticalLaserPreview?
    @State private var verticalLaserReplay: VerticalLaserReplay?
    private var robotDemo: RobotDemoDriver { objects.robotDemo }
    @State private var robotDemoActive = false
    /// The demo's K03 attachment (`-avatarPackets`); revoked on teardown.
    @State private var demoAvatars: LiveAvatarPresenter?
    #endif

    #if DEBUG
    private static let landscapePreview = ProcessInfo.processInfo.arguments.contains("-landscape")
    #endif

    private var world: some View {
        RealityView { content in
            content.camera = .virtual
            #if DEBUG
            LaserPerfMonitor.shared.sessionBegan()
            if let selected = TimingIndicatorControls.launchVariant { scene.selectTimingVariant(selected) }
            presentation.holdsTimingComparison = TimingIndicatorControls.isComparison
            #endif
            presentation.diamondFlights = diamondFlights
            presentation.teamCallouts = teamCallouts
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
            scene.installFinalVaultArt(await FinalVaultArt.load())
            content.add(scene.root)
            // Live cutouts and avatars update on the render loop, on the host clock their capture
            // times use, so stale input falls back or relaxes without waiting for a newer frame.
            // Captures only what it uses, weakly: never this view (`self`), whose state holds the round's
            // scene, presentation and session (see `RoundObjects`). The FTUE's per-frame work, which needs
            // this view's tutorial state, runs through `objects.onFrame` (cleared in `onDisappear`).
            let frameContent = content
            objects.onFrame = { now, scene in
                if let scene, let tutorial = activeTutorial {
                    leanTravel.update(scene: scene, tutorial: tutorial, generation: generation, at: now,
                        eligible: trainingSceneActive && (suppliedSession == nil || suppliedSession?.canStartLiveRound == true))
                }
                if let scene { updateHeartTraining(scene: scene, at: now); updateLaserPractice(scene: scene, at: now) }
                if let tutorial = activeTutorial {
                    let active = tutorial.isActive && !tutorial.isSuspended && trainingSceneActive
                        && (suppliedSession == nil || suppliedSession?.canStartLiveRound == true)
                    tutorial.progressJourney.update(stage: tutorial.stage, generation: generation, at: now, active: active)
                    if let scene {
                        updateTutorialVaultPractice(tutorial, scene: scene, at: now)
                        updateTutorialDiamondTime(tutorial, scene: scene, content: frameContent, at: now)
                    }
                } else {
                    if tutorialVaultPractice != nil { retireTutorialVaultPractice() }
                    if tutorialDiamondTime != nil { retireTutorialDiamondTime() }
                }
                if needsLeanProjection, wantsLeanProjection, let scene {
                    let viewport = presentation.pawBoardDiamonds.viewportFrame.size
                    if let fraction = LeanCueProjection.headTop(scene: scene, viewport: viewport, project: {
                        frameContent.project(point: $0, to: .named(DiamondHUDFlightModel.space))
                    }) {
                        tutorial?.setHeadTop(fraction, generation: generation)
                        #if DEBUG
                        if isLeanPreview { leanPreview.setHeadTop(fraction, generation: generation) }
                        #endif
                        needsLeanProjection = false
                    }
                }
                if let scene, let tutorial, let suppliedSession, tutorial.isPractising || tutorial.collection != nil {
                    // Session readiness drives travel. A fresh CP1/K03 sample still gates contact.
                    let ready = tutorial.canExploreLean(in: suppliedSession)
                    updateLeanAndCollectibles(tutorial, scene: scene, context: suppliedSession.inputContext,
                        input: suppliedSession.inputConfiguration, configuration: suppliedSession.configuration,
                        eligible: ready,
                        contactPlayers: tutorial.collection == nil ? nil : freshTutorialPlayers(suppliedSession, at: now),
                        at: now)
                }
                if activeTutorial?.collection == nil { collectiblePresentation.clear() }
                #if DEBUG
                if isLeanPreview, let scene, let input = leanPreviewInput {
                    if leanHeldStage != nil, !leanPreviewLayoutDone, !needsLeanProjection {
                        leanPreviewAudit = LeanFTUELayoutAudit.inspect(scene: scene, solo: isLeanPreviewSolo,
                            index: leanRequestedLayout, origin: presentation.pawBoardDiamonds.viewportFrame.origin) {
                            frameContent.project(point: $0, to: .named(DiamondHUDFlightModel.space))
                        }
                        leanPreviewLayoutDone = true
                    }
                    if leanHeldStage == nil, leanPreview.isPractising || leanPreview.collection != nil {
                        updateLeanAndCollectibles(leanPreview, scene: scene, context: input.context,
                            input: input.configuration, configuration: leanPreviewConfiguration, eligible: true,
                            contactPlayers: input.collectibleContactFixture, at: now)
                    }
                }
                #endif
            }
            #if DEBUG
            frameRefresh = content.subscribe(to: SceneEvents.Update.self) { [weak scene, weak heartPreview, weak sessionSlot, weak objects] _ in
                let now = CACurrentMediaTime()
                scene?.refreshLiveCutouts(now: now)
                PerfSpans.measure("avatars") { scene?.refreshLiveAvatars(now: now) }
                objects?.onFrame?(now, scene)
                heartPreview?.update(now: now)
                MaskBenchmark.recorder.renderTick(now) // no-op without `-maskBench`
                if LaserPerfMonitor.isEnabled {
                    LaserPerfMonitor.shared.frame(now: now, phase: Self.perfPhase(sessionSlot?.session), scene: scene)
                }
            }
            #else
            frameRefresh = content.subscribe(to: SceneEvents.Update.self) { [weak scene, weak objects] _ in
                let now = CACurrentMediaTime()
                scene?.refreshLiveCutouts(now: now)
                scene?.refreshLiveAvatars(now: now)
                objects?.onFrame?(now, scene)
            }
            #endif
            if let avatarSource {
                do {
                    let templates = try await RobotAvatarLayer.sharedTemplates()
                    guard !Task.isCancelled else { return }
                    let mailbox = AvatarPoseMailbox(maxAge: LiveAvatarPresenter.maximumPoseAge)
                    // Play Again (iPad, 12 November 2026): a live session mounted before its camera
                    // input starts must not take the pose lease yet. Starting the input retires any
                    // current lease (`CameraTrackingGate.reserveBodySession`); with the scene
                    // assets cached, the second round attached first and its mascots never moved.
                    // The mascots load now (warm-up behind the setup screen); their feed attaches
                    // with the round plan, always after the input has started.
                    let defersFeed = suppliedSession.map { !$0.hasLiveRoundPlan } ?? false
                    let pump = defersFeed ? nil : try avatarSource(mailbox)
                    if defersFeed { deferredAvatarFeed = { try avatarSource(mailbox) } }
                    // A DEBUG Solo Test tracks P1 only: Tangerine's lane is hidden, not shown untracked.
                    scene.attachLiveAvatars(mailbox: mailbox, templates: templates, pump: pump,
                        players: Set(suppliedSession?.inputConfiguration.roster ?? PlayerID.allCases),
                        liveEvidence: suppliedSession.map { session in { [weak session] player, capturedAt in
                            // The judge's latest evidence, only when it is as fresh as the pose shown.
                            guard let snapshot = session?.latestSnapshot,
                                  abs(snapshot.capturedAt - capturedAt) <= LiveAvatarPresenter.maximumPoseAge,
                                  let sample = snapshot.players[player], sample.trackingStatus == .reliable else { return nil }
                            let g = sample.geometry
                            let soles = [g.leftSoleY, g.rightSoleY].filter { $0.validity == .valid }.compactMap(\.value)
                            return LiveAvatarEvidence(lowerSoleY: soles.count == 2 ? soles.min() : nil,
                                airborne: sample.jumpState.validity == .valid && sample.jumpState.phase == .airborne,
                                centerX: g.centerX.validity == .valid ? g.centerX.value : nil)
                        } })
                    // Vault buttons are judged where the mascot's hand reaches (its console dock), when
                    // the mascots have consoles (they ride boards); otherwise the approved zones.
                    if scene.robotAvatars?.consoles.isEmpty == false {
                        suppliedSession?.vaultMascotReach = { [weak scene] player, capturedAt in
                            scene?.robotAvatars?.vaultReachShift(player, capturedAt: capturedAt)
                        }
                    } else {
                        suppliedSession?.vaultMascotReach = nil
                    }
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
                    // LIFECYCLE (Kevin, 22 November 2026, measured): RealityKit keeps an update handler's
                    // closure alive after `cancel()`, so this one captures only weak references: never this
                    // view or the content (held by `RoundObjects` until it is used or the view closes).
                    objects.liveContent = content
                    pendingLiveStart = content.subscribe(to: SceneEvents.Update.self) {
                        [weak suppliedSession, weak objects, weak sessionSlot] _ in
                        guard let suppliedSession, let objects, let sessionSlot, suppliedSession.hasLiveRoundPlan,
                              sessionSlot.session == nil, let liveContent = objects.liveContent else { return }
                        sessionSlot.session = suppliedSession
                        objects.pendingLiveStart?.cancel(); objects.pendingLiveStart = nil
                        objects.liveContent = nil
                        if let attach = objects.deferredAvatarFeed {
                            objects.deferredAvatarFeed = nil
                            do { objects.scene.attachLiveAvatarPump(try attach()) }
                            catch { print("PlayView: live avatar feed unavailable: \(error)") }
                        }
                        objects.presentation.start(on: liveContent, scene: objects.scene, session: suppliedSession)
                    }
                }
                return
            }
            // Optional world-construction guides. Replay body markers live in the presentation adapter.
            #if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            if isLeanPreview {
                let previewContent = content
                do {
                    let script = try LaserReplayScript.load().freshRound(generation: generation)
                    let input = script.input
                    let calibrations = input.configuration.calibrations.filter { !isLeanPreviewSolo || $0.key == .player1 }
                    var previewConfiguration = input.configuration.replacingCalibrations(calibrations)
                    if isLeanPreviewSolo { previewConfiguration.soloPlayer = .player1 }
                    let inputSource = LeanFTUESyntheticInput(configuration: previewConfiguration,
                        geometry: input.cameraGeometryRevision, tutorial: leanPreview,
                        roster: isLeanPreviewSolo ? [.player1] : PlayerID.allCases, hold: leanHeldStage != nil)
                    let templates = try await RobotAvatarLayer.sharedTemplates()
                    guard !Task.isCancelled else { return }
                    scene.attachLiveAvatars(mailbox: inputSource.mailbox, templates: templates, pump: inputSource,
                        players: Set(inputSource.roster))
                    inputSource.practice = { previewLaserPractice }
                    inputSource.onBodySnapshot = { packet, host in
                        try? previewLaserPractice?.receive(packet, at: host, maximumAge: LiveAvatarPresenter.maximumPoseAge)
                    }
                    leanPreviewInput = inputSource
                    scene.isLaserVisible = false
                    leanPreviewConfiguration = script.configuration
                    leanPreviewStart = {
                        leanPreviewTask = Task { @MainActor in
                            do {
                                scene.detachLiveAvatars(); leanPreviewInput = nil
                                guard try await installAvatars(calibrations: calibrations,
                                    layout: input.configuration.playerPlaneLayout) != nil, !Task.isCancelled else { return }
                                scene.players[.player2]?.isEnabled = !isLeanPreviewSolo
                                let replay = try LaserReplayDriver.makeSession(script: script)
                                session = replay
                                try await replay.start()
                                guard !Task.isCancelled else { await replay.stop(); return }
                                presentation.start(on: previewContent, scene: scene, session: replay)
                            } catch { startupError = String(describing: error) }
                        }
                    }
                    LeanFTUEPreviewLaunch.applyReset(to: leanPreview)
                    leanPreview.freezesIntroductionForLayout = leanHeldStage == .introduction
                    // Isolated returning-player review; never resets production first-play storage.
                    let manualReplay = LeanFTUEPreviewLaunch.consumeManualReplay()
                    if manualReplay && !FTUEOnboardingPreview.isRequested {
                        UserDefaults(suiteName: "LaserHeist.LeanFTUEPreview")!.set(true, forKey: LeanTutorial.completionKey)
                        UserDefaults(suiteName: "LaserHeist.LeanFTUEPreview")!.set(true, forKey: LeanTutorial.heartCompletionKey)
                        UserDefaults(suiteName: "LaserHeist.LeanFTUEPreview")!.set(true, forKey: LeanTutorial.jumpDuckCompletionKey)
                        UserDefaults(suiteName: "LaserHeist.LeanFTUEPreview")!.set(true, forKey: LeanTutorial.progressCompletionKey)
                    }
                    leanPreview.prepare(generation: generation, roster: inputSource.roster, replayRequested: manualReplay)
                    leanPreview.beginIfEligible(generation: generation, eligible: true)
                    if let held = leanHeldStage, held != .introduction {
                        leanPreview.showPracticeForLayout(held, generation: generation)
                    }
                    if leanPreview.stage == .completed { let start = leanPreviewStart; leanPreviewStart = nil; start?() }
                } catch { startupError = String(describing: error) }
                return
            }
            if HeartAnimationPreview.isRequested {
                do {
                    let input = try LaserReplayScript.load().input.configuration
                    _ = try await installAvatars(calibrations: input.calibrations, layout: input.playerPlaneLayout)
                    guard !Task.isCancelled else { return }
                    try await heartPreview.start(scene: scene, generation: generation)
                } catch { startupError = String(describing: error) }
                return // No replay coordinator, gameplay clock, body input or reward events.
            }
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
            // Launch with `-replay -gateConsolePreview [solo] [seconds]` to review the gates' wall consoles.
            if GateConsolePreview.isRequested {
                do {
                    let input = try LaserReplayScript.load().input
                    let (solo, heldAt) = GateConsolePreview.requested
                    let calibrations = input.configuration.calibrations.filter { !solo || $0.key == .player1 }
                    guard let robots = try await installAvatars(calibrations: calibrations,
                                                                layout: input.configuration.playerPlaneLayout) else { return }
                    if solo { scene.players[.player2]?.isEnabled = false }
                    scene.isLaserVisible = false
                    try gateConsolePreview.start(on: content, scene: scene, robots: robots,
                                                 configuration: input.configuration, heldAt: heldAt)
                } catch { startupError = String(describing: error) }
                return
            }
            // Launch with `-replay -hitReactionPreview [p1|p2|both] [high|low] …` to review the HIT zap.
            if LaserHitReactionPreview.isRequested {
                do {
                    let input = try LaserReplayScript.load().input
                    let request = LaserHitReactionPreview.requested
                    guard let robots = try await installAvatars(calibrations: input.configuration.calibrations,
                                                                layout: input.configuration.playerPlaneLayout) else { return }
                    hitReactionPreview.start(on: content, scene: scene, robots: robots, request: request)
                } catch { startupError = String(describing: error) }
                return
            }
            // Launch with `-replay -finalVaultPreview [solo] [seconds]` to review the final vault entry.
            if FinalVaultPreview.isRequested {
                do {
                    let input = try LaserReplayScript.load().input
                    let (solo, heldAt) = FinalVaultPreview.requested
                    let calibrations = input.configuration.calibrations.filter { !solo || $0.key == .player1 }
                    guard try await installAvatars(calibrations: calibrations,
                                                   layout: input.configuration.playerPlaneLayout) != nil else { return }
                    // Solo: Tangerine's lane is hidden, as in a live Solo Test.
                    if solo { scene.players[.player2]?.isEnabled = false }
                    finalVaultPreview.start(on: content, scene: scene, solo: solo, heldAt: heldAt)
                } catch { startupError = String(describing: error) }
                return
            }
            // Launch with `-replay -verticalLaserReplay [clear|hit|unavailable] [solo] [reduced] [seconds]` for
            // one vertical laser driven by mock authoritative board positions and a scripted verdict.
            if VerticalLaserReplay.isRequested {
                do {
                    let input = try LaserReplayScript.load().input
                    let request = VerticalLaserReplay.requested
                    let calibrations = input.configuration.calibrations.filter { !request.solo || $0.key == .player1 }
                    guard let robots = try await installAvatars(calibrations: calibrations,
                                                                layout: input.configuration.playerPlaneLayout) else { return }
                    if request.solo { scene.players[.player2]?.isEnabled = false }
                    scene.isLaserVisible = false
                    let replay = VerticalLaserReplay(scene: scene, robots: robots, request: request)
                    verticalLaserReplay = replay
                    replay.start(on: content)
                } catch { startupError = String(describing: error) }
                return
            }
            // Launch with `-replay -verticalLaserPreview [solo] [center|left|right|outer|sweep] [parked] [reduced] [seconds]`
            // to review the vertical laser prototype (no gameplay).
            if VerticalLaserPreview.isRequested {
                do {
                    let input = try LaserReplayScript.load().input
                    let request = VerticalLaserPreview.requested
                    let calibrations = input.configuration.calibrations.filter { !request.solo || $0.key == .player1 }
                    guard try await installAvatars(calibrations: calibrations,
                                                   layout: input.configuration.playerPlaneLayout) != nil else { return }
                    if request.solo { scene.players[.player2]?.isEnabled = false }
                    scene.isLaserVisible = false
                    let preview = VerticalLaserPreview(scene: scene, request: request)
                    verticalLaserPreview = preview
                    preview.start(on: content, scene: scene)
                } catch { startupError = String(describing: error) }
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
                // Opt-in synthetic posture comparison, using the existing HIGH preview band
                // at the crossing plane. This never creates a round or judges a contact.
                if arguments.contains("-duckLaserComparison") {
                    let band = LaserApproachPreview.encounters[0].band
                    scene.setLaserBand(lowerEdge: band.lowerBound, upperEdge: band.upperBound)
                    scene.setLaserDepth(scene.mapping.interactionPlaneZ)
                    scene.setLaserDangerSide(.above)
                    scene.setLaserVisualState(.active)
                    scene.isLaserVisible = true
                }
                do {
                    let input = try LaserReplayScript.load().input
                    // `-robotDemoSolo`: Lemon alone, as in a Solo round (no P2 mascot, no partner limit).
                    let demoCalibrations = arguments.contains("-robotDemoSolo")
                        ? input.configuration.calibrations.filter { $0.key == .player1 } : input.configuration.calibrations
                    guard let robots = try await installAvatars(calibrations: demoCalibrations,
                                                                layout: input.configuration.playerPlaneLayout) else { return }
                    // 30 Hz poses shown at render rate, feet diagnostics on.
                    robots.smoothing = 0.03
                    robots.diagnosticsEnabled = true
                    let sequence = RobotDemoSequence(configuration: input.configuration,
                                                     cameraGeometryRevision: input.cameraGeometryRevision, only: only)
                    if arguments.contains("-avatarPackets") {
                        // K03 path: the demo's frames as labelled SYNTHETIC D06 packets through the
                        // bounded latest-only mailbox, drained once per render tick.
                        var lifecycle = SyntheticAvatarSource(configuration: input.configuration,
                                                              cameraGeometryRevision: input.cameraGeometryRevision)
                        let mailbox = AvatarPoseMailbox(maxAge: LiveAvatarPresenter.maximumPoseAge)
                        if arguments.contains("-avatarLifecycle") {
                            // As a live round: a later status (binding, calibration) replaces the
                            // first, which resets every mascot's presentation (iPad steering P0).
                            mailbox.publish(lifecycle.status)
                            lifecycle.statusRevision += 1
                            lifecycle.controlRevision += 1
                        }
                        let source = lifecycle
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
                useSlice = useSlice || DiamondTimeFixture.isRequested || TimingIndicatorControls.isComparison
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
    }

    private var activeTutorial: LeanTutorial? {
        #if DEBUG
        if isLeanPreview { return leanPreview }
        #endif
        return tutorial
    }

    private var gameplaySurface: some View {
        world
        .blur(radius: (activeTutorial?.heartPhase?.usesOverlay == true || activeTutorial?.progressPhase != nil || activeTutorial?.stage == .vaultButtonIntroduction || activeTutorial?.stage == .collectiblesIntroduction || activeTutorial?.stage == .diamondCollectionIntroduction) && activeTutorial?.isSuspended == false ? 5 : 0)
        #if DEBUG
        .blur(radius: isLeanPreview && (leanPreview.stage == .introduction || leanPreview.stage == .jumpDuckIntroduction) && !leanPreview.isSuspended ? 5 : 0)
        #endif
        #if DEBUG
        // Launch with `-landscape` to frame the 3D view at the narrowest landscape iPad's aspect
        // (4:3) on a Simulator that cannot be rotated: the camera then composes exactly as in
        // landscape (composition reviews only).
        .frame(width: Self.landscapePreview ? UIScreen.main.bounds.width : nil,
               height: Self.landscapePreview ? UIScreen.main.bounds.width * 3 / 4 : nil)
        .clipped()
        #endif
        // After the DEBUG framing, so the paw board maps onto the 3D view as framed.
        .onGeometryChange(for: CGRect.self) {
            $0.frame(in: .global)
        } action: {
            presentation.pawBoardDiamonds.viewportFrame = $0
            tutorialDiamondPresentation.pawBoardDiamonds.viewportFrame = $0
            needsLeanProjection = true
        }
        .ignoresSafeArea()
        .background(.black)
        .overlay {
            if let bonus = tutorialDiamondTime, let tutorial = activeTutorial {
                tutorialDiamondHUD(bonus, tutorial: tutorial)
            } else if let session {
                let model = session.summary == nil ? PerfSpans.measure("hudModel") { hudModel(session) } : nil
                ZStack {
                    if let seconds = model?.diamondTimeRemaining, seconds > 0 {
                        DiamondTimeRushFrame(secondsRemaining: seconds)
                    }
                    if session.showsDiamondTimePaws {
                        DiamondTimePawOverlay(time: session.state?.gameTime ?? 0, paws: session.diamondTimePaws,
                            states: session.diamondStates, presentation: presentation.pawBoardDiamonds)
                    }
                    // The debug HUD takes the place of the normal HUD.
                    if let model, !Self.showsReplayDebugHUD {
                        GameplayHUD(model: model, actions: hudActions(session), isFTUEActive: tutorial?.isActive == true, ftueJourney: tutorial?.progressJourney,
                            onFTUEProgressFrame: { tutorial?.setProgressHUDFrame($0, generation: generation) },
                            onHealthFrame: { tutorial?.setHealthHUDFrame($0, generation: generation) })
                    }
                    // PERFECT! / ZAPPED! on the HUD's title line, never over the results.
                    if session.summary == nil, activeTutorial?.isSuspended != true, scenePhase == .active,
                       (activeTutorial?.heartPhase != .hurt && activeTutorial?.practiceMove == nil) || suppliedSession?.canStartLiveRound != false {
                        LaserTeamCalloutView(model: teamCallouts)
                    }
                    // The blink into Diamond Time, over everything; only while the entry plays.
                    if let entry = session.finalVaultEntry, !entry.isComplete, entry.blinkClosure > 0 {
                        DiamondTimeBlinkView(closure: entry.blinkClosure)
                    }
                }
            }
            #if DEBUG
            if FinalVaultPreview.isRequested {
                DiamondTimeBlinkView(closure: finalVaultPreview.blinkClosure,
                                     forcesReducedMotion: ProcessInfo.processInfo.arguments.contains("reduce"))
            }
            #endif
        }
        #if DEBUG
        .overlay {
            if isLeanPreview, leanPreview.isActive {
                ZStack {
                    if tutorialDiamondTime == nil, let configuration = leanPreviewConfiguration {
                        GameplayHUD(model: .init(state: tutorialVaultPractice?.state(health: previewHeartTraining?.state.teamHealth)
                                        ?? previewHeartTraining?.state, events: [], configuration: configuration,
                                        activityDuration: configuration.activityDuration, soloPractice: isLeanPreviewSolo),
                                    actions: leanTutorialActions(leanPreview), isFTUEActive: leanPreview.isActive, ftueJourney: leanPreview.progressJourney,
                                    onFTUEProgressFrame: { leanPreview.setProgressHUDFrame($0, generation: generation) },
                                    onHealthFrame: { leanPreview.setHealthHUDFrame($0, generation: generation) })
                    }
                    if !leanPreview.isSuspended {
                        if scenePhase == .active { LaserTeamCalloutView(model: teamCallouts) }
                        LeanTutorialOverlay(tutorial: leanPreview, solo: isLeanPreviewSolo,
                            posterOnly: ProcessInfo.processInfo.arguments.contains("-leanFTUEReduceMotion"))
                    }
                }
            }
        }
        .overlay(alignment: .bottomLeading) {
            if isLeanPreview {
                VStack(alignment: .leading, spacing: 4) {
                    Text(leanPreviewStatus)
                        .accessibilityIdentifier("leanPreviewStatus")
                    if let practice = tutorialVaultPractice {
                        Text(verbatim: vaultPreviewSceneStatus)
                            .accessibilityIdentifier("ftueVaultSceneStatus")
                        let pressed = practice.vault?.buttons.values.filter { !$0.isEmpty }.count ?? 0
                        Text(verbatim: "SYNTHETIC VAULT · active: \(pressed) · opened: \(practice.didOpen)")
                            .accessibilityIdentifier("ftueVaultPracticeStatus")
                    }
                    if let practice = previewLaserPractice {
                        Text("SYNTHETIC \(practice.move.rawValue) attempt \(practice.attemptNumber) · \(String(describing: practice.outcome)) · no practice damage")
                            .accessibilityIdentifier("ftuePracticeStatus")
                    }
                    Text(leanPreviewAudit).accessibilityIdentifier("leanPreviewAudit")
                        .font(.system(size: 1)).foregroundStyle(.clear).frame(width: 1, height: 1)
                    if !leanPreview.isActive {
                        Button("Retry sample round", action: retry).accessibilityIdentifier("leanPreviewRetry")
                    }
                }.font(.caption2).foregroundStyle(.white).padding(8)
                    .background(.black.opacity(0.5))
            }
        }
        .onChange(of: leanPreview.stage) { _, stage in
            guard isLeanPreview else { return }
            if stage == .completed {
                if FTUEOnboardingPreview.isRequested {
                    leanPreviewStart = nil
                    leave()
                } else {
                    let start = leanPreviewStart; leanPreviewStart = nil; start?()
                }
            }
        }
        #endif
        .overlay {
            if let final = session?.summary { ResultsView(summary: final, onRetry: retry, onHome: homeAction) }
        }
        .overlayPreferenceValue(PickupHUDAnchorKey.self) { anchors in
            if tutorialDiamondTime != nil {
                DiamondHUDFlightOverlay(model: tutorialDiamondFlights, scoreAnchor: anchors[.score], healthAnchor: nil)
            } else if !hasTutorialOverlay {
                DiamondHUDFlightOverlay(model: diamondFlights, scoreAnchor: anchors[.score], healthAnchor: anchors[.health])
            }
        }
        .coordinateSpace(name: DiamondHUDFlightModel.space)
        .safeAreaInset(edge: .bottom) {
            // Results carry their own Back to Home (the same `leave`).
            if onExit != nil, session?.summary == nil, !hasTutorialOverlay {
                Button("Back to input selection", systemImage: "chevron.backward") { leave() }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(leaving).accessibilityIdentifier("leaveReplay")
                .padding(.bottom, 8)
            }
        }
        #if DEBUG
        // A scene that failed to start never attaches the live frame host, so the setup stage (in
        // front of this view) waits on "Get ready!" with no visible reason: say why in the log.
        .onChange(of: startupError) { _, error in
            if let error { print("[LaserLive] scene startup failed, no live frame host: \(error)") }
        }
        #endif
    }

    var body: some View {
        gameplaySurface
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
            if HeartAnimationPreview.isRequested {
                HeartAnimationPreviewControls(preview: heartPreview, retry: retry)
            }
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
        #if DEBUG
        .overlay(alignment: .bottomTrailing) {
            GeometryReader { geometry in
                VStack { Spacer(); HStack { Spacer()
                    if !HeartAnimationPreview.isRequested, !hasTutorialOverlay {
                        TimingIndicatorControls(session: session, scene: scene, retry: retry, viewport: geometry.size)
                    }
                } }
            }.ignoresSafeArea()
        }
        #endif
        .task(id: activeTutorial?.isActive == true) {
            guard activeTutorial?.isActive == true, tutorialHeartArt == nil else { return }
            tutorialHeartArt = try? await HeartArt.load()
        }
        .onAppear { trainingSceneActive = scenePhase == .active }
        .onChange(of: scenePhase) { _, phase in
            trainingSceneActive = phase == .active
            activeTutorial?.suspendPracticeClock()
            leanTravel.suspend()
            collectiblePresentation.suspend()
            tutorialVaultPractice?.suspend(at: CACurrentMediaTime())
            tutorialDiamondTime?.suspend(at: CACurrentMediaTime())
            guard activeTutorial?.heartPhase == .hurt || activeTutorial?.practiceMove != nil else { return }
            teamCallouts.setTutorialSuspended(phase != .active || activeTutorial?.isSuspended == true)
            updateHeartTraining(scene: scene, at: CACurrentMediaTime())
            updateLaserPractice(scene: scene, at: CACurrentMediaTime())
        }
        .onChange(of: suppliedSession.map { tutorial?.canExploreLean(in: $0) == true }) { _, _ in
            tutorial?.suspendPracticeClock()
            leanTravel.suspend()
            collectiblePresentation.suspend()
        }
        .onChange(of: session?.phase) { _, phase in
            scene.setTimingPaused(phase == .paused)
            if phase != .running { diamondFlights.clear() }
            #if DEBUG
            // `-maskBench` spike: the measured run is the live round, countdown to finish.
            if let phase, session?.isReplay == false {
                let inRound = [.countdown, .running, .paused].contains(phase)
                let ended = phase == .finished || { if case .failed = phase { true } else { false } }()
                MaskBenchmark.recorder.sessionPhase("\(phase)", inRound: inRound, finished: ended)
            }
            #endif
        }
        #if DEBUG
        .overlay(alignment: .topLeading) {
            if MaskBenchmark.configuration.map({ $0.overlay || $0.script }) == true { MaskBenchmarkOverlay() }
        }
        .overlay {
            // `-replay -debugRoundControlsPreview`: the live round's DEBUG card over the replay, to
            // review its placement in the Simulator (no camera). A replay offers no skips: both stay off.
            if let session, session.summary == nil, DebugRoundControls.previewRequested { DebugRoundControls(session: session) }
        }
        #endif
        .onChange(of: session?.summary?.sessionGeneration) { _, final in
            if final != nil { presentation.stop() }
            #if DEBUG
            // `-autoRetry N` (lifecycle stress runs): Results › Retry, N times, two seconds after each Results.
            if final != nil, Self.autoRetriesLeft > 0 {
                Self.autoRetriesLeft -= 1
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    retry()
                }
            }
            #endif
        }
        .onDisappear {
            pendingLiveStart?.cancel(); pendingLiveStart = nil
            objects.liveContent = nil
            objects.deferredAvatarFeed = nil
            objects.onFrame = nil
            retireTutorialVaultPractice()
            retireTutorialDiamondTime()
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
            heartTutorialDemo.stop()
            suppliedSession?.retireHeartTraining()
            suppliedSession?.retireFTUELaserPractice()
            practicePresentation.stop(callouts: teamCallouts)
            collectiblePresentation.clear()
            leanTravel.stop()
            #if DEBUG
            LaserPerfMonitor.shared.sessionEnded()
            leanPreviewTask?.cancel(); leanPreviewTask = nil
            leanPreviewInput?.stop(); leanPreviewInput = nil; leanPreviewStart = nil
            if isLeanPreview { LeanFTUEPreviewLaunch.cancelManualReplay() }
            leanPreview.abandon()
            heartPreview.stop()
            MaskBenchmark.recorder.suspend(reason: "view closed")
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
    /// `-autoRetry N`: how many automatic Retries are left in this app run (lifecycle stress runs).
    private static var autoRetriesLeft: Int = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let i = arguments.firstIndex(of: "-autoRetry"), i + 1 < arguments.count else { return 0 }
        return Int(arguments[i + 1]) ?? 0
    }()
    private static let showsReplayDebugHUD = ProcessInfo.processInfo.arguments.contains("-replayDebugHUD")
    #else
    private static let showsReplayDebugHUD = false
    #endif

    private var wantsLeanProjection: Bool {
        #if DEBUG
        tutorial != nil || isLeanPreview
        #else
        tutorial != nil
        #endif
    }

    private var hasTutorialOverlay: Bool {
        if suppliedSession?.preRoundTutorialPending == true { return true }
        #if DEBUG
        return isLeanPreview && leanPreview.isActive
        #else
        return false
        #endif
    }

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
        collectiblePresentation.clear()
        retireTutorialVaultPractice()
        retireTutorialDiamondTime()
        AudioService.shared.play(.uiTap)
        Task { @MainActor in
            await session?.stop()
            presentation.stop()
            onExit()
        }
    }

    private func leanTutorialActions(_ tutorial: LeanTutorial) -> GameplayHUDActions {
        GameplayHUDActions(pause: {
            tutorialVaultPractice?.suspend(at: CACurrentMediaTime())
            tutorial.setSuspended(true, generation: generation)
        },
            resume: { tutorial.setSuspended(false, generation: generation) }, leave: leave)
    }

    private var previewDiamondTimeHealth: Int? {
        #if DEBUG
        previewHeartTraining?.state.teamHealth
        #else
        nil
        #endif
    }

    private func tutorialDiamondHUD(_ round: FTUEDiamondTimeSession, tutorial: LeanTutorial) -> some View {
        let configuration = round.inputs.configuration
        let state = round.state(health: suppliedSession?.heartTraining?.state.teamHealth
            ?? previewDiamondTimeHealth)
        let model = GameplayHUDModel(state: state, events: round.events, configuration: configuration,
            activityDuration: configuration.activityDuration, diamondsCollected: round.game.diamondsCollected,
            enteringFinalVault: !round.entry.isComplete)
        return ZStack {
            if let seconds = model.diamondTimeRemaining, seconds > 0 {
                DiamondTimeRushFrame(secondsRemaining: seconds)
            }
            if round.showsPawBoard {
                DiamondTimePawOverlay(time: state.gameTime, paws: round.paws, states: round.game.diamonds,
                                      presentation: tutorialDiamondPresentation.pawBoardDiamonds)
            }
            GameplayHUD(model: model, actions: leanTutorialActions(tutorial),
                        isFTUEActive: true, ftueJourney: tutorial.progressJourney)
        }
    }

    private func updateTutorialVaultPractice(_ tutorial: LeanTutorial, scene: LaserScene, at now: Double) {
        guard !leaving, tutorial.stage == .vaultPractice, tutorial.generation == generation else {
            if tutorialVaultPractice != nil { retireTutorialVaultPractice() }
            #if DEBUG
            if vaultDiagnosticStart != nil {
                vaultDiagnosticStart = nil
                vaultDiagnosticInspected = false
                vaultTraceState = nil
                vaultTraceCount = 0
                vaultPreviewSceneStatus = ""
            }
            #endif
            return
        }
        var inputs = suppliedSession?.tutorialVaultInputs(generation: generation)
        var snapshot = suppliedSession?.latestSnapshot
        #if DEBUG
        if isLeanPreview, let input = leanPreviewInput {
            inputs = tutorialVaultPractice?.inputs ?? input.vaultPracticeInputs()
            snapshot = input.latestSnapshot
        }
        #endif
        if let practice = tutorialVaultPractice, let context = suppliedSession?.inputContext,
           context != practice.inputs.round.context { retireTutorialVaultPractice() }

        let consolesReady = inputs?.round.roster.allSatisfy { scene.robotAvatars?.consoles[$0] != nil } == true
        var evidenceReady = FTUEVaultPractice.hasCurrentBodySnapshot(snapshot, inputs: inputs, at: now)
        #if DEBUG
        if vaultDiagnosticStart == nil {
            vaultDiagnosticStart = now
            print("[FTUEVault] practice generation=\(generation) roster=\(tutorial.roster) inputs=\(inputs != nil) consoles=\(consolesReady) fresh=\(evidenceReady) active=\(trainingSceneActive) paused=\(tutorial.isSuspended) readiness=\(String(describing: suppliedSession?.liveReadiness?.phase))")
        }
        if isLeanPreview, ProcessInfo.processInfo.arguments.contains("-leanFTUEVaultInitialDropout"),
           let start = vaultDiagnosticStart, now - start < 4 {
            evidenceReady = false
        }
        #endif
        #if DEBUG
        defer {
            traceTutorialVault(inputs: inputs, snapshot: snapshot, at: now, consolesReady: consolesReady, evidenceReady: evidenceReady)
        }
        #endif
        // A ready, bound session can show its encounter while waiting for a fresh contact packet.
        // Keep the practice clock and consumer suspended until the original evidence gate is met.
        guard trainingSceneActive, !tutorial.isSuspended, let inputs, consolesReady else {
            tutorialVaultPractice?.suspend(at: now)
            return
        }
        do {
            if tutorialVaultPractice == nil {
                let presenter = GameplayScenePresenter(scene: scene, configuration: inputs.round.configuration,
                                                       encounters: [], showsDebugMarkers: false)
                presenter.vault.visiblePlayers = Set(inputs.round.roster)
                presenter.vault.liveConsoles = { [weak scene] player in scene?.robotAvatars?.consoles[player] }
                presenter.onSound = { AudioService.shared.play($0) }
                tutorialVaultPresenter = presenter
                tutorialVaultPractice = try FTUEVaultPractice(inputs: inputs, at: now)
            }
            guard let practice = tutorialVaultPractice, let presenter = tutorialVaultPresenter else { return }
            if evidenceReady {
                #if DEBUG
                if isLeanPreview, let input = leanPreviewInput, let packet = snapshot {
                    snapshot = try input.vaultPracticeSnapshot(packet, practice: practice)
                }
                #endif
                let shifts = snapshot.flatMap { suppliedSession?.vaultZoneShifts(for: $0) } ?? [:]
                try practice.update(at: now, snapshot: snapshot, zoneShifts: shifts)
            } else {
                practice.suspend(at: now)
            }
            let state = practice.state
            presenter.apply(state: state, events: practice.events, snapshot: nil)
            #if DEBUG
            if !vaultDiagnosticInspected {
                vaultDiagnosticInspected = true
                let door = scene.root.findEntity(named: "vaultDoor")
                let camera = scene.root.findEntity(named: "camera") as? PerspectiveCamera
                let consoles = presenter.vault.consoleViews.values.compactMap {
                    $0.root.findEntity(named: "vault.console.button.activate")
                }
                let viewport = presentation.pawBoardDiamonds.viewportFrame
                let aspect = Float(viewport.width / max(1, viewport.height))
                func inFrame(_ entity: Entity) -> Bool {
                    guard let camera, entity.isEnabledInHierarchy, entity.scene != nil else { return false }
                    let point = camera.convert(position: entity.position(relativeTo: nil), from: nil)
                    let limit = -point.z * tan(camera.camera.fieldOfViewInDegrees * .pi / 360)
                    return point.z < 0 && abs(point.x) < limit * aspect && abs(point.y) < limit
                }
                let doorVisible = door.map(inFrame) == true
                let inFrameCount = consoles.filter(inFrame).count
                let doorPosition = door.flatMap { door in camera.map { door.position(relativeTo: $0) } }
                let buttonPositions = camera.map { camera in consoles.map { $0.position(relativeTo: camera) } }
                vaultPreviewSceneStatus = "SYNTHETIC VAULT SCENE · door: \(doorVisible) · buttons: \(inFrameCount) · waiting: \(!evidenceReady)"
                print("[FTUEVault] applied generation=\(generation) doorParent=\(door?.parent?.name ?? "nil") doorInFrame=\(doorVisible) doorRelativeToCamera=\(String(describing: doorPosition)) buttonsInFrame=\(inFrameCount)/\(inputs.round.roster.count) buttonPositions=\(String(describing: buttonPositions)) aspect=\(aspect) travel=\(scene.travelOffset) camera=\(String(describing: camera?.transform)) fresh=\(evidenceReady)")
            }
            #endif
            guard evidenceReady else { return }
            // Give the shared opening its authored on-screen time even if a RealityKit
            // playback controller reports completion before its first rendered frame.
            let openingDuration = VaultDoor.openingDuration(reduceMotion: presenter.vault.reducesMotion())
            if let openedAt = practice.openedAt, state.gameTime - openedAt >= openingDuration,
               !presenter.vault.holdsTravel(for: state) {
                tutorial.finishVaultPractice(practice, generation: generation, doorIsClear: true)
                #if DEBUG
                if Self.tracesTutorialVault {
                    print("[FTUEVault] completion generation=\(generation) encounter=\(practice.presentationID) accepted=\(tutorial.stage != .vaultPractice)")
                }
                #endif
                retireTutorialVaultPractice()
            } else if let failedAt = practice.failedAt,
                      state.gameTime - failedAt >= VaultPresentation.exitFadeDuration {
                // Retry the same production opportunity after its failure feedback.
                retireTutorialVaultPractice()
            }
        } catch {
            retireTutorialVaultPractice()
            startupError = String(describing: error)
        }
    }

    #if DEBUG
    private static let tracesTutorialVault = ProcessInfo.processInfo.arguments.contains("-ftueVaultDiagnostics")
    @State private var vaultTraceState: String?
    @State private var vaultTraceCount = 0

    private func traceTutorialVault(inputs: FTUEVaultPractice.Inputs?, snapshot: BodySnapshot?, at now: Double,
                                    consolesReady: Bool, evidenceReady: Bool) {
        guard Self.tracesTutorialVault, vaultTraceCount < 16 else { return }
        let practice = tutorialVaultPractice
        let context = inputs?.round.context
        let wrists = (practice?.contactReadout ?? []).map {
            "\($0.playerID)/\($0.button)/\($0.wrist):\($0.status):pressed=\($0.pressed)"
        }.sorted()
        let readiness = "scene=\(consolesReady) plan=\(inputs != nil) currentBody=\(evidenceReady) wristPacket=\(snapshot?.wristContact != nil) active=\(trainingSceneActive) paused=\(activeTutorial?.isSuspended == true)"
        let key = "\(readiness) \(snapshot != nil) \(wrists) opened=\(practice?.didOpen == true)"
        guard key != vaultTraceState else { return }
        vaultTraceState = key
        vaultTraceCount += 1
        let age = snapshot.map { now - $0.capturedAt }
        let remaining = practice.flatMap { practice in practice.vault.map { max(0, $0.deadline - practice.state.gameTime) } }
        print("[FTUEVault] generation=\(generation) encounter=\(String(describing: practice?.presentationID)) roster=\(inputs?.round.roster ?? []) host=\(now) start=\(String(describing: vaultDiagnosticStart)) \(readiness) source=\(String(describing: context?.wristContact?.sourceEpoch)) cal=\(String(describing: context?.calibrationRevisions)) frame=\(String(describing: snapshot?.frameID)) age=\(String(describing: age)) remaining=\(String(describing: remaining)) wrists=\(wrists) opened=\(practice?.didOpen == true)")
    }
    #endif

    private func retireTutorialVaultPractice() {
        tutorialVaultPresenter?.stop()
        tutorialVaultPresenter?.vault.buttons.removeFromParent()
        tutorialVaultPresenter?.vault.root.removeFromParent()
        tutorialVaultPresenter = nil
        tutorialVaultPractice = nil
    }

    private func updateTutorialDiamondTime(_ tutorial: LeanTutorial, scene: LaserScene,
                                           content: RealityViewCameraContent, at now: Double) {
        guard !leaving, tutorial.stage == .diamondTimeDemo, tutorial.generation == generation else {
            if tutorialDiamondTime != nil { retireTutorialDiamondTime() }
            return
        }
        var inputs = suppliedSession?.tutorialDiamondTimeInputs(generation: generation)
        var snapshot = suppliedSession?.latestSnapshot
        #if DEBUG
        if isLeanPreview, let input = leanPreviewInput {
            inputs = tutorialDiamondTime?.inputs ?? input.diamondTimeInputs()
            snapshot = input.latestSnapshot
        }
        #endif
        let eligible = inputs != nil && trainingSceneActive && !tutorial.isSuspended
        if let round = tutorialDiamondTime {
            let currentContext = suppliedSession?.inputContext ?? inputs?.context
            if let currentContext, round.inputs.context != currentContext { retireTutorialDiamondTime() }
        }
        do {
            if eligible, let inputs {
                if tutorialDiamondTime == nil {
                    tutorialDiamondTime = try FTUEDiamondTimeSession(inputs: inputs, at: now)
                    tutorialDiamondPresentation.diamondFlights = tutorialDiamondFlights
                }
                if let round = tutorialDiamondTime {
                    #if DEBUG
                    if isLeanPreview, let input = leanPreviewInput, let packet = snapshot, round.showsPawBoard {
                        snapshot = try input.diamondTimeSnapshot(packet, round: round)
                    }
                    #endif
                    try round.update(at: now, snapshot: snapshot)
                    if round.isComplete {
                        retireTutorialDiamondTime()
                        tutorial.finishDiamondTime(round, generation: generation)
                        return
                    }
                }
            } else {
                tutorialDiamondTime?.suspend(at: now)
            }
        } catch {
            retireTutorialDiamondTime()
            startupError = String(describing: error)
            return
        }
        if let round = tutorialDiamondTime {
            tutorialDiamondPresentation.renderTutorialDiamondTime(round, on: content, scene: scene, running: eligible)
        }
    }

    private func retireTutorialDiamondTime() {
        tutorialDiamondPresentation.stop()
        tutorialDiamondTime = nil
    }

    /// Only the existing render callback drives the scoped training encounter.
    private func updateHeartTraining(scene: LaserScene, at now: Double) {
        guard let tutorial = activeTutorial, tutorial.heartPhase != nil else {
            heartTutorialDemo.stop()
            if activeTutorial?.isActive != true {
                suppliedSession?.retireHeartTraining()
                #if DEBUG
                previewHeartTraining = nil
                #endif
            }
            return
        }
        guard tutorial.heartPhase == .hurt else { heartTutorialDemo.stop(); return }
        let suspended = tutorial.isSuspended || !trainingSceneActive
        if let suppliedSession {
            suppliedSession.updateHeartTraining(at: now, suspended: suspended)
            let paused = suspended || !suppliedSession.canStartLiveRound
            heartTutorialDemo.update(scene: scene, training: suppliedSession.heartTraining, callouts: teamCallouts, suspended: paused)
            if !paused, let receipt = heartTutorialDemo.feedbackFinished(teamCallouts) {
                suppliedSession.finishHeartTrainingFeedback(id: receipt.id, generation: generation)
                if suppliedSession.heartTraining?.feedbackFinished == true {
                    tutorial.finishTrainingEncounter(suppliedSession.heartTraining!, generation: generation)
                }
            }
        }
        else {
        #if DEBUG
        if isLeanPreview, let configuration = leanPreviewConfiguration, let input = leanPreviewInput {
            if previewHeartTraining == nil {
                previewHeartTraining = try? HeartTrainingEncounter(configuration: configuration, context: input.context,
                    roster: Set(leanPreview.roster))
            }
            previewHeartTraining?.update(at: now, eligible: !suspended, context: input.context)
            heartTutorialDemo.update(scene: scene, training: previewHeartTraining, callouts: teamCallouts, suspended: suspended)
            if !suspended, let receipt = heartTutorialDemo.feedbackFinished(teamCallouts) {
                previewHeartTraining?.finishFeedback(id: receipt.id, generation: generation)
                if previewHeartTraining?.feedbackFinished == true {
                    tutorial.finishTrainingEncounter(previewHeartTraining!, generation: generation)
                }
            }
        }
        #endif
        }
    }

    private func updateLaserPractice(scene: LaserScene, at now: Double) {
        guard let tutorial = activeTutorial, tutorial.practiceMove != nil else {
            practicePresentation.stop(callouts: teamCallouts)
            suppliedSession?.retireFTUELaserPractice()
            #if DEBUG
            previewLaserPractice = nil
            #endif
            return
        }
        let suspended = tutorial.isSuspended || !trainingSceneActive
        if let suppliedSession {
            suppliedSession.updateFTUELaserPractice(at: now, generation: generation, suspended: suspended)
            guard let practice = suppliedSession.laserPractice else { return }
            let paused = suspended || !suppliedSession.canStartLiveRound
            practicePresentation.update(scene: scene, practice: practice, callouts: teamCallouts, suspended: paused)
            if !paused, let attempt = practicePresentation.finishedAttempt(teamCallouts) {
                suppliedSession.finishFTUEPracticeFeedback(attempt: attempt, generation: generation)
                if let current = suppliedSession.laserPractice {
                    tutorial.synchronizePractice(current, generation: generation)
                    #if DEBUG
                    if current.move == .duck, current.completed,
                       ProcessInfo.processInfo.arguments.contains("-ftueDuckDiagnostics") {
                        print("[FTUE Duck] generation=\(generation) attempt=\(attempt) feedback=finished transition=\(tutorial.stage)")
                    }
                    #endif
                }
            }
        } else {
            #if DEBUG
            if isLeanPreview, leanPreviewConfiguration != nil, let input = leanPreviewInput {
                if previewLaserPractice == nil {
                    previewLaserPractice = try? .init(input: input.configuration, configuration: try LaserFullReplayPlan.roundConfiguration(),
                        context: input.context, poseFirst: PoseFirstCandidate.isEnabled)
                }
                try? previewLaserPractice?.update(at: now, eligible: !suspended, context: input.context)
                if let practice = previewLaserPractice {
                    practicePresentation.update(scene: scene, practice: practice, callouts: teamCallouts, suspended: suspended)
                    if !suspended, let attempt = practicePresentation.finishedAttempt(teamCallouts) {
                        try? previewLaserPractice?.feedbackFinished(attempt: attempt, generation: generation)
                        if let current = previewLaserPractice { tutorial.synchronizePractice(current, generation: generation) }
                    }
                }
            }
            #endif
        }
    }

    private func freshTutorialPlayers(_ session: GameSessionCoordinator, at now: Double) -> Set<PlayerID> {
        guard let snapshot = session.latestSnapshot, let context = session.inputContext,
              now >= snapshot.capturedAt, now - snapshot.capturedAt <= LiveAvatarPresenter.maximumPoseAge else { return [] }
        return Set(session.inputConfiguration.roster.filter {
            context.accepts(snapshot, playerID: $0) && snapshot.players[$0]?.trackingStatus == .reliable
        })
    }

    private func updateLeanAndCollectibles(_ tutorial: LeanTutorial, scene: LaserScene,
                                          context: BodyInputContext?, input: BodyInputConfiguration,
                                          configuration: LaserRoundConfiguration?, eligible: Bool,
                                          contactPlayers: Set<PlayerID>? = nil, at now: Double) {
        let allowed = eligible && trainingSceneActive && !tutorial.isSuspended && !leaving
            && tutorial.generation == generation
        let value = scene.liveAvatars?.lastAppliedFrame.flatMap { frame in
            LeanMovementObservation.make(frame: frame, context: context, generation: generation,
                roster: tutorial.roster, eligible: allowed, now: now, bounds: scene.robotAvatars?.steering?.bounds) {
                    scene.robotAvatars?.steeringReading($0)
                }
        }
        let trackedPlayers = Set(value?.players.keys.map { $0 } ?? [])
        let players = contactPlayers.map { trackedPlayers.intersection($0) } ?? trackedPlayers
        if tutorial.isPractising {
            #if DEBUG
            if RobotAvatarLayer.debugTestSteer != nil {
                tutorial.advancePractice(generation: generation, at: now, ready: false)
                return
            }
            #endif
            if let value {
                if tutorial.shouldRead(value.source) { tutorial.observe(value, generation: generation, at: now) }
            } else { tutorial.observe(nil, generation: generation, at: now) }
            tutorial.advancePractice(generation: generation, at: now, ready: allowed)
        } else if let kind = tutorial.collection, let context, let configuration {
            if let receipt = collectiblePresentation.update(scene: scene, kind: kind,
                configuration: configuration, input: input, context: context, at: now,
                ready: allowed, contactsFrom: players, heartArt: tutorialHeartArt) {
                tutorial.acceptPickup(receipt)
            }
        } else { collectiblePresentation.suspend() }
    }

    /// Live pause/continue intents go to the session. Replay retains its fixture-driven controls.
    private func hudActions(_ session: GameSessionCoordinator) -> GameplayHUDActions {
        if let tutorial, tutorial.isActive { return leanTutorialActions(tutorial) }
        return GameplayHUDActions(pause: session.isReplay ? nil : { session.pauseLiveRound() },
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
        return GameplayHUDModel(state: tutorial?.isActive == true
                                    ? (tutorialVaultPractice?.state(health: session.heartTraining?.state.teamHealth)
                                       ?? session.heartTraining?.state ?? session.state) : session.state,
                                events: session.events, configuration: configuration,
                                activityDuration: session.activityDuration, stageProgress: session.stageProgress,
                                diamondsCollected: collected, diamondsAreFixture: fixture,
                                enteringFinalVault: session.finalVaultEntry.map { !$0.presentsDiamondTime } ?? false,
                                soloPractice: session.isSoloPractice)
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

    /// What the round shows now, for `LaserPerfMonitor` (`-perfLog`): solo/co-op and the phase.
    private static func perfPhase(_ session: GameSessionCoordinator?) -> String {
        guard let session else { return "loading" }
        let players = session.inputConfiguration.roster.count == 1 ? "solo" : "coop"
        if session.summary != nil { return "\(players).results" }
        if session.phase == .paused { return "\(players).paused" }
        switch session.state?.phase {
        case .activity?: return "\(players).gameplay"
        case .vault?: return "\(players).gate"
        case .diamondTime?: return session.finalVaultEntry.map { !$0.isComplete } == true ? "\(players).vaultEntry" : "\(players).diamondTime"
        case .ended?: return "\(players).ended"
        case nil: return "\(players).\(session.phase)"
        }
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
