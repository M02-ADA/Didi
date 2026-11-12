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

    /// The consoles appear (all red) a few seconds before the gate, while the door approaches, so the
    /// players can steer to their docks first; nothing is judged before the gate.
    @Test func theConsolesAppearBeforeTheGate() throws {
        let scene = LaserScene()
        let configuration = try LaserRoundConfiguration(evidenceTiming: .init(windowBefore: 0.125, windowAfter: 0.125, deliveryAllowance: 0.125),
                                                        clearanceMargin: 0.005, diamondPoints: 25)
        let vault = VaultPresentation(scene: scene, configuration: configuration)
        vault.reducesMotion = { true }
        vault.liveConsoles = { Self.console($0) }
        let activity = LaserGameState(sessionGeneration: UUID(), phase: .activity, gameTime: 50, activityProgress: 0.2,
                                      teamHealth: 5, teamScore: 0, encounters: [])
        vault.update(state: activity, travelDistance: 0, upcomingVaultIn: 10)
        #expect(vault.consoleViews.isEmpty, "not yet: 10 s before the gate")
        vault.update(state: activity, travelDistance: 0, upcomingVaultIn: VaultPresentation.consoleLead - 0.5)
        let p1 = try #require(vault.consoleViews[.player1])
        #expect(p1.root.isEnabled && LaserVaultButton.allCases.allSatisfy { p1.states[$0] == .available }, "shown, all red")
    }
}
