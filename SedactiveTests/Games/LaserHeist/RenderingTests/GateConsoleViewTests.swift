import Foundation
import RealityKit
import Testing
import UIKit
@testable import Sedactive

/// Each player's ONE activation button on the corridor's side wall, the Blender asset `GateButton.usdz`
/// (Kevin, task owner, 19–20 November 2026; it replaced the HIGH / MIDDLE / LOW buttons): UNAVAILABLE
/// (cap sunk, accents dark) while the gate comes in, AVAILABLE (red cap and halo) during the gate,
/// (press) → PRESSED (cap locked down, still RED) once per gate, and OPENED (green cap, halo and light)
/// only once the gate is open: RED = GATE CLOSED, GREEN = GATE OPEN (20 November 2026). Driven only by the
/// game's `vault.buttons` and `vault.opened`. Presentation tests: no judge here.
@MainActor
struct GateConsoleViewTests {
    private static let arm = LaserGateConsole.Arm(shoulder: [0.154, 0.693], length: 0.369)
    private static func console(_ player: PlayerID) -> LaserGateConsole {
        LaserGateConsole(player: player, arm: arm, visibleHalfWidth: 2.583, wallHalfWidth: 4.41, planeZ: 0)
    }

    private static func near(_ depth: Float?, _ expected: Float) -> Bool { depth.map { abs($0 - expected) < 1e-5 } ?? false }

    private static func all(_ entity: Entity) -> [Entity] { [entity] + entity.children.flatMap { all($0) } }

    /// A console view drawing the loaded Blender asset.
    private static func view(_ player: PlayerID) async throws -> GateConsoleView {
        _ = try #require(await GateConsoleView.sharedTemplate(), "GateButton.usdz loads from RealityKitContent")
        let view = GateConsoleView(console: console(player))
        #expect(view.usesAsset)
        return view
    }

