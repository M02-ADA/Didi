#if DEBUG
import Observation
import RealityKit
import SwiftUI

/// A separate presentation for listening to real replay cues with a controllable source clock.
struct SFXReplayLabView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var lab = SFXReplayLab()
    @State private var sceneReady = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        RealityView { content in
            content.camera = .virtual
            lab.scene.installEnvironment(authored: await LaserScene.loadAuthoredEnvironment())
            lab.scene.installLaserArtwork(await LaserScene.loadLaserGateArtwork())
            lab.scene.installVaultDoor(await LaserScene.loadVaultDoorArtwork())
            lab.scene.installDiamondArt(await LaserScene.loadDiamondArtwork())
            guard !Task.isCancelled else { return }
            content.add(lab.scene.root)
            sceneReady = true
        }
        .background(.black)
        .safeAreaInset(edge: .top) {
            HStack {
                Text("SFX Replay Lab").font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding()
            .background(.regularMaterial)
        }
        .safeAreaInset(edge: .bottom) { controls }
        .task(id: sceneReady) {
            if sceneReady { await lab.run() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { lab.playing = false }
        }
        .onDisappear { lab.close() }
    }

    private var controls: some View {
        @Bindable var lab = lab
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Scenario", selection: $lab.scenario) {
                    ForEach(SFXReplayLab.scenarios, id: \.self) { scenario in
                        Text(SFXReplayLab.title(for: scenario)).tag(scenario)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("sfxReplayScenario")
                .onChange(of: lab.scenario) { _, _ in lab.seek(to: 0) }
                Spacer()
                if let error = lab.error {
                    Text(error).foregroundStyle(.red)
                } else {
                    Text(lab.status).monospacedDigit()
                        .accessibilityIdentifier("sfxReplayStatus")
                }
            }
            HStack {
                Button { lab.seek(to: lab.time - 10) } label: {
                    Label("Back 10 seconds", systemImage: "gobackward.10")
                }.labelStyle(.iconOnly)
                    .accessibilityIdentifier("sfxReplayBack")
                Button(lab.playing ? "Pause" : "Play") { lab.togglePlayback() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("sfxReplayPlay")
                Button { lab.seek(to: lab.time + 10) } label: {
                    Label("Forward 10 seconds", systemImage: "goforward.10")
                }.labelStyle(.iconOnly)
                    .accessibilityIdentifier("sfxReplayForward")
                Menu("Jump to scene", systemImage: "list.bullet") {
                    ForEach(lab.chapters) { chapter in
                        Button(chapter.title) { lab.seek(to: chapter.time) }
                    }
                }
                .accessibilityIdentifier("sfxReplayChapters")
                Spacer()
                Picker("Speed", selection: $lab.speed) {
                    Text("0.5×").tag(0.5)
                    Text("1×").tag(1.0)
                    Text("2×").tag(2.0)
                    Text("4×").tag(4.0)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 240)
            }
            .disabled(lab.session == nil || lab.isSeeking)
        }
        .padding()
        .background(.regularMaterial)
    }
}

@MainActor @Observable
private final class SFXReplayLab {
    struct Chapter: Identifiable {
        let title: String
        let time: Double
        var id: String { title }
    }

    static let scenarios: [LaserReplayScript.Scenario] = [.standard, .healthDepleted, .vaultTimeout]

    static func title(for scenario: LaserReplayScript.Scenario) -> String {
        switch scenario {
        case .standard: "Normal · victory"
        case .healthDepleted: "All HITs · game over"
        case .vaultTimeout: "Vault timeout · game over"
        }
    }

    let scene = LaserScene()
    var scenario: LaserReplayScript.Scenario = .standard
    var speed = 1.0
    var playing = false
    private(set) var session: GameSessionCoordinator?
    private(set) var time = 0.0
    private(set) var isSeeking = false
    private(set) var error: String?
    private(set) var chapters: [Chapter] = []
    private var pendingSeek: Double? = 0
    private var script: LaserReplayScript?
    private var loadedScenario: LaserReplayScript.Scenario?
    private var presenter: GameplayScenePresenter?
    private var closed = false

    var status: String {
        if isSeeking || session == nil { return "Preparing replay…" }
        let health = session?.state?.teamHealth ?? script?.configuration.initialTeamHealth ?? 0
        let seconds = Int(time)
        let timestamp = String(format: "%d:%02d", seconds / 60, seconds % 60)
        let result = switch session?.summary?.outcome {
        case .completed: " · Victory"
        case .healthDepleted: " · Game over: health depleted"
        case .vaultFailed: " · Game over: vault timeout"
        default: ""
        }
        return "\(timestamp) · Health \(health)\(result)"
    }

    func seek(to position: Double) {
        pendingSeek = max(0, position)
        AudioService.shared.stopEffects()
    }

    func togglePlayback() {
        if session?.summary != nil { seek(to: 0) }
        playing.toggle()
    }

    func close() {
        closed = true
        presenter?.stop()
        AudioService.shared.stopEffects()
        AudioService.shared.setMusic(.menu)
    }

