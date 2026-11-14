import Foundation
import RealityKit
import Testing
@testable import Sedactive

/// The laser HIT zap (14 November 2026): one timeline from impact to the live pose, only for an
/// authoritative HIT, only on the struck mascot, never stacking, never left on screen, and never
/// moving the body that diamond contact reads.
@MainActor
struct LaserHitReactionTests {
    typealias R = LaserHitReaction
    private let degrees = Float.pi / 180

    // MARK: - The timeline

    @Test(arguments: [R.Region.upper, .lower]) func oneTimelineFromImpactBackToTheLivePose(region: R.Region) {
        let r = R(region: region, side: 1, reduceMotion: false, seed: 3)
        #expect(r.frame(at: -0.01).isRest && r.frame(at: R.duration).isRest && r.frame(at: 5).isRest)
        // Impact: the very first frame changes (hit-stop, contact squash, flash).
        let impact = r.frame(at: 0)
        #expect(impact.holdsPose && impact.squash < 0.97 && impact.flash > 0.9)
        #expect(r.frame(at: R.hitStop - 0.001).holdsPose && !r.frame(at: R.hitStop + 0.001).holdsPose)
        // Recoil: peaks ~110 ms, knocked toward `side` (+1: right, clockwise on screen), small overshoot.
        let peak = stride(from: 0.0, to: 0.3, by: 0.001).max { abs(R.recoil($0)) < abs(R.recoil($1)) } ?? 0
        #expect(peak > 0.08 && peak < 0.14, "\(peak)")
        #expect(r.frame(at: peak).roll < 0 && r.frame(at: peak).rootOffset.x > 0)
        #expect(R.recoil(0.28) < 0 && R.recoil(0.28) > -0.3)
        // Shudder: only in its window, a real vibration (many sign changes), decaying.
        #expect(R.shudderEnvelope(0.07) == 0 && R.shudderEnvelope(0.41) == 0)
        let shudder = stride(from: 0.09, to: 0.4, by: 1.0 / 240).map { R.shudder($0, phase: 0) }
        #expect(zip(shudder, shudder.dropFirst()).filter { $0.0 * $0.1 < 0 }.count >= 6)
        #expect(R.shudderEnvelope(0.12) > 2 * R.shudderEnvelope(0.3))
        // VFX peak with the body and are gone before the end.
        #expect(r.frame(at: 0.12).arcs > 0.7 && r.frame(at: 0.47).arcs == 0 && !r.frame(at: 0.5).sparks)
        // Small, controlled and continuous: no pop at 240 Hz, never out of its lane.
        var maxOffset: Float = 0, maxRoll: Float = 0, maxStep: Float = 0
        var last = r.frame(at: R.hitStop)
        for i in Int(R.hitStop * 240)...Int(R.duration * 240) {
            let f = r.frame(at: Double(i) / 240)
            maxOffset = max(maxOffset, simd_length(f.rootOffset))
            maxRoll = max(maxRoll, abs(f.roll))
            maxStep = max(maxStep, abs(f.roll - last.roll), abs(f.headRoll - last.headRoll) / 2)
            last = f
        }
        #expect(maxOffset < 0.08 && maxRoll < 15 * degrees, "offset \(maxOffset) roll \(maxRoll / degrees)°")
        #expect(maxStep < 4 * degrees, "\(maxStep / degrees)° per 1/240 s")
        // Lands on the live pose: the last instant is (almost) rest.
        let late = r.frame(at: R.duration - 0.001)
        #expect(abs(late.roll) < 1e-3 && abs(late.squash - 1) < 1e-3 && simd_length(late.rootOffset) < 1e-3)
    }

