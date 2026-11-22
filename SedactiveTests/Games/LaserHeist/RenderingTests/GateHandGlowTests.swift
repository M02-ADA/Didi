import Foundation
import RealityKit
import Testing
@testable import Sedactive

/// The gate's hand cue (Kevin, 22 November 2026): the mascot's pressing hand glows while its
/// player's button is live, flares on the game's activation, then fades; dark on timeout and
/// reset. Presentation only.
@MainActor
struct GateHandGlowTests {
    // MARK: The envelope (pure)

    @Test func aLiveCueRampsInWithoutAJumpAndStaysClearlyVisible() {
        var glow = GateHandGlow()
        #expect(!glow.advance(to: .off, at: 0).isVisible, "no gate: nothing")
        let first = glow.advance(to: .live, at: 1)
        #expect(first.aura < 0.05, "the ramp starts from dark (\(first.aura))")
        var previous = first.aura
        for k in 1...8 {
            let f = glow.advance(to: .live, at: 1 + GateHandGlow.rampIn * Double(k) / 8, reduceMotion: true)
            #expect(f.aura >= previous - 1e-6, "eases in monotonically")
            previous = f.aura
        }
        // Settled: clearly noticeable, breathing gently, never a strobe.
        let levels = stride(from: 1.5, to: 3.5, by: 1.0 / 30).map { glow.advance(to: .live, at: $0).aura }
        #expect(levels.min()! > 0.7 && levels.max()! <= 1, "steady and readable: \(levels.min()!)…\(levels.max()!)")
        #expect(levels.max()! - levels.min()! < 0.25, "the breathing is subtle")
        #expect(zip(levels, levels.dropFirst()).allSatisfy { abs($0 - $1) < 0.05 }, "no frame-to-frame jumps")
    }

    @Test func theFistOnTheButtonChargesTheGlowAndSettlesItsBreathing() {
        var glow = GateHandGlow()
        _ = glow.advance(to: .live, at: 0)
        let far = stride(from: 1.0, to: 2.1, by: 1.0 / 30).map { glow.advance(to: .live, at: $0, approach: 0) }
        let near = stride(from: 2.1, to: 3.2, by: 1.0 / 30).map { glow.advance(to: .live, at: $0, approach: 1) }
        #expect(near.map(\.aura).min()! > far.map(\.aura).min()!, "brighter on the button")
        #expect(near.map(\.auraScale).min()! > far.map(\.auraScale).max()! - 0.05, "a little larger on the button")
        let spread = near.dropFirst(10).map(\.aura).max()! - near.dropFirst(10).map(\.aura).min()!
        #expect(spread < 0.01, "steady with the fist on the button (\(spread))")
    }

    @Test func aPressFlaresThenFadesOutCleanly() {
        var glow = GateHandGlow()
        _ = glow.advance(to: .live, at: 0)
        let before = glow.advance(to: .live, at: 2)
        let rise = glow.advance(to: .pressed, at: 2)
        #expect(abs(rise.aura - before.aura) < 0.02 && abs(rise.auraScale - before.auraScale) < 0.02, "the flare starts from what is shown")
        let peak = glow.advance(to: .pressed, at: 2 + GateHandGlow.flareRise)
        #expect(peak.aura > 0.99 && peak.auraScale > 1.35, "contact: a bright bump (\(peak.auraScale))")
        #expect(peak.flare > 0.5, "and a ring thrown out")
        let settled = glow.advance(to: .pressed, at: 2 + GateHandGlow.flareSettle)
        #expect(abs(settled.auraScale - 1) < 0.02 && settled.flare < 0.15, "settled after the flare")
        #expect(glow.advance(to: .pressed, at: 2 + GateHandGlow.pressHold).aura > 0.95, "a brief hold")
        let fading = glow.advance(to: .pressed, at: 2 + GateHandGlow.pressHold + GateHandGlow.pressFade / 2).aura
        #expect(fading > 0.3 && fading < 0.95, "then a fade (\(fading))")
        #expect(!glow.advance(to: .pressed, at: 2 + GateHandGlow.pressDuration).isVisible, "gone within a second, never lingering")
        #expect(GateHandGlow.pressDuration < 1)
        // The gate opening (still `pressed` for the cue) does not light it again.
        #expect(!glow.advance(to: .pressed, at: 4).isVisible)
    }

    @Test func aTimeoutOrResetFadesTheLiveGlowAndTheNextGateLightsItAgain() {
        var glow = GateHandGlow()
        _ = glow.advance(to: .live, at: 0)
        let shown = glow.advance(to: .live, at: 1).aura
        let start = glow.advance(to: .off, at: 1)
        #expect(abs(start.aura - shown) < 0.02, "the fade starts from what is shown")
        let mid = glow.advance(to: .off, at: 1 + GateHandGlow.fadeOut / 2).aura
        #expect(mid > 0.1 && mid < shown, "eases out")
        #expect(!glow.advance(to: .off, at: 1 + GateHandGlow.fadeOut).isVisible, "gone after the fade")
        // The next gate: live again from dark.
        _ = glow.advance(to: .live, at: 5)
        #expect(glow.advance(to: .live, at: 5 + GateHandGlow.rampIn).aura > 0.7)
    }