    func run() async {
        AudioService.shared.preloadEffects()
        let clock = ContinuousClock()
        var lastTick = clock.now
        while !Task.isCancelled, !closed {
            do {
                let now = clock.now
                let delta = (now - lastTick).components
                lastTick = now
                if let position = pendingSeek {
                    pendingSeek = nil
                    try await rebuild(at: position)
                    lastTick = clock.now
                } else if playing, let session, let script, session.phase == .running {
                    AudioService.shared.setMusic(.mission)
                    let elapsed = Double(delta.seconds) + Double(delta.attoseconds) / 1e18
                    let next = min(script.duration, time + min(elapsed, 0.10) * speed)
                    try await session.advance(to: next)
                    if closed || Task.isCancelled { break }
                    guard pendingSeek == nil else { continue }
                    time = session.summary?.gameDuration ?? next
                    render()
                    if let summary = session.summary {
                        playing = false
                        AudioService.shared.setMusic(nil, fade: 0.6)
                        if let cue = ResultsView.sting(for: summary.outcome) { AudioService.shared.play(cue) }
                    }
                }
                try await Task.sleep(for: .milliseconds(25))
            } catch is CancellationError {
                break
            } catch {
                self.error = "Replay could not run: \(error)"
                playing = false
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        await session?.stop()
    }

    private func rebuild(at position: Double) async throws {
        isSeeking = true
        defer { isSeeking = false }
        error = nil
        presenter?.stop()
        await session?.stop()
        try Task.checkCancellation()
        let selected = scenario
        if selected != loadedScenario || script == nil {
            let plan = try LaserReplayScript.complete(scenario: selected)
            script = plan
            chapters = Self.chapters(in: plan, scenario: selected)
            loadedScenario = selected
        }
        guard let script else { return }
        let fresh = try script.freshRound(generation: UUID())
        let replay = try LaserReplayDriver.makeSession(script: fresh)
        session = replay
        try await replay.start()
        let target = min(position, fresh.duration)
        try await replay.advance(to: target)
        try Task.checkCancellation()
        guard !closed else { return }
        time = replay.summary?.gameDuration ?? target
        let view = GameplayScenePresenter(scene: scene, configuration: fresh.configuration,
                                          encounters: replay.encounters, showsDebugMarkers: false)
        let layout = replay.inputConfiguration.playerPlaneLayout
        view.normalDiamonds.source = { [weak replay] in
            guard let replay else { return [] }
            return LaserReplayPresentation.normalDiamonds(replay.diamondStates, layout: layout)
        }
        view.diamondTime.source = { [weak replay] _ in
            guard let replay else { return [] }
            return replay.diamondStates.values.compactMap { state in
                guard case .diamondTime = state.lifetime,
                      let lane = PlayerID.allCases.first(where: { state.spawn.eligiblePlayers.contains($0) }),
                      let id = Int(state.spawn.id.uuidString.suffix(12), radix: 16) else { return nil }
                let collected: Bool
                switch state.outcome {
                case .collected: collected = true
                case nil: collected = false
                default: return nil
                }
                return DiamondTimeDiamond(id: id, lane: lane,
                    offsetX: Float(state.spawn.position.x - layout.centerX(for: lane)),
                    heightAboveFloor: Float(state.spawn.position.y), collected: collected)
            }.sorted { $0.id < $1.id }
        }
        presenter = view
        render() // Consume reconstructed events before attaching any sound output.
        view.onSound = { AudioService.shared.play($0) }
        if replay.summary != nil {
            playing = false
            AudioService.shared.setMusic(nil, fade: 0.6)
        }
    }

    private func render() {
        guard let session, let state = session.state else { return }
        presenter?.apply(state: state, events: session.events, snapshot: session.latestSnapshot,
            upcomingVaultIn: LaserReplayPresentation.upcomingVaultIn(state: state, activityDuration: session.activityDuration))
    }

    private static func chapters(in script: LaserReplayScript, scenario: LaserReplayScript.Scenario) -> [Chapter] {
        var result = [Chapter(title: "Start of round", time: 0)]
        guard let plan = script.fullRound else { return result }
        if let first = script.encounters.first?.targets.first {
            result.append(Chapter(title: "First laser", time: max(0, first.warningTime - 0.5)))
        }
        if scenario == .healthDepleted {
            // Both players are hit at each crossing. Start before the last approach.
            let hitsToLose = (script.configuration.initialTeamHealth + 1) / 2
            if let target = script.encounters.prefix(hitsToLose).last?.targets.first {
                result.append(Chapter(title: "Final HIT / game over", time: max(0, target.warningTime - 0.5)))
            }
            return result
        }
        if let pickup = plan.steps.first(where: { if case .normalDiamond = $0.action { true } else { false } }) {
            result.append(Chapter(title: "Diamond pickup", time: max(0, pickup.time - 0.5)))
        }
        let vaults = plan.steps.filter { if case .openVault = $0.action { true } else { false } }
        for (index, vault) in vaults.enumerated() {
            result.append(Chapter(title: "Vault \(index + 1)", time: max(0, vault.time - 1)))
        }
        if scenario == .vaultTimeout, let vault = vaults.first {
            result.append(Chapter(title: "Vault warning / game over",
                                  time: vault.time + max(0, script.configuration.vaultDuration - 3)))
        } else {
            result.append(Chapter(title: "Diamond Time", time: plan.bonusStart - 0.6))
            result.append(Chapter(title: "Victory", time: plan.duration - 2))
        }
        return result.sorted { $0.time < $1.time }
    }
}
#endif