    @Test func theButtonGoesFromUnavailableToLiveToActivatedOnceAndStaysActivated() async throws {
        let view = try await Self.view(.player1)
        typealias P = GateConsoleView.Palette
        #expect(view.state == .unavailable && view.glowColor() == P.accentOff)
        #expect(Self.near(view.capDepth(), GateConsoleView.capLowered), "not ready: the cap sits sunk in its socket")
        view.reset(ready: true, reduceMotion: true)
        #expect(view.state == .available && view.glowColor() == P.accent)
        #expect(Self.near(view.capDepth(), GateConsoleView.capRest) && view.arms == 0, "ready: the cap stands proud (Reduce Motion: no spring)")
        view.complete(reduceMotion: true)
        #expect(view.state == .completed && view.glowColor() == P.accent && !view.capIsGreen)
        #expect(Self.near(view.capDepth(), GateConsoleView.capSettled), "pressed: locked down, still red")
        view.complete(reduceMotion: true)
        view.complete(.activate, reduceMotion: false)
        #expect(view.presses[.activate] == 1, "one press per gate")
        #expect(view.state == .completed, "stays pressed")
        view.setUnavailable()
        #expect(view.state == .completed && !view.capIsGreen, "a pressed button stays pressed (red) when the gate times out")
        view.open(reduceMotion: true)
        #expect(view.state == .opened && view.glowColor() == P.success && view.capIsGreen, "the gate is open: green")
        #expect(Self.near(view.capDepth(), GateConsoleView.capSettled), "open: still locked down")
        view.complete(reduceMotion: true)
        #expect(view.state == .opened && view.presses[.activate] == 1, "a press after opening changes nothing")
        view.reset(ready: true, reduceMotion: true)
        #expect(view.state == .available && view.presses.isEmpty && Self.near(view.capDepth(), GateConsoleView.capRest), "a new gate: back up and live")
        view.setUnavailable()
        #expect(view.state == .unavailable && Self.near(view.capDepth(), GateConsoleView.capLowered), "timed out unpressed: sunk, dark")
        #expect(GateConsoleView.capPressed < GateConsoleView.capSettled && GateConsoleView.capSettled < GateConsoleView.capLowered
                && GateConsoleView.capLowered < GateConsoleView.capRest, "travel: bottomed < locked < sunk < rest")
    }

    /// The modelled cap really moves along its own axis: proud of the collar at rest, its edge down
    /// to the collar when bottomed, never into the socket floor; the housing never moves.
    @Test func theCapTravelsInItsSocket() async throws {
        let view = try await Self.view(.player2)
        let entities = Self.all(view.root)
        let cap = try #require(entities.first { $0.name == "Cap" })
        let housing = try #require(entities.first { $0.name == "Housing" })
        let mount = view.buttonMount
        view.reset(ready: true, reduceMotion: true)
        let rest = cap.visualBounds(relativeTo: mount)
        let housingRest = housing.visualBounds(relativeTo: mount)
        print(String(format: "CAP rest front %.3f, radius %.3f · housing z %.3f…%.3f, %.3f across", rest.max.z, rest.extents.x / 2,
                     housingRest.min.z, housingRest.max.z, housingRest.extents.x))
        #expect(abs(rest.max.z - LaserGateConsole.capFront) < 0.003, "the asset's cap front is the console's: \(rest.max.z)")
        #expect(abs(rest.extents.x / 2 - LaserGateConsole.radius) < 0.003 && abs(rest.extents.y / 2 - LaserGateConsole.radius) < 0.003)
        #expect(abs(housingRest.extents.x / 2 - LaserGateConsole.plateHalf) < 0.005, "the plate: \(housingRest.extents.x) m across")
        // The housing is the plate (and its screws), behind the plate's front; the asset's body behind it is
        // its own part (`Body`, not shown on the door frame) and keeps its authored depth.
        #expect(housingRest.max.z < 0.01 && housingRest.min.z > -LaserGateConsole.plateDepth - 0.01, "the housing is the plate")
        let body = try #require(entities.first { $0.name == "Body" }).visualBounds(relativeTo: mount)
        #expect(body.min.z < -LaserGateConsole.bodyDepth + 0.01 && body.max.z < 0.01, "the body: \(body.min.z)…\(body.max.z)")
        #expect(rest.max.z - LaserGateConsole.collarFront >= 0.04, "rest: proud of the collar by \(rest.max.z - LaserGateConsole.collarFront) m")
        view.complete(reduceMotion: true)
        let locked = cap.visualBounds(relativeTo: mount)
        #expect(abs(locked.max.z - rest.max.z - GateConsoleView.capSettled) < 1e-3, "it travels along its own axis")
        #expect(abs(locked.center.x - rest.center.x) < 1e-4 && abs(locked.center.y - rest.center.y) < 1e-4)
        let bottom = LaserGateConsole.capEdgeFront + GateConsoleView.capPressed
        #expect(abs(bottom - LaserGateConsole.collarFront) < 0.001, "bottomed: its edge level with the collar")
        #expect(rest.min.z + GateConsoleView.capPressed > -0.035, "never past the socket floor (3.5 cm behind the plate)")
        #expect(housing.visualBounds(relativeTo: mount) == housingRest, "the housing never moves")
        #expect(GateConsoleView.capRest - GateConsoleView.capPressed >= 0.02, "a real travel")
    }

    /// The button on the gate's door frame (owner, 20 November 2026), built into a compact access module
    /// (`GateAccessModule`): a shallow access panel flush on the frame's jamb band, its neck (the collar)
    /// up to the plate's back, an indicator; the button model, its glow and its light; and nothing else:
    /// no jamb block, toe-kick, niche, bezel, ribs, box or stand. The asset's body (made to sink into a
    /// stand) is not shown.
    @Test func theButtonIsBuiltIntoAnAccessModuleOnTheGateFrame() async throws {
        for player in PlayerID.allCases {
            let console = Self.console(player)
            let view = try await Self.view(player)
            let entities = Self.all(view.root)
            #expect(!entities.contains { ["vault.console.housing", "vault.console.toeKick", "vault.console.panel", "vault.console.wallModule",
                                          "vault.console.bezel", "vault.console.rib", "vault.console.strip", "Head", "Post", "PostStrip", "Foot",
                                          "vault.console.pedestal", "vault.console.base"].contains($0.name) }, "\(player): no extra structure")
            // The access module: from the door's surface (its outline and panel) to the plate's back (the neck),
            // wholly on the jamb, no taller than its panel.
            let mount = try #require(entities.first { $0.name == "vault.console.mount" }).visualBounds(relativeTo: nil)
            let panel = try #require(entities.first { $0.name == "vault.console.mount.panel" }).visualBounds(relativeTo: nil)
            let collar = try #require(entities.first { $0.name == "vault.console.collar" }).visualBounds(relativeTo: nil)
            print(String(format: "MOUNT %@ module x %.3f…%.3f y %.3f…%.3f z %.3f…%.3f · panel x %.3f…%.3f · neck z %.3f…%.3f · door %+.3f",
                         player.rawValue, mount.min.x, mount.max.x, mount.min.y, mount.max.y, mount.min.z, mount.max.z,
                         panel.min.x, panel.max.x, collar.min.z, collar.max.z, console.doorZ))
            #expect(abs(mount.min.z - console.doorZ) < 1e-3 && abs(mount.max.z - (console.doorZ + LaserGateConsole.standoff)) < 1e-3,
                    "\(player): the module spans the door to the plate")
            #expect(abs(panel.min.z - console.doorZ) < 1e-3 && abs(panel.max.z - (console.doorZ + LaserGateConsole.panelDepth)) < 1e-3,
                    "\(player): a shallow panel flush on the frame")
            #expect(abs(collar.min.z - panel.max.z) < 1e-3 && abs(collar.max.z - (console.doorZ + LaserGateConsole.standoff)) < 1e-3,
                    "\(player): the neck from the panel to the plate's back")
            #expect(LaserGateConsole.jamb.contains(min(abs(mount.min.x), abs(mount.max.x)))
                    && LaserGateConsole.jamb.contains(max(abs(mount.min.x), abs(mount.max.x))), "\(player): wholly on the jamb")
            #expect(mount.extents.y <= LaserGateConsole.panelSize.y + 0.02 && mount.extents.x <= LaserGateConsole.panelSize.x + 0.02,
                    "\(player): compact")
            #expect(collar.extents.x <= LaserGateConsole.neckSize.x + 1e-3 && collar.extents.y <= LaserGateConsole.neckSize.y + 1e-3,
                    "\(player): the neck stays under the plate")
            // The asset's stand body is not shown (it would hang in front of the door).
            let body = try #require(entities.first { $0.name == "Body" })
            #expect(!body.isEnabled, "\(player): no body behind the plate")
            // The button model in front of the collar, compact (the plate's size).
            let b = try #require(entities.first { $0.name == "vault.console.buttonModel" }).visualBounds(relativeTo: nil)
            #expect(b.extents.x < 2 * LaserGateConsole.plateHalf + 0.02 && b.extents.y < 2 * LaserGateConsole.plateHalf + 0.02,
                    "\(player): compact, the plate's size")
            #expect(b.max.z - console.doorZ < LaserGateConsole.standoff + LaserGateConsole.plateDepth + LaserGateConsole.capFront + 0.01,
                    "\(player): stands \(b.max.z - console.doorZ) m off the door")
            let glow = try #require(entities.first { $0.name == "vault.console.glow" })
            #expect(simd_distance(glow.position(relativeTo: nil), console.button.center) < 1e-5)
            #expect(simd_distance(glow.orientation(relativeTo: nil).act([0, 0, 1]), console.button.normal) < 1e-4, "the glow faces the camera")
            let halo = try #require(entities.first { $0.name == "vault.console.halo" })
            #expect(abs(halo.position(relativeTo: nil).z - console.doorZ) < 0.01, "\(player): the halo on the door's surface")
            #expect(entities.filter { $0.name == "vault.console.light" }.count == 1)
        }
    }

    /// The access module's indicator shows the button's state, in the frame art's flat unlit style:
    /// dark while unavailable, red while live, green once activated (access granted), red again on reset.
    @Test func theModulesIndicatorShowsTheButtonsState() async throws {
        let view = try await Self.view(.player2)
        let indicator = try #require(Self.all(view.root).first { $0.name == "vault.console.mount.indicator" } as? ModelEntity)
        func shown() -> UInt32? {
            guard let material = indicator.model?.materials.first as? UnlitMaterial else { return nil }
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            material.color.tint.getRed(&r, green: &g, blue: &b, alpha: &a)
            return UInt32((r * 255).rounded()) << 16 | UInt32((g * 255).rounded()) << 8 | UInt32((b * 255).rounded())
        }
        typealias P = GateConsoleView.Palette
        #expect(shown() == P.accentOff, "unavailable: dark")
        view.reset(ready: true, reduceMotion: true)
        #expect(shown() == P.accent, "live: red")
        view.complete(reduceMotion: true)
        #expect(shown() == P.accent, "pressed, gate closed: red")
        view.open(reduceMotion: true)
        #expect(shown() == P.success, "gate open: green")
        view.reset(ready: true, reduceMotion: true)
        #expect(shown() == P.accent, "the next gate: red again")
        // Unlit like the door's own art, so the module matches the frame's painted tones.
        let panel = try #require(Self.all(view.root).first { $0.name == "vault.console.mount.panel" } as? ModelEntity)
        #expect(panel.model?.materials.allSatisfy { $0 is UnlitMaterial } == true)
    }

    /// Closed gate: a strong red cap with a soft red halo, pressed or not; open gate: the cap turns
    /// green, a bright green halo and a green light (the existing values). Reset brings the red back.
    @Test func redWhileClosedAndGreenOnlyOnceOpen() async throws {
        let view = try await Self.view(.player1)
        typealias P = GateConsoleView.Palette
        func red() -> Bool { !view.capIsGreen && view.haloColor == P.haloRed && view.lightLevel == 0 && view.glowColor() != P.success }
        view.reset(ready: true, reduceMotion: true)
        #expect(red() && view.haloOpacity > 0)
        view.complete(reduceMotion: true)
        #expect(red() && view.haloOpacity == GateConsoleView.haloIdle, "pressed, gate closed: the existing red glow")
        view.open(reduceMotion: true)
        #expect(view.capIsGreen && view.haloColor == P.haloGreen && view.haloOpacity == GateConsoleView.haloActive)
        #expect(view.lightLevel == GateConsoleView.lightIntensity && view.glowColor() == P.success)
        view.reset(ready: true, reduceMotion: true)
        #expect(red(), "a new gate: red again")
        view.setUnavailable()
        #expect(view.haloOpacity == 0 && !view.capIsGreen, "timed out: dark")
        // Animated: the press never turns it green, however long it is held closed.
        view.reset(ready: true, reduceMotion: false)
        view.complete(reduceMotion: false)
        for _ in 0..<16 { try await Task.sleep(for: .milliseconds(25)); #expect(!view.capIsGreen && view.lightLevel == 0) }
        #expect(red() && view.glowColor() == P.accent, "the press's flash settles back to red")
        view.open(reduceMotion: false)
        #expect(view.capIsGreen && view.haloColor == P.haloGreen && view.lightLevel > GateConsoleView.lightIntensity, "green at once when open")
        for _ in 0..<60 where view.glowColor() != P.success || view.lightLevel != GateConsoleView.lightIntensity {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(view.glowColor() == P.success && view.lightLevel == GateConsoleView.lightIntensity, "settled green")
        // Opening an unpressed button changes nothing.
        let other = try await Self.view(.player2)
        other.reset(ready: true, reduceMotion: true)
        other.open(reduceMotion: true)
        #expect(other.state == .available && !other.capIsGreen && other.opens == 0)
    }

    /// The accents build up as the fist reaches toward the live button, from the existing reach
    /// readings; nothing builds up otherwise.
    @Test func theLiveButtonBuildsUpAsTheFistApproaches() async throws {
        let view = try await Self.view(.player1)
        view.setApproach(1)
        #expect(view.approachLevel == 0, "unavailable: nothing")
        view.reset(ready: true, reduceMotion: false)
        #expect(view.approachLevel == 0 && view.glowColor() == GateConsoleView.Palette.accent)
        view.setApproach(0.5)
        #expect(view.approachLevel == 2)
        view.setApproach(1)
        #expect(view.approachLevel == 3 && view.glowColor() == GateConsoleView.Palette.accentHot, "the fist on the button: full build-up")
        view.complete(reduceMotion: false)
        view.setApproach(1)
        #expect(view.approachLevel == 0, "activated: no build-up")
    }

    /// Arming: when the gate's time starts the cap springs up (once per gate).
    @Test func theCapArmsWithASpringWhenTheGateStarts() async throws {
        let view = try await Self.view(.player2)
        view.reset(ready: false, reduceMotion: false)
        #expect(view.arms == 0 && Self.near(view.capDepth(), GateConsoleView.capLowered))
        view.reset(ready: true, reduceMotion: false)
        #expect(view.arms == 1 && Self.near(view.capDepth(), GateConsoleView.capRest), "rises to rest")
        view.reset(ready: true, reduceMotion: false)
        #expect(view.arms == 1, "already up: no second spring")
    }

    /// The animated press: the cap drives in and locks and the accents flash, settling back to red;
    /// the gate opening then turns it green, once.
    @Test func theAnimatedPressLocksTheCapAndStaysRedUntilOpen() async throws {
        let view = try await Self.view(.player2)
        view.reset(ready: true, reduceMotion: false)
        view.complete(reduceMotion: false)
        view.setSideComplete(true, reduceMotion: false)
        #expect(view.state == .completed, "completed at once (the game decided)")
        #expect(view.glowColor() == GateConsoleView.Palette.flash, "the impact flash")
        #expect(abs((view.capDepth() ?? 0) - GateConsoleView.capSettled) < 1e-5, "ends locked down (the animation plays from rest)")
        #expect(view.sideComplete)
        // The flash settles back to red (polled: other main-actor tests may delay the tasks).
        for _ in 0..<60 where view.glowColor() != GateConsoleView.Palette.accent { try await Task.sleep(for: .milliseconds(50)) }
        #expect(view.glowColor() == GateConsoleView.Palette.accent && !view.capIsGreen, "settled red: the gate is still closed")
        view.open(reduceMotion: false)
        view.open(reduceMotion: false)
        #expect(view.opens == 1 && view.state == .opened)
        for _ in 0..<60 where view.glowColor() != GateConsoleView.Palette.success { try await Task.sleep(for: .milliseconds(50)) }
        #expect(abs((view.capDepth() ?? 0) - GateConsoleView.capSettled) < 1e-5)
        #expect(view.glowColor() == GateConsoleView.Palette.success && view.capIsGreen, "settled green")
    }

    /// One modelled button where the console puts it, facing the way it faces, on the approved stand;
    /// nothing left of the three-button column, and no hit targets (the game alone decides).
    @Test func oneDrawnButtonAndNoLeftoverTargets() async throws {
        for player in PlayerID.allCases {
            let console = Self.console(player)
            let view = try await Self.view(player)
            let entities = Self.all(view.root)
            let buttons = entities.filter { $0.name.hasPrefix("vault.console.button.") }
            #expect(buttons.count == 1 && buttons.first?.name == "vault.console.button.activate")
            // The asset's separate parts (each a USD Xform holding its mesh), in one button model.
            #expect(entities.filter { $0.name == "vault.console.buttonModel" }.count == 1)
            for part in ["Housing", "Collar", "Socket", "Cap", "Accents"] {
                #expect(entities.contains { $0.name == part && $0.components.has(ModelComponent.self) }, "\(player) \(part)")
            }
            // The glow's parts; nothing left of the wall module, the floor stand, the column or its plate.
            for part in ["vault.console.glow", "vault.console.halo", "vault.console.light", "vault.console.collar", "vault.console.mount",
                         "vault.console.mount.panel", "vault.console.mount.indicator"] {
                #expect(entities.filter { $0.name == part }.count == 1, "\(player) \(part)")
            }
            #expect(!entities.contains { ["Head", "Post", "PostStrip", "Foot", "vault.console.pedestal", "vault.console.base", "vault.console.plate",
                                          "vault.console.check", "vault.console.label"].contains($0.name) })
            #expect(!entities.contains { ["vault.console.wallModule", "vault.console.housing", "vault.console.toeKick", "vault.console.bezel"].contains($0.name) })
            #expect(!entities.contains { $0.name.contains("top") || $0.name.contains("middle") || $0.name.contains("bottom") })
            #expect(entities.allSatisfy { $0.components[CollisionComponent.self] == nil && $0.components[InputTargetComponent.self] == nil })
            let mount = view.buttonMount
            #expect(simd_distance(mount.position, console.button.center) < 1e-5)
            #expect(simd_distance(mount.orientation.act([0, 0, 1]), console.button.normal) < 1e-4, "its axis is the button's normal")
            #expect(simd_distance(mount.orientation.act([0, 1, 0]), console.button.up) < 1e-4)
            // The contact point is on the modelled cap's front face at rest (where the fist lands).
            view.reset(ready: true, reduceMotion: true)
            let local = mount.convert(position: console.button.contact, from: view.root)
            let cap = try #require(entities.first { $0.name == "Cap" }).visualBounds(relativeTo: mount)
            #expect(hypot(local.x, local.y) < LaserGateConsole.radius && local.z <= cap.max.z + 1e-4 && local.z >= LaserGateConsole.capEdgeFront - 1e-4,
                    "\(player): the contact is on the cap's face: \(local)")
        }
    }

    /// Through the vault presentation: unavailable while the gate comes in, available when it begins,
    /// the game's activation completes it and lights the console; a timeout darkens an unpressed one.
    @Test func theVaultPresentationDrivesTheConsolesFromGameState() throws {
        let scene = LaserScene()
        let configuration = try LaserRoundConfiguration(evidenceTiming: .init(windowBefore: 0.125, windowAfter: 0.125, deliveryAllowance: 0.125),
                                                        clearanceMargin: 0.005, diamondPoints: 25)
        let vault = VaultPresentation(scene: scene, configuration: configuration)
        vault.reducesMotion = { true }
        vault.liveConsoles = { Self.console($0) }
        let id = UUID(), generation = UUID()
        func state(_ buttons: [PlayerID: Set<LaserVaultButton>], at t: Double, phase: LaserRoundPhase = .vault) -> LaserGameState {
            LaserGameState(sessionGeneration: generation, phase: phase, gameTime: t, activityProgress: 0, teamHealth: 5, teamScore: 0,
                           encounters: [], vault: LaserVaultState(id: id, deadline: 5, buttons: buttons))
        }
        vault.update(state: state([:], at: 0), travelDistance: 0)
        let p1 = try #require(vault.consoleViews[.player1]), p2 = try #require(vault.consoleViews[.player2])
        #expect(p1.root.isEnabled && p2.root.isEnabled)
        #expect(p1.state == .available && p2.state == .available, "the gate's time runs: both ready")
        vault.update(state: state([.player1: [.activate]], at: 1), travelDistance: 0)
        #expect(p1.state == .completed && p2.state == .available, "each player's own button")
        #expect(p1.sideComplete && !p2.sideComplete)
        #expect(!p1.capIsGreen, "pressed, gate closed: red")
        vault.update(state: state([.player1: [.activate]], at: 2), travelDistance: 0)
        #expect(p1.presses[.activate] == 1 && !p1.capIsGreen, "stays red, pressed once")
        // Timeout (the game ends the round as vaultFailed): P2's unpressed button goes dark, P1 stays red.
        vault.update(state: state([.player1: [.activate]], at: 5, phase: .ended(.vaultFailed)), travelDistance: 0)
        #expect(p2.state == .unavailable && p1.state == .completed && !p1.capIsGreen && !p2.capIsGreen)
    }

    /// The colour the access module's indicator bar shows.
    private static func indicatorColor(_ view: GateConsoleView) -> UInt32? {
        guard let bar = all(view.root).first(where: { $0.name == "vault.console.mount.indicator" }) as? ModelEntity,
              let material = bar.model?.materials.first as? UnlitMaterial else { return nil }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        material.color.tint.getRed(&r, green: &g, blue: &b, alpha: &a)
        return UInt32((r * 255).rounded()) << 16 | UInt32((g * 255).rounded()) << 8 | UInt32((b * 255).rounded())
    }

    /// RED = GATE CLOSED, GREEN = GATE OPEN, through the vault presentation with a real two-panel door:
    /// closed → red; each press → still red; the game unlocks the gate (`vault.opened`) → green at once
    /// (cap, halo, light and the module's indicator), on the frame the door starts opening, and green
    /// throughout its opening and after; the next gate and a replay reset → red again. Co-op (both
    /// players) and Solo (P1 only), with and without Reduce Motion. Game state only; nothing here judges.
    @Test(arguments: [(false, false), (true, false), (false, true), (true, true)])
    func theButtonsTurnGreenWhenTheGameUnlocksTheGate(reduceMotion: Bool, solo: Bool) throws {
        let scene = LaserScene()
        Self.installTwoPanelDoor(on: scene)
        let configuration = try LaserRoundConfiguration(evidenceTiming: .init(windowBefore: 0.125, windowAfter: 0.125, deliveryAllowance: 0.125),
                                                        clearanceMargin: 0.005, diamondPoints: 25)
        let vault = VaultPresentation(scene: scene, configuration: configuration)
        let roster: [PlayerID] = solo ? [.player1] : [.player1, .player2]
        vault.reducesMotion = { reduceMotion }
        vault.visiblePlayers = Set(roster)
        vault.liveConsoles = { Self.console($0) }
        let generation = UUID(), first = UUID(), second = UUID()
        func state(_ id: UUID, _ buttons: [PlayerID: Set<LaserVaultButton>], at t: Double, opened: Bool = false,
                   phase: LaserRoundPhase = .vault) -> LaserGameState {
            LaserGameState(sessionGeneration: generation, phase: phase, gameTime: t, activityProgress: 0, teamHealth: 5, teamScore: 0,
                           encounters: [], missionProgress: 0, vault: LaserVaultState(id: id, deadline: t + 10, buttons: buttons, opened: opened))
        }
        typealias P = GateConsoleView.Palette
        vault.update(state: state(first, [:], at: 0), travelDistance: 0)
        let views = try roster.map { try #require(vault.consoleViews[$0]) }
        func red(_ v: GateConsoleView) -> Bool {
            !v.capIsGreen && v.haloColor == P.haloRed && v.lightLevel == 0 && v.glowColor() != P.success && Self.indicatorColor(v) != P.success
        }
        func green(_ v: GateConsoleView) -> Bool {
            v.state == .opened && v.capIsGreen && v.haloColor == P.haloGreen && v.haloOpacity == GateConsoleView.haloActive
                && v.lightLevel >= GateConsoleView.lightIntensity && Self.indicatorColor(v) == v.glowColor()
        }
        #expect(views.allSatisfy { red($0) && $0.state == .available }, "closed: red")
        if !solo {
            vault.update(state: state(first, [.player1: [.activate]], at: 1), travelDistance: 0)
            #expect(views[0].state == .completed && views.allSatisfy(red), "P1 pressed, gate still locked: red")
        }
        let all = Dictionary(uniqueKeysWithValues: roster.map { ($0, Set(LaserVaultButton.allCases)) })
        // The last press: the game unlocks the gate on the same frame. Green at once, as the door starts opening.
        vault.update(state: state(first, all, at: 2, opened: true), travelDistance: 0)
        #expect(scene.vaultDoorState == .open)
        #expect(views.allSatisfy(green), "unlocked: green as the door starts opening")
        #expect(views.allSatisfy { $0.opens == 1 })
        // Throughout the opening (travel is still held: the door is not yet clear), green.
        let opening = VaultDoor.openingDuration(reduceMotion: reduceMotion)
        for share in [0.25, 0.6, 0.95] {
            let mid = state(first, all, at: 2 + opening * share, opened: true)
            #expect(vault.holdsTravel(for: mid), "the door is still opening at \(share)")
            vault.update(state: mid, travelDistance: 0)
            #expect(views.allSatisfy(green), "green while the door opens (\(share))")
        }
        // Fully open, the team passing: still green, shown once.
        vault.update(state: state(first, all, at: 2 + opening + 0.01, opened: true), travelDistance: 0)
        vault.update(state: state(first, all, at: 4, opened: true, phase: .activity), travelDistance: 0.5)
        #expect(views.allSatisfy { green($0) && $0.opens == 1 }, "stays green; shown once")
        // The next gate: red again.
        vault.update(state: state(second, [:], at: 60), travelDistance: 40)
        #expect(views.allSatisfy { red($0) && $0.state == .available }, "the next gate: red")
        vault.update(state: state(second, [roster.last!: [.activate]], at: 61), travelDistance: 40)
        #expect(views.last?.state == .completed && views.allSatisfy(red), "pressed, still locked: red")
        // A replay restart (reset): red, not ready.
        vault.reset()
        #expect(views.allSatisfy { red($0) && $0.state == .unavailable }, "reset: red")
    }

    /// A gate that times out never shows green: the pressed button stays red, the unpressed one goes
    /// dark, through the timeout and after it.
    @Test(arguments: [false, true]) func aTimedOutGateNeverShowsGreen(reduceMotion: Bool) throws {
        let scene = LaserScene()
        Self.installTwoPanelDoor(on: scene)
        let configuration = try LaserRoundConfiguration(evidenceTiming: .init(windowBefore: 0.125, windowAfter: 0.125, deliveryAllowance: 0.125),
                                                        clearanceMargin: 0.005, diamondPoints: 25)
        let vault = VaultPresentation(scene: scene, configuration: configuration)
        vault.reducesMotion = { reduceMotion }
        vault.liveConsoles = { Self.console($0) }
        let id = UUID(), generation = UUID()
        func state(_ t: Double, _ phase: LaserRoundPhase = .vault) -> LaserGameState {
            LaserGameState(sessionGeneration: generation, phase: phase, gameTime: t, activityProgress: 0, teamHealth: 5, teamScore: 0,
                           encounters: [], vault: LaserVaultState(id: id, deadline: 5, buttons: [.player1: [.activate]]))
        }
        vault.update(state: state(0), travelDistance: 0)
        let p1 = try #require(vault.consoleViews[.player1]), p2 = try #require(vault.consoleViews[.player2])
        vault.markFailed(id)
        for t in [5.0, 6, 8] {
            vault.update(state: state(t, .ended(.vaultFailed)), travelDistance: 0)
            #expect(!p1.capIsGreen && !p2.capIsGreen && p1.lightLevel == 0 && p2.lightLevel == 0 && p1.opens == 0)
            #expect(p1.state == .completed && p2.state == .unavailable && scene.vaultDoorState != .open)
        }
    }

    /// The gate is one structure: the buttons on the side walls come down the corridor with the door,
    /// a fixed distance in front of it, arriving at their places exactly when the door reaches its
    /// stop, just behind the players (20 November 2026: the buttons on the gate's frame). Without the
    /// buttons the door keeps its authored stop.
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
        #expect(abs(stop - (scene.mapping.interactionPlaneZ - LaserGateConsole.doorDepth)) < 1e-5 && stop > scene.layout.vaultDoorStopZ,
                "with the buttons the door stops \(LaserGateConsole.doorDepth) m beyond the players")
        let button = Self.console(.player1).button
        #expect(abs(button.center.z - LaserGateConsole.plateDepth - LaserGateConsole.standoff - stop) < 1e-5, "the collar stands on the door")
        let generation = UUID()
        func activity(_ t: Double) -> LaserGameState {
            LaserGameState(sessionGeneration: generation, phase: .activity, gameTime: t, activityProgress: 0.2, teamHealth: 5, teamScore: 0, encounters: [])
        }
        // Far: the consoles are already part of the approaching gate, riding with the door.
        vault.update(state: activity(50), travelDistance: 0, upcomingVaultIn: 3)
        let p1 = try #require(vault.consoleViews[.player1])
        #expect(p1.root.isEnabled && p1.state == .unavailable, "coming in with the door: not ready yet")
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
        #expect(p1.root.isEnabled && vault.indicator(.player1, .activate) == .idle)
        #expect(p1.state == .available, "the gate's time starts: ready")
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
        #expect(LaserVaultButton.allCases.allSatisfy { p1.states[$0] == .opened }, "open (no door art: clear at once): green")
        // Travel resumes: the consoles move with the corridor (and the door), not with the mascots.
        vault.update(state: state(.activity, 1.5, opened: true), travelDistance: 11.2)
        #expect(abs(vault.buttons.position.z - 1.2) < 1e-4, "passing the players with the corridor")
        #expect(vault.buttons.isEnabled && LaserVaultButton.allCases.allSatisfy { p1.states[$0] == .opened })
        // Past the camera: cleaned up with the door.
        // (The door keeps its authored stop, 7.5 m down the corridor, so that is further.)
        vault.update(state: state(.activity, 3, opened: true), travelDistance: 10 + 12)
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