    @Test func aButtonSeenAlreadyPressedLightsNothing() {
        var glow = GateHandGlow()
        _ = glow.advance(to: .off, at: 0)
        #expect(!glow.advance(to: .pressed, at: 0.1).isVisible)
        #expect(!glow.advance(to: .pressed, at: 0.2).isVisible)
        #expect(glow.phase == .off)
    }

    @Test func reduceMotionKeepsTheCueWithoutPulseSizeOrRing() {
        var glow = GateHandGlow()
        _ = glow.advance(to: .live, at: 0, reduceMotion: true)
        let live = stride(from: 0.5, to: 2.0, by: 1.0 / 30).map { glow.advance(to: .live, at: $0, reduceMotion: true) }
        #expect(live.allSatisfy { $0.auraScale == 1 && $0.aura > 0.8 }, "visible, no size change")
        #expect(live.map(\.aura).max()! - live.map(\.aura).min()! < 1e-4, "no breathing")
        let press = stride(from: 2.0, to: 3.0, by: 1.0 / 30).map { glow.advance(to: .pressed, at: $0, reduceMotion: true) }
        #expect(press.allSatisfy { $0.auraScale == 1 && $0.flare == 0 }, "no flare pop, no ring")
        #expect(!press.last!.isVisible, "still fades out")
    }

    // MARK: In the scene, through the real gate presentation

    private static func layer(_ players: Set<PlayerID>) async throws -> (LaserScene, RobotAvatarLayer, [PlayerID: AvatarReference]) {
        _ = await PlayerHoverboard.sharedTemplate()
        let input = try LaserReplayScript.load().input
        let scene = LaserScene()
        let calibrations = input.configuration.calibrations.filter { players.contains($0.key) }
        let layer = RobotAvatarLayer(scene: scene, calibrations: calibrations, layout: input.configuration.playerPlaneLayout,
                                     templates: try await RobotAvatarLayer.sharedTemplates())
        scene.robotAvatars = layer
        let references = calibrations.mapValues { AvatarReference(calibration: $0, layout: input.configuration.playerPlaneLayout) }
        return (scene, layer, references)
    }

    /// One synthetic frame: each player standing, arms down.
    private static func frame(_ layer: RobotAvatarLayer, _ generation: UUID, _ n: Int, _ references: [PlayerID: AvatarReference]) throws {
        let input = try LaserReplayScript.load().input
        let t = Double(n) / 30
        func v(_ x: Double) throws -> EstimatedScalar { try EstimatedScalar(value: x, validity: .valid) }
        var players: [PlayerID: PlayerBodySample] = [:], poses: [PlayerID: PresentationPoseSample] = [:]
        for (player, r) in references {
            let c = input.configuration.calibrations[player]!
            let h = r.standingHeight, L = r.laneCenterX
            func p(_ x: Double, _ y: Double) -> PresentationPoint { PresentationPoint(x: L + x, y: y, confidence: 0.9) }
            poses[player] = PresentationPoseSample(playerID: player, calibrationRevision: c.revision, joints: [
                .leftShoulder: p(0.13 * h, 0.82 * h), .rightShoulder: p(-0.13 * h, 0.82 * h),
                .leftHip: p(0.07 * h, r.standingHipY), .rightHip: p(-0.07 * h, r.standingHipY), .nose: p(0, 0.9 * h),
                .leftElbow: p(0.15 * h, 0.64 * h), .leftWrist: p(0.16 * h, 0.5 * h),
                .rightElbow: p(-0.15 * h, 0.64 * h), .rightWrist: p(-0.16 * h, 0.5 * h)])
            players[player] = PlayerBodySample(playerID: player, calibrationRevision: c.revision, trackingStatus: .reliable,
                geometry: BodyGeometry(crownY: try v(1.7), leftWristY: try v(1), rightWristY: try v(1), leftSoleY: try v(0),
                                       rightSoleY: try v(0), centerX: try v(L)),
                jumpState: JumpState(phase: .grounded, validity: .valid))
        }
        layer.apply(BodySnapshot(sessionGeneration: generation, frameID: UInt64(n), capturedAt: t, cameraGeometryRevision: 1, players: players),
                    joints: PresentationPoseFrame(sessionGeneration: generation, frameID: UInt64(n), capturedAt: t, players: poses))
    }

