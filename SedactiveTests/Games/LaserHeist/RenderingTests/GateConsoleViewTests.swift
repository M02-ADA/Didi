import Foundation
import RealityKit
import Testing
@testable import Sedactive

/// The unified wall console's buttons (owner, 12 November 2026): one state system for all three,
/// RED available → (press) → GREEN completed, once per button per gate, kept until the gate ends,
/// driven only by the game's `vault.buttons`. Presentation tests: no judge here.
@MainActor
struct GateConsoleViewTests {
    private static let arm = LaserGateConsole.Arm(shoulder: [0.154, 0.693], length: 0.369)
    private static func console(_ player: PlayerID) -> LaserGateConsole {
        LaserGateConsole(player: player, arm: arm, visibleHalfWidth: 2.583, wallHalfWidth: 3.15, planeZ: 0)
    }

    @Test func eachButtonGoesRedToGreenOnceAndStaysGreen() {
        let view = GateConsoleView(console: Self.console(.player1))
        for b in LaserVaultButton.allCases {
            #expect(view.states[b] == .available && view.glowColor(b) == GateConsoleView.Palette.redGlow && !view.isCheckShown(b))
            #expect(view.capDepth(b) == GateConsoleView.capRest, "unpressed: the cap stands proud")
        }
        view.complete(.middle, reduceMotion: true)
        #expect(view.states[.middle] == .completed && view.glowColor(.middle) == GateConsoleView.Palette.greenGlow)
        #expect(view.isCheckShown(.middle) && view.capDepth(.middle) == GateConsoleView.capSettled, "green, checked, settled into its bezel")
        #expect(view.states[.top] == .available && view.states[.bottom] == .available, "the others stay red")
        view.complete(.middle, reduceMotion: true)
        view.complete(.middle, reduceMotion: false)
        #expect(view.presses[.middle] == 1, "one press per button per gate")
        #expect(view.states[.middle] == .completed && view.glowColor(.middle) == GateConsoleView.Palette.greenGlow, "stays green")
        view.reset()
        #expect(LaserVaultButton.allCases.allSatisfy { view.states[$0] == .available && !view.isCheckShown($0) }, "a new gate starts red")
    }

    /// The animated press: the cap sinks and settles, the colour changes at the bottom of the press.
    @Test func theAnimatedPressSettlesIntoTheSameGreenButton() async throws {
        let view = GateConsoleView(console: Self.console(.player2))
        view.complete(.top, reduceMotion: false)
        #expect(view.states[.top] == .completed, "completed at once (the game decided)")
        #expect(view.capDepth(.top) == GateConsoleView.capSettled, "ends settled (the animation plays from the rest depth)")
        // The colour changes 60 ms in (on the main actor; allow for a busy test host).
        for _ in 0..<40 where !view.isCheckShown(.top) { try await Task.sleep(for: .milliseconds(50)) }
        #expect(view.isCheckShown(.top) && view.glowColor(.top) == GateConsoleView.Palette.greenGlow)
        #expect(GateConsoleView.capPressed < GateConsoleView.capSettled && GateConsoleView.capSettled < GateConsoleView.capRest)
    }