    @Test func reduceMotionIsAGentleHighlightOnly() {
        let r = R(region: .upper, side: -1, reduceMotion: true)
        let frames = (0...Int(R.duration * 240)).map { r.frame(at: Double($0) / 240) }
        #expect(frames.allSatisfy { !$0.holdsPose && $0.arcs == 0 && !$0.sparks && $0.headRoll == 0
            && $0.shoulderShrug == 0 && $0.rootOffset == .zero && abs($0.roll) < 3 * degrees })
        #expect(r.frame(at: 0.1).glow > 0.2 && r.frame(at: 0).flash > 0.4)
    }

    @Test func theBodyFlashesOnceThenCarriesASoftChargeThatEndsBeforeTheSettle() {
        let r = R(region: .lower, side: -1, reduceMotion: false, seed: 5)
        // The impact frame: the body's own surface is white-hot through the hit-stop.
        #expect(r.frame(at: 0).bodyFlash == 1 && r.frame(at: R.hitStop - 0.001).bodyFlash > 0.8)
        #expect(r.frame(at: 0.1).bodyFlash == 0, "one flash, gone by 100 ms")
        // The charge swells (never drops below 65 % of its envelope: a charge, not a strobe).
        let charge = stride(from: 0.07, to: 0.3, by: 1.0 / 240).map { R.charge($0) }
        #expect(charge.allSatisfy { $0 >= 0.6 }, "\(charge.min() ?? 0)")
        #expect(r.frame(at: 0.46).charge == 0 && r.frame(at: 0.5).charge == 0)
        // Reduce Motion: no white frame, one soft tint.
        let gentle = (0...Int(R.duration * 240)).map { R(region: .upper, side: 1, reduceMotion: true).frame(at: Double($0) / 240) }
        #expect(gentle.allSatisfy { $0.bodyFlash == 0 && $0.charge <= 0.55 } && gentle.contains { $0.charge > 0.3 })
    }

    @Test func theBodyTintBrightensWithoutReplacingTheMascotsColour() {
        let impact = LaserHitZap.bodyTint(flash: 1, charge: 0), charge = LaserHitZap.bodyTint(flash: 0, charge: 1)
        #expect(impact.intensity > charge.intensity && charge.intensity < 1, "emission adds to the authored colour")
        #expect(LaserHitZap.bodyTint(flash: 0, charge: 0).intensity == 0)
    }

    // MARK: - On the mascots

    /// The emission of the mascot's own (skinned) model's materials.
    private func emission(_ layer: RobotAvatarLayer, _ scene: LaserScene, _ player: PlayerID) throws -> [Float] {
        let model = try #require(RobotAvatarLayer.skinnedModel(in: try container(scene, player)))
        return (model.model?.materials ?? []).compactMap { ($0 as? PhysicallyBasedMaterial)?.emissiveIntensity }
    }

    @Test func eachStruckMascotsOwnSurfaceIsChargedAndRestoredExactly() async throws {
        let (scene, layer) = try await layer()
        let authored = try emission(layer, scene, .player1), authored2 = try emission(layer, scene, .player2)
        #expect(!authored.isEmpty, "the mascots' materials are physically based")
        scene.setLaserBand(lowerEdge: 1.239, upperEdge: 1.261)
        // Both struck at once: each charges on its own.
        scene.presentOutcome(.hit, for: .player1)
        scene.presentOutcome(.hit, for: .player2)
        layer.render(now: 5)
        #expect(layer.isBodyCharged(.player1) && layer.isBodyCharged(.player2))
        #expect(try emission(layer, scene, .player1).allSatisfy { $0 > 1 }, "the impact frame is hot")
        layer.render(now: 5.2)
        #expect(try emission(layer, scene, .player1) != authored)
        // Done: the authored materials, exactly.
        layer.render(now: 5.7)
        #expect(!layer.isBodyCharged(.player1) && !layer.isBodyCharged(.player2))
        #expect(try emission(layer, scene, .player1) == authored && emission(layer, scene, .player2) == authored2)
        // A stop mid-reaction restores them too.
        scene.presentOutcome(.hit, for: .player2)
        layer.render(now: 6)
        #expect(layer.isBodyCharged(.player2))
        scene.clearLaserFeedback()
        #expect(!layer.isBodyCharged(.player2))
        #expect(try emission(layer, scene, .player2) == authored2)
    }

    private func layer() async throws -> (LaserScene, RobotAvatarLayer) {
        let scene = LaserScene()
        scene.installEnvironment(authored: nil)
        let layer = RobotAvatarLayer(scene: scene, players: Set(PlayerID.allCases), templates: try await RobotAvatarLayer.sharedTemplates())
        scene.robotAvatars = layer
        layer.smoothing = 0.03
        // Settled rest pose (no body data).
        for i in 0...300 { layer.render(now: Double(i) / 60) }
        return (scene, layer)
    }

    private func container(_ scene: LaserScene, _ player: PlayerID) throws -> Entity {
        try #require(scene.players[player]?.findEntity(named: "player.\(player.rawValue).robot"))
    }

    private func zap(_ scene: LaserScene, _ player: PlayerID) -> Entity? {
        scene.players[player]?.findEntity(named: "player.\(player.rawValue).laserHitZap")
    }

    @Test func onlyTheStruckMascotReactsAndDiamondContactNeverSeesIt() async throws {
        let (scene, layer) = try await layer()
        let p1 = try container(scene, .player1), p2 = try container(scene, .player2)
        let rest1 = p1.transform, rest2 = p2.transform
        let contactBefore = layer.diamondContactBody(.player1)
        #expect(!contactBefore.isEmpty)
        scene.setLaserBand(lowerEdge: 1.239, upperEdge: 1.261)
        scene.presentOutcome(.hit, for: .player1)
        #expect(layer.isReactingToHit(.player1) && !layer.isReactingToHit(.player2))
        #expect(layer.hitReaction(.player1)?.region == .upper, "a high beam strikes the upper body")
        var tilted = false, zapShown = false
        for i in 1...80 {
            layer.render(now: 5 + Double(i) / 120)
            #expect(simd_distance(p2.position, rest2.translation) < 1e-4 && p2.orientation == rest2.rotation && p2.scale == rest2.scale,
                    "P2 is never moved by P1's hit")
            if abs(p1.orientation.angle) > 2 * degrees { tilted = true }
            if zap(scene, .player1)?.isEnabled == true { zapShown = true }
            // Diamond contact reads the pose without the zap.
            let contact = layer.diamondContactBody(.player1)
            #expect(contact.count == contactBefore.count && zip(contact, contactBefore).allSatisfy {
                simd_distance($0.start, $1.start) < 1e-3 && simd_distance($0.end, $1.end) < 1e-3
            }, "t \(i)")
        }
        #expect(tilted && zapShown)
        #expect(zap(scene, .player2) == nil, "no effect built for P2")
        // Done: back to the live pose, nothing left on screen.
        layer.render(now: 6.5)
        #expect(!layer.isReactingToHit(.player1))
        #expect(simd_distance(p1.position, rest1.translation) < 1e-4 && p1.orientation == rest1.rotation
                && simd_distance(p1.scale, rest1.scale) < 1e-5)
        #expect(zap(scene, .player1)?.isEnabled == false)
    }

    @Test func onlyAHitShocksAndRepeatedHitsNeverStack() async throws {
        let (scene, layer) = try await layer()
        scene.setLaserBand(lowerEdge: 0.249, upperEdge: 0.271)
        scene.presentOutcome(.clear, for: .player1)
        scene.presentOutcome(.unavailable, for: .player2)
        #expect(!layer.isReactingToHit(.player1) && !layer.isReactingToHit(.player2), "CLEAR and UNAVAILABLE never shock")
        scene.presentOutcome(.hit, for: .player2)
        #expect(layer.hitReaction(.player2)?.region == .lower, "a low beam strikes the legs")
        layer.render(now: 5.01)
        let first = layer.hitReaction(.player2)
        layer.render(now: 5.06)
        scene.presentOutcome(.hit, for: .player2)
        #expect(layer.hitReaction(.player2) == first, "50 ms later: the same hit, not a second one")
        layer.render(now: 5.3)
        scene.presentOutcome(.hit, for: .player2)
        #expect(layer.hitReaction(.player2) != first, "a later HIT restarts the reaction")
        layer.render(now: 5.31)
        #expect(layer.hitFrame(.player2)?.holdsPose == true, "from its own impact, not stacked on the first")
        // Both struck: each reacts on its own.
        scene.presentOutcome(.hit, for: .player1)
        layer.render(now: 5.36)
        #expect(layer.isReactingToHit(.player1) && layer.isReactingToHit(.player2))
        #expect(layer.hitFrame(.player1)?.holdsPose == true && layer.hitFrame(.player2)?.holdsPose == false)
        // A new round or a stop mid-reaction: nothing stays.
        scene.clearLaserFeedback()
        for player in PlayerID.allCases {
            #expect(!layer.isReactingToHit(player))
            #expect(try container(scene, player).orientation == simd_quatf(ix: 0, iy: 0, iz: 0, r: 1))
            #expect(zap(scene, player)?.isEnabled == false)
        }
        layer.remove()
        #expect(zap(scene, .player2) == nil && zap(scene, .player1) == nil)
    }
}