    @Test(arguments: [false, true])
    func theGateLifecycleDrivesEachPressingHandsGlow(solo: Bool) async throws {
        let roster: Set<PlayerID> = solo ? [.player1] : Set(PlayerID.allCases)
        let (scene, layer, references) = try await Self.layer(roster)
        let configuration = try LaserRoundConfiguration(evidenceTiming: .init(windowBefore: 0.125, windowAfter: 0.125, deliveryAllowance: 0.125),
                                                        clearanceMargin: 0.005, diamondPoints: 25)
        let vault = VaultPresentation(scene: scene, configuration: configuration)
        vault.reducesMotion = { false }
        vault.visiblePlayers = roster
        vault.liveConsoles = { layer.consoles[$0] }
        let id = UUID(), generation = UUID()
        var n = 0
        func state(_ buttons: [PlayerID: Set<LaserVaultButton>], opened: Bool = false, phase: LaserRoundPhase = .vault) -> LaserGameState {
            LaserGameState(sessionGeneration: generation, phase: phase, gameTime: Double(n) / 30, activityProgress: 0, teamHealth: 5,
                           teamScore: 0, encounters: [], vault: LaserVaultState(id: id, deadline: 30, buttons: buttons, opened: opened))
        }
        func run(_ frames: Int, _ s: () -> LaserGameState) throws {
            for _ in 0..<frames { n += 1; try Self.frame(layer, generation, n, references); vault.update(state: s(), travelDistance: 0) }
        }
        try run(2) { state([:], phase: .activity) }
        #expect(roster.allSatisfy { !layer.handGlowShown($0) }, "no gate: no glow")
        // The gate starts: each pressing hand lights.
        try run(15) { state([:]) }
        for player in roster {
            #expect(layer.handGlow(player)?.phase == .live, "\(player): live")
            #expect(layer.handGlowShown(player) && (layer.handGlow(player)?.shown.aura ?? 0) > 0.7, "\(player): clearly visible")
            // On the hand that presses: the console-side fist, as the camera sees it, in front of the body.
            let robot = try #require(layer.robots[player]), console = try #require(layer.consoles[player])
            let glow = try #require(layer.handGlowPositions[player])
            let camera = scene.layout.cameraPosition
            let sk = robot.solver.skeleton, world = sk.world(robot.model.jointTransforms).position
            let hands = ["Hand_L", "Hand_R"].compactMap { sk($0) }.map { robot.model.convert(position: world[$0], to: nil) }
            let pressing = try #require(hands.max { $0.x * console.side < $1.x * console.side })
            let other = try #require(hands.min { $0.x * console.side < $1.x * console.side })
            func screen(_ p: SIMD3<Float>) -> SIMD2<Float> { SIMD2(p.x - camera.x, p.y - camera.y) / (camera.z - p.z) }
            let onHand = simd_distance(screen(glow), screen(pressing)), offHand = simd_distance(screen(glow), screen(other))
            print(String(format: "GLOW %@ at (%+.3f, %.3f, %+.3f) · pressing hand (%+.3f, %.3f, %+.3f) · cap front z %+.3f · screen gap %.4f (other hand %.4f)",
                         player.rawValue, glow.x, glow.y, glow.z, pressing.x, pressing.y, pressing.z, console.button.contact.z, onHand, offHand))
            #expect(onHand < 0.03 && offHand > 3 * onHand, "\(player): drawn over the pressing hand only")
            #expect(glow.z > pressing.z + 0.2 && glow.z > console.button.contact.z + 0.2, "\(player): in front of the body and the button")
        }
        // P1 presses: P1's hand flares, then fades; the partner's stays live. (The cue set by one
        // frame's gate update shows from the next presented frame.)
        try run(3) { state([.player1: [.activate]]) }
        #expect(layer.handGlow(.player1)?.phase == .pressed && (layer.handGlow(.player1)?.shown.auraScale ?? 0) > 1.1, "P1: contact flare")
        if !solo { #expect(layer.handGlow(.player2)?.phase == .live, "P2 still cued") }
        try run(Int(GateHandGlow.pressDuration * 30) + 2) { state([.player1: [.activate]]) }
        #expect(!layer.handGlowShown(.player1), "P1: faded after the press")
        if solo {
            // Solo: P1's press opens the gate; nothing lights again.
            try run(10) { state([.player1: [.activate]], opened: true) }
            #expect(!layer.handGlowShown(.player1))
        } else {
            // Co-op: the gate times out before P2 presses: P2's glow fades, nothing flares.
            try run(2) { state([.player1: [.activate]], phase: .ended(.vaultFailed)) }
            #expect(layer.handGlow(.player2)?.phase == .off)
            try run(Int(GateHandGlow.fadeOut * 30) + 2) { state([.player1: [.activate]], phase: .ended(.vaultFailed)) }
            #expect(PlayerID.allCases.allSatisfy { !layer.handGlowShown($0) }, "timed out: no glow")
        }
        // A new gate after a reset lights the hands again.
        vault.reset()
        try run(2) { state([:], phase: .activity) }
        #expect(roster.allSatisfy { layer.handGlow($0)?.phase == .off })
        let next = UUID()
        for _ in 0..<15 {
            n += 1; try Self.frame(layer, generation, n, references)
            vault.update(state: LaserGameState(sessionGeneration: generation, phase: .vault, gameTime: Double(n) / 30, activityProgress: 0,
                                               teamHealth: 5, teamScore: 0, encounters: [],
                                               vault: LaserVaultState(id: next, deadline: 60, buttons: [:])), travelDistance: 0)
        }
        #expect(roster.allSatisfy { layer.handGlow($0)?.phase == .live && layer.handGlowShown($0) }, "next gate: lit again")
        layer.remove()
        #expect(roster.allSatisfy { !layer.handGlowShown($0) })
        withExtendedLifetime(scene) {}
    }
}