    /// Through the vault presentation: the game's activations drive the console; completed buttons
    /// stay green while the gate is active; a side's three greens light its edge strips.
    @Test func theVaultPresentationDrivesTheConsolesFromGameState() throws {
        let scene = LaserScene()
        let configuration = try LaserRoundConfiguration(evidenceTiming: .init(windowBefore: 0.125, windowAfter: 0.125, deliveryAllowance: 0.125),
                                                        clearanceMargin: 0.005, diamondPoints: 25)
        let vault = VaultPresentation(scene: scene, configuration: configuration)
        vault.reducesMotion = { true }
        vault.liveConsoles = { Self.console($0) }
        let id = UUID(), generation = UUID()
        func state(_ buttons: [PlayerID: Set<LaserVaultButton>], at t: Double) -> LaserGameState {
            LaserGameState(sessionGeneration: generation, phase: .vault, gameTime: t, activityProgress: 0, teamHealth: 5, teamScore: 0,
                           encounters: [], vault: LaserVaultState(id: id, deadline: 5, buttons: buttons))
        }
        vault.update(state: state([:], at: 0), travelDistance: 0)
        let p1 = try #require(vault.consoleViews[.player1]), p2 = try #require(vault.consoleViews[.player2])
        #expect(p1.root.isEnabled && p2.root.isEnabled)
        vault.update(state: state([.player1: [.bottom]], at: 1), travelDistance: 0)
        #expect(p1.states[.bottom] == .completed && p2.states[.bottom] == .available)
        vault.update(state: state([.player1: [.bottom, .top]], at: 2), travelDistance: 0)
        #expect(p1.states[.bottom] == .completed && p1.states[.top] == .completed && p1.presses[.bottom] == 1, "stays green, pressed once")
        vault.update(state: state([.player1: [.bottom, .top, .middle]], at: 3), travelDistance: 0)
        #expect(p1.sideComplete && !p2.sideComplete)
    }

    /// The gate is one structure (iPad, 12 November 2026): with wall consoles the door stops just
    /// beyond the players, and the consoles come down the corridor with it, a fixed distance in front
    /// of it, arriving beside the mascots exactly when the door reaches its stop. Without consoles
    /// the door keeps its authored stop.
    @Test func theConsolesComeInWithTheDoorAndArriveBesideThePlayers() throws {
        let scene = LaserScene()
        scene.installVaultDoor(nil)
        let configuration = try LaserRoundConfiguration(evidenceTiming: .init(windowBefore: 0.125, windowAfter: 0.125, deliveryAllowance: 0.125),
                                                        clearanceMargin: 0.005, diamondPoints: 25)
        let plain = VaultPresentation(scene: scene, configuration: configuration)
        #expect(plain.doorStopZ == scene.layout.vaultDoorStopZ, "no consoles: the authored stop")
        let vault = VaultPresentation(scene: scene, configuration: configuration)
        vault.reducesMotion = { true }
        vault.liveConsoles = { Self.console($0) }
        let stop = vault.doorStopZ
        #expect(abs(stop - (scene.mapping.interactionPlaneZ - VaultPresentation.consoleDoorGap)) < 1e-5 && stop > scene.layout.vaultDoorStopZ,
                "with consoles the door stops \(VaultPresentation.consoleDoorGap) m beyond the players")
        let generation = UUID()
        func activity(_ t: Double) -> LaserGameState {
            LaserGameState(sessionGeneration: generation, phase: .activity, gameTime: t, activityProgress: 0.2, teamHealth: 5, teamScore: 0, encounters: [])
        }
        // Far: the consoles are already part of the approaching gate, riding with the door.
        vault.update(state: activity(50), travelDistance: 0, upcomingVaultIn: 3)
        let p1 = try #require(vault.consoleViews[.player1])
        #expect(p1.root.isEnabled && LaserVaultButton.allCases.allSatisfy { p1.states[$0] == .available })
        let far = vault.buttons.position.z
        #expect(abs(far + GateTravelEase.distance(lead: 3, speed: scene.layout.travelSpeed)) < 1e-4, "the consoles ride \(far) m out, with the door")
        // Arriving: both at their places, the consoles beside the players.
        vault.update(state: activity(52.99), travelDistance: 0, upcomingVaultIn: 0.01)
        #expect(abs(vault.buttons.position.z) < 0.06)
        let id = UUID()
        vault.update(state: LaserGameState(sessionGeneration: generation, phase: .vault, gameTime: 53, activityProgress: 0, teamHealth: 5,
                                           teamScore: 0, encounters: [], vault: LaserVaultState(id: id, deadline: 58, buttons: [:])),
                     travelDistance: 0)
        #expect(vault.buttons.position.z == 0, "at the gate the consoles stand beside the players")
        #expect(p1.root.isEnabled && vault.indicator(.player1, .top) == .idle)
    }

    /// After the gate opens the consoles are corridor structure (iPad, 12 November 2026: they had
    /// stayed beside the mascots and dissolved): they keep their greens, never fade, ride with the
    /// door as travel resumes, and are cleaned up with it once past the camera.
    @Test func afterOpeningTheConsolesStayGreenRideWithTheCorridorAndLeaveWithTheDoor() throws {
        let scene = LaserScene()
        let configuration = try LaserRoundConfiguration(evidenceTiming: .init(windowBefore: 0.125, windowAfter: 0.125, deliveryAllowance: 0.125),
                                                        clearanceMargin: 0.005, diamondPoints: 25)
        let vault = VaultPresentation(scene: scene, configuration: configuration)
        vault.reducesMotion = { true }
        vault.liveConsoles = { Self.console($0) }
        let id = UUID(), generation = UUID()
        let all: [PlayerID: Set<LaserVaultButton>] = [.player1: Set(LaserVaultButton.allCases), .player2: Set(LaserVaultButton.allCases)]
        func state(_ phase: LaserRoundPhase, _ t: Double, opened: Bool) -> LaserGameState {
            LaserGameState(sessionGeneration: generation, phase: phase, gameTime: t, activityProgress: 0, teamHealth: 5, teamScore: 0,
                           encounters: [], missionProgress: opened ? 1 : 0, vault: LaserVaultState(id: id, deadline: 5, buttons: opened ? all : [:], opened: opened))
        }
        vault.update(state: state(.vault, 0, opened: false), travelDistance: 10)
        vault.update(state: state(.vault, 1, opened: true), travelDistance: 10)
        let p1 = try #require(vault.consoleViews[.player1])
        #expect(vault.buttons.isEnabled, "open: still shown")
        #expect(abs(vault.buttons.position.z) < 1e-5, "open: still in place (\(vault.buttons.position.z))")
        #expect(vault.buttons.components[OpacityComponent.self]?.opacity ?? 1 == 1 && vault.buttons.availableAnimations.isEmpty)
        #expect(LaserVaultButton.allCases.allSatisfy { p1.states[$0] == .completed }, "still green")
        // Travel resumes: the consoles move with the corridor (and the door), not with the mascots.
        vault.update(state: state(.activity, 1.5, opened: true), travelDistance: 11.2)
        #expect(abs(vault.buttons.position.z - 1.2) < 1e-4, "passing the players with the corridor")
        #expect(vault.buttons.isEnabled && LaserVaultButton.allCases.allSatisfy { p1.states[$0] == .completed })
        // Past the camera: cleaned up with the door.
        vault.update(state: state(.activity, 3, opened: true), travelDistance: 10 + 6)
        #expect(!vault.buttons.isEnabled, "removed once out of view (with the door)")
    }

    /// The corridor's ease into and out of a gate is continuous: it meets cruise speed without a kink
    /// and stops exactly at the gate's start.
    @Test func theGateTravelEaseIsContinuous() {
        let v: Float = 5.2, t = GateTravelEase.duration
        #expect(GateTravelEase.distance(lead: 0, speed: v) == 0)
        #expect(abs(GateTravelEase.distance(lead: t, speed: v) - v * Float(2 * t / 3)) < 1e-5)
        #expect(abs(GateTravelEase.distance(lead: t + 0.5, speed: v) - v * Float(t + 0.5 - t / 3)) < 1e-5, "cruises in at full speed")
        #expect(GateTravelEase.speedFactor(lead: 0) == 0)
        #expect(abs(GateTravelEase.speedFactor(lead: t - 1e-6) - 1) < 1e-4)
        #expect(GateTravelEase.speedFactor(lead: 5) == 1 && GateTravelEase.speedFactor(lead: nil) == 1)
        // The door's eased distance and the corridor's eased speed agree (d′ = v · factor).
        for i in 1..<40 {
            let l = t * Double(i) / 40, h = 1e-3
            let slope = (GateTravelEase.distance(lead: l + h, speed: v) - GateTravelEase.distance(lead: l - h, speed: v)) / Float(2 * h)
            #expect(abs(slope - v * GateTravelEase.speedFactor(lead: l)) < 2e-2)
            #expect(GateTravelEase.speedFactor(lead: l) <= 1, "never faster than cruise")
            #expect(GateTravelEase.distance(lead: l, speed: v) <= GateTravelEase.distance(lead: l + 0.01, speed: v), "monotonic")
        }
    }

    /// HIGH regression (iPad, 12 November 2026): the dock assist had started only when the riding
    /// consoles arrived, i.e. at the gate's start, so the first button (usually HIGH) was judged
    /// while the mascot still glided in and its zone sat further out. It now runs from
    /// `dockLead` before the gate, as it did when the consoles appeared early; the reach still waits
    /// for the consoles to arrive.
    @Test func theDockAssistStartsBeforeTheGateAndTheReachWhenTheConsolesArrive() async throws {
        _ = await PlayerHoverboard.sharedTemplate()
        let scene = LaserScene()
        let layer = RobotAvatarLayer(scene: scene, players: [.player1], templates: try await RobotAvatarLayer.sharedTemplates())
        scene.robotAvatars = layer
        let configuration = try LaserRoundConfiguration(evidenceTiming: .init(windowBefore: 0.125, windowAfter: 0.125, deliveryAllowance: 0.125),
                                                        clearanceMargin: 0.005, diamondPoints: 25)
        let vault = VaultPresentation(scene: scene, configuration: configuration)
        vault.reducesMotion = { true }
        vault.visiblePlayers = [.player1]
        vault.liveConsoles = { [weak layer] in layer?.consoles[$0] }
        let generation = UUID()
        func activity(_ lead: Double) -> LaserGameState {
            LaserGameState(sessionGeneration: generation, phase: .activity, gameTime: 60 - lead, activityProgress: 0.9, teamHealth: 5,
                           teamScore: 0, encounters: [])
        }
        vault.update(state: activity(6), travelDistance: 0, upcomingVaultIn: 6)
        #expect(!layer.docksActive && !layer.consolesActive, "6 s out: steering as usual")
        vault.update(state: activity(VaultPresentation.dockLead - 0.5), travelDistance: 0, upcomingVaultIn: VaultPresentation.dockLead - 0.5)
        #expect(layer.docksActive, "the dock assist runs before the gate")
        #expect(!layer.consolesActive, "the reach waits for the consoles to arrive")
        vault.update(state: LaserGameState(sessionGeneration: generation, phase: .vault, gameTime: 60, activityProgress: 1, teamHealth: 5,
                                           teamScore: 0, encounters: [], vault: LaserVaultState(id: UUID(), deadline: 65, buttons: [:])),
                     travelDistance: 0)
        #expect(layer.docksActive && layer.consolesActive, "at the gate: docked and reaching")
        layer.remove()
    }

    /// The team waits for the passage: after the last press the corridor's presented travel holds
    /// while the door is still opening, and resumes once it is clear; the authoritative next minute
    /// starts at once (game state unchanged).
    @Test func travelHoldsUntilTheOpenedDoorIsClear() async throws {
        let scene = LaserScene()
        Self.installTwoPanelDoor(on: scene)
        let configuration = try LaserRoundConfiguration(evidenceTiming: .init(windowBefore: 0.125, windowAfter: 0.125, deliveryAllowance: 0.125),
                                                        clearanceMargin: 0.005, diamondPoints: 25)
        let presenter = GameplayScenePresenter(scene: scene, configuration: configuration, encounters: [])
        presenter.vault.reducesMotion = { false }
        let generation = UUID(), id = UUID()
        let all: [PlayerID: Set<LaserVaultButton>] = [.player1: Set(LaserVaultButton.allCases), .player2: Set(LaserVaultButton.allCases)]
        func state(_ phase: LaserRoundPhase, _ t: Double, opened: Bool) -> LaserGameState {
            LaserGameState(sessionGeneration: generation, phase: phase, gameTime: t, activityProgress: 0.5, teamHealth: 5, teamScore: 0,
                           encounters: [], missionProgress: opened ? 1 : 0, vault: LaserVaultState(id: id, deadline: 65, buttons: opened ? all : [:], opened: opened))
        }
        presenter.apply(state: state(.vault, 60, opened: false), events: [], snapshot: nil)
        // The last press opens it; the next minute starts at once (activity again).
        presenter.apply(state: state(.activity, 61, opened: true), events: [], snapshot: nil)
        let atOpen = presenter.travelDistance
        presenter.apply(state: state(.activity, 61.4, opened: true), events: [], snapshot: nil)
        #expect(presenter.travelDistance == atOpen, "held while the door opens")
        #expect(scene.vaultDoorState == .open)
        let opening = VaultDoor.openingDuration(reduceMotion: false)
        presenter.apply(state: state(.activity, 61 + opening - 0.01, opened: true), events: [], snapshot: nil)
        #expect(presenter.travelDistance == atOpen, "still held just before the door is clear")
        presenter.apply(state: state(.activity, 61 + opening + 0.01, opened: true), events: [], snapshot: nil)
        let resumed = presenter.travelDistance
        presenter.apply(state: state(.activity, 61 + opening + 0.51, opened: true), events: [], snapshot: nil)
        #expect(abs(presenter.travelDistance - resumed - scene.layout.travelSpeed * 0.5) < 1e-3, "then travels on at cruise")
    }

    /// A door with two panels (as the authored one), installed on the scene.
    private static func installTwoPanelDoor(on scene: LaserScene) {
        let artwork = Entity(), root = Entity()
        root.name = "VaultDoorRoot"; artwork.addChild(root)
        let light = Entity(); light.name = "UnlockedLight"; root.addChild(light)
        for side in ["LeftDoorPanel", "RightDoorPanel"] {
            let panel = Entity(); panel.name = side; root.addChild(panel)
            let art = ModelEntity(mesh: .generatePlane(width: 2.4, height: 3.2)); art.name = "Art"; panel.addChild(art)
        }
        scene.installVaultDoor(artwork)
    }

    /// CONSECUTIVE GATES (iPad, 12 November 2026: after passing an opened gate the corridor stopped
    /// while lasers kept coming). Three gates in a row through the presenter, with wall consoles and
    /// mascots: each gate stops travel (the vault phase), the opened door holds it only until its
    /// passage is clear, then the corridor travels on through the whole next stage, past the old
    /// door and while the next door comes down the corridor, until the next gate; the dock assist
    /// still starts `dockLead` before each gate. The opened vault stays in game state through the
    /// next minute (Jevon's game), as here.
    @Test(arguments: [false, true]) func travelContinuesThroughEveryStageAfterAGateIsPassed(solo: Bool) async throws {
        _ = await PlayerHoverboard.sharedTemplate()
        let scene = LaserScene()
        Self.installTwoPanelDoor(on: scene)
        let players: [PlayerID] = solo ? [.player1] : [.player1, .player2]
        let layer = RobotAvatarLayer(scene: scene, players: Set(players), templates: try await RobotAvatarLayer.sharedTemplates())
        scene.robotAvatars = layer
        let configuration = try LaserRoundConfiguration(evidenceTiming: .init(windowBefore: 0.125, windowAfter: 0.125, deliveryAllowance: 0.125),
                                                        clearanceMargin: 0.005, diamondPoints: 25)
        let presenter = GameplayScenePresenter(scene: scene, configuration: configuration, encounters: [])
        presenter.vault.reducesMotion = { false }
        presenter.vault.visiblePlayers = Set(players)
        presenter.vault.liveConsoles = { [weak layer] in layer?.consoles[$0] }
        let generation = UUID(), dt = 0.1, stage = 30.0, speed = scene.layout.travelSpeed
        let opening = VaultDoor.openingDuration(reduceMotion: false)
        let all = Dictionary(uniqueKeysWithValues: players.map { ($0, Set(LaserVaultButton.allCases)) })
        func state(_ phase: LaserRoundPhase, _ t: Double, _ vault: LaserVaultState?) -> LaserGameState {
            LaserGameState(sessionGeneration: generation, phase: phase, gameTime: t, activityProgress: 0.5, teamHealth: 5, teamScore: 0,
                           encounters: [], missionProgress: 0, vault: vault)
        }
        var t = 0.0, passed: LaserVaultState?, openedAt: Double?
        presenter.apply(state: state(.activity, 0, nil), events: [], snapshot: nil, upcomingVaultIn: stage) // the first frame sets the clock
        for gate in 1...3 {
            // The stage: activity, the previous (opened) vault still in state, the next gate ahead.
            let start = t, frames = Int((stage / dt).rounded())
            var oldDoorLeft = gate == 1, nextDoorCame = false
            for i in 1..<frames {
                t = start + Double(i) * dt
                let lead = Double(frames - i) * dt, before = presenter.travelDistance
                presenter.apply(state: state(.activity, t, passed), events: [], snapshot: nil, upcomingVaultIn: lead)
                let moved = presenter.travelDistance - before
                let released = openedAt.map { t - $0 > opening + dt } ?? true
                if let openedAt, t - openedAt < opening - dt / 2 {
                    #expect(moved == 0, "gate \(gate - 1): held while its door opens (t \(t))")
                } else if released {
                    let expected = speed * Float(dt) * GateTravelEase.speedFactor(lead: lead)
                    #expect(abs(moved - expected) < 1e-3,
                            "stage \(gate): the corridor travels on (t \(t), lead \(lead), moved \(moved), expected \(expected))")
                }
                if scene.vaultDoorDepth == nil { oldDoorLeft = true }
                if oldDoorLeft, presenter.vault.approaching { nextDoorCame = true }
                if released, lead > VaultPresentation.dockLead + dt { #expect(!layer.docksActive, "stage \(gate): free steering (lead \(lead))") }
                if !released, openedAt.map({ t - $0 < opening - dt / 2 }) == true { #expect(layer.docksActive, "held: still docked") }
                if lead < VaultPresentation.dockLead - dt { #expect(layer.docksActive, "stage \(gate): docking before the gate (lead \(lead))") }
            }
            #expect(oldDoorLeft && nextDoorCame, "stage \(gate): the old door left the view and the next one came down the corridor")
            // The gate: travel stops (a legitimate stop) until the presses open it.
            let vault = LaserVaultState(id: UUID(), deadline: t + 10, buttons: [:])
            let atGate = presenter.travelDistance
            for _ in 0..<10 {
                t += dt
                presenter.apply(state: state(.vault, t, vault), events: [], snapshot: nil)
            }
            #expect(presenter.travelDistance == atGate, "gate \(gate): stopped while it is pressed")
            #expect(layer.docksActive && layer.consolesActive, "gate \(gate): docked and reaching")
            // The last press: the next minute starts at once (activity), the vault opened in state.
            t += dt
            passed = LaserVaultState(id: vault.id, deadline: vault.deadline, buttons: all, opened: true)
            openedAt = t
            presenter.apply(state: state(.activity, t, passed), events: [], snapshot: nil, upcomingVaultIn: stage)
            #expect(presenter.travelDistance == atGate && scene.vaultDoorState == .open, "gate \(gate): opened, the team waits")
        }
        layer.remove()
    }
}
