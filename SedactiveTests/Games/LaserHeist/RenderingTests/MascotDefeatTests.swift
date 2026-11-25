import Foundation
import RealityKit
import Testing
import UIKit
@testable import Sedactive

/// The cartoon team defeat after a fatal HIT (Kevin, 23 November 2026; DEBUG preview, not yet in
/// the Game Over flow). Health is shared, so the team falls together. Presentation only: the
/// timeline (`MascotDefeat`), then the mascot layer.
@MainActor
struct MascotDefeatTests {
    private static func struck(_ side: Float = -1, reduce: Bool = false) -> MascotDefeat {
        MascotDefeat(role: .struck, side: side, reduceMotion: reduce)
    }

    private static func teammate(_ side: Float = 1, reduce: Bool = false, spreads: Bool = true) -> MascotDefeat {
        MascotDefeat(role: .teammate, side: side, reduceMotion: reduce, spreads: spreads)
    }

    /// Every configuration the preview shows: P1 or P2 struck, both struck, nobody (ambiguous), Solo.
    private static var teams: [[MascotDefeat]] {
        [[struck(-1), teammate(1)], [teammate(-1), struck(1)], [struck(-1), struck(1)],
         [teammate(-1, spreads: false), teammate(1, spreads: false)], [struck(-1)]]
    }

    private static func samples(_ end: Double = 3, rate: Double = 240) -> [Double] {
        stride(from: 0, through: end, by: 1 / rate).map { $0 }
    }

    // MARK: The timeline (pure)

    /// The fatal HIT plays as it is: the defeat adds nothing to the struck body until the
    /// overload, its board shows the HIT's own light and motion, and never its white impact again.
    @Test func theHitPlaysOnceAndTheDefeatBuildsOnIt() {
        let d = Self.struck()
        for t in stride(from: 0.0, to: 0.22, by: 1.0 / 120) {
            let f = d.frame(at: t)
            #expect(f.upperWeight == 0 && f.lowerWeight == 0 && f.armWeight == 0, "no scripted pose yet at \(t)")
            #expect(f.rootOffset == .zero && f.roll == 0 && f.squash == 1 && f.popAge == nil)
            #expect(f.boardTau == t, "the board's own HIT light")
            let hit = HoverboardReaction.hitMotion(t)
            #expect(f.boardRoll == hit.roll && f.boardLift == hit.lift, "the board's own HIT motion")
        }
        for team in Self.teams {
            for d in team {
                for t in Self.samples() where t >= MascotDefeat.overloadStart {
                    #expect(d.frame(at: t).boardTau >= 0.07, "no second white impact flash at \(t)")
                }
            }
        }
    }

    /// One climactic beat: every board in every configuration explodes at the same instant and is
    /// gone by the same instant.
    @Test func everyBoardExplodesAndVanishesTogether() {
        for team in Self.teams {
            for d in team {
                #expect(d.frame(at: MascotDefeat.popTime - 0.001).popAge == nil)
                #expect(d.frame(at: MascotDefeat.popTime).popAge == 0, "the boom at \(MascotDefeat.popTime) s")
                #expect(!d.frame(at: MascotDefeat.popTime - 0.001).boardGone)
                for t in Self.samples() where t >= MascotDefeat.vanishTime {
                    #expect(d.frame(at: t).boardGone, "gone from \(MascotDefeat.vanishTime) s (\(t))")
                }
                // It swells into the boom, then shrinks away inside the burst.
                #expect(d.frame(at: MascotDefeat.popTime - 0.005).boardScale > 1.05)
                #expect(d.frame(at: MascotDefeat.popTime + 0.02).boardScale > 1)
            }
        }
    }

    /// Nobody sits on an invisible board: once the boards are gone, every mascot comes down to
    /// the floor and stays seated there.
    @Test func everyMascotLandsSeatedOnTheFloor() {
        for team in Self.teams {
            for d in team {
                let land = d.landTime
                #expect(land > d.apexTime && land < 1.25, "lands \(land) s after the HIT")
                let landed = d.frame(at: land + 0.001)
                #expect(abs(landed.rootOffset.y + landed.boardLift + d.floorDrop) < 0.002, "the soles on the floor")
                #expect(landed.seat > 0.99 && landed.lowerWeight == 1 && landed.upperWeight == 1, "seated")
                for t in Self.samples() where t >= d.settledTime {
                    let f = d.frame(at: t)
                    #expect(abs(f.rootOffset.y + f.boardLift + d.floorDrop) < 1e-5 && f.boardGone && f.floorShadow == 1)
                    #expect(abs(f.squash - 1) < 0.03 && f.soot == 1 && f.smoke > 0.99)
                }
                // Airborne: never below the floor.
                for t in Self.samples(land) where t >= MascotDefeat.popTime {
                    let f = d.frame(at: t)
                    #expect(f.rootOffset.y + f.boardLift >= -d.floorDrop - 1e-4, "above the floor at \(t)")
                }
            }
        }
        // The struck mascot flies a little higher than its teammate; both land within ~0.1 s.
        let (a, b) = (Self.struck(), Self.teammate())
        #expect(a.apexHeight > b.apexHeight && abs(a.landTime - b.landTime) < 0.1)
    }

    @Test func noPoseSnapsAndNothingTeleports() {
        for team in Self.teams + [[Self.struck(reduce: true), Self.teammate(reduce: true)]] {
            for d in team {
                var previous = d.frame(at: 0)
                for t in Self.samples().dropFirst() {
                    let f = d.frame(at: t)
                    #expect(abs(f.roll - previous.roll) < 0.06 && abs(f.squash - previous.squash) < 0.06, "body at \(t)")
                    #expect(abs((f.rootOffset.y + f.boardLift) - (previous.rootOffset.y + previous.boardLift)) < 0.03, "height at \(t)")
                    #expect(abs(f.rootOffset.x - previous.rootOffset.x) < 0.01, "no sideways teleport at \(t)")
                    #expect(abs(f.boardRoll - previous.boardRoll) < 0.08, "board at \(t)")
                    #expect(abs(f.addHeadYaw - previous.addHeadYaw) < 0.03, "look at \(t)")
                    for side in RobotPoseTargets.Side.allCases {
                        if let a = f.arms[side], let b = previous.arms[side] {
                            #expect(simd_dot(a.upper, b.upper) > cos(0.2) && simd_dot(a.fore, b.fore) > cos(0.25), "arms at \(t)")
                        }
                    }
                    previous = f
                }
            }
        }
    }

    /// The teammate notices, the failure spreads to its board, and from then both boards flicker
    /// in sync.
    @Test func theFailureSpreadsToTheTeammate() {
        let s = Self.struck(-1), m = Self.teammate(1)
        // Before the spread: its own live pose and board, a startle and a look at Lemon.
        for t in Self.samples(MascotDefeat.spreadArrive - 0.001) {
            let f = m.frame(at: t)
            #expect(!f.drivesBoard && f.anchor < 1 && f.popAge == nil, "its own board until the spread (\(t))")
        }
        #expect(m.frame(at: 0.08).rootOffset.y > 0.02, "a startle at the HIT")
        #expect(m.frame(at: 0.45).addHeadYaw < -0.4, "looking toward Lemon")
        // The arc travels only on the struck board's side, from its start to its arrival.
        #expect(s.frame(at: MascotDefeat.spreadStart - 0.01).spreadAge == nil && s.frame(at: MascotDefeat.spreadStart + 0.05).spreadAge != nil)
        #expect(Self.samples().allSatisfy { m.frame(at: $0).spreadAge == nil })
        // Its board joins with a surge, then flickers in step with the struck board.
        #expect(m.frame(at: MascotDefeat.spreadArrive).drivesBoard)
        for t in Self.samples(MascotDefeat.popTime) where t >= MascotDefeat.spreadArrive + 0.05 {
            #expect(m.frame(at: t).boardTau == s.frame(at: t).boardTau, "the same light at \(t)")
        }
        // Nobody struck: no startle, no arc, every board fails from the overload.
        let alone = Self.teammate(spreads: false)
        #expect(alone.frame(at: 0.08).rootOffset == .zero && alone.frame(at: MascotDefeat.overloadStart).drivesBoard)
    }

    /// P1 and P2 fall as each other's reflection, each outward, away from the other. (The struck
    /// board's HIT motion before the overload is the existing HIT's, the same for both.)
    @Test func lemonAndTangerineMirrorEachOther() {
        for (a, b) in [(Self.struck(-1), Self.struck(1)), (Self.teammate(-1), Self.teammate(1))] {
            for t in stride(from: 0.0, through: 2.4, by: 0.01) {
                let x = a.frame(at: t), y = b.frame(at: t)
                #expect(abs(x.roll + y.roll) < 1e-5 && abs(x.rootOffset.x + y.rootOffset.x) < 1e-5, "body at \(t)")
                #expect(abs(x.addHeadYaw + y.addHeadYaw) < 1e-5)
                if t >= 0.32 { #expect(abs(x.boardYaw + y.boardYaw) < 1e-5 && abs(x.boardRoll + y.boardRoll) < 1e-5, "board at \(t)") }
                #expect(x.rootOffset.y == y.rootOffset.y && x.squash == y.squash && x.seat == y.seat)
            }
            #expect(a.frame(at: 1.0).rootOffset.x < 0 && b.frame(at: 1.0).rootOffset.x > 0, "thrown outward")
        }
    }

    /// Soot darkens the body a little: Lemon stays yellow, Tangerine orange.
    @Test func sootKeepsEachMascotsColour() {
        for hex: UInt32 in [0xF6CA58, 0xF78146] {
            let c = SIMD3<Float>(Float(hex >> 16 & 0xFF), Float(hex >> 8 & 0xFF), Float(hex & 0xFF)) / 255
            let s = c * MascotDefeat.sootTint
            var h0: CGFloat = 0, h1: CGFloat = 0, b0: CGFloat = 0, b1: CGFloat = 0
            UIColor(red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1).getHue(&h0, saturation: nil, brightness: &b0, alpha: nil)
            UIColor(red: CGFloat(s.x), green: CGFloat(s.y), blue: CGFloat(s.z), alpha: 1).getHue(&h1, saturation: nil, brightness: &b1, alpha: nil)
            #expect(abs(h0 - h1) < 0.02, "the same hue")
            #expect(b1 / b0 > 0.8, "darker, never black (\(b1 / b0))")
        }
    }

    /// Reduce Motion: no wobble, arc, launch or bounce; every board fades at the same moment
    /// before the mascots sink through where it was, and they sit on the floor.
    @Test func reduceMotionFadesAndSinksTogether() {
        for d in [Self.struck(reduce: true), Self.teammate(reduce: true)] {
            for t in Self.samples() {
                let f = d.frame(at: t)
                #expect(f.boardRoll == 0 && f.boardPitch == 0 && f.boardYaw == 0 && f.boardScale == 1 && f.squash == 1)
                #expect(f.spreadAge == nil && f.gather == 0 && f.rootOffset.y <= 0.001)
                #expect(HoverboardReaction.hit.arcs(at: f.boardTau, reduceMotion: f.boardLightsReduced).isEmpty, "no arcs at \(t)")
                if f.rootOffset.y < -0.02 { #expect(f.boardOpacity < 0.1, "the board is gone before the mascot sinks (\(t))") }
            }
            let end = d.frame(at: 1.6)
            #expect(end.boardGone && abs(end.rootOffset.y + d.floorDrop) < 1e-4 && end.seat == 1 && end.soot == 1)
        }
    }

    // MARK: The mascot layer

    private static func layer(_ players: Set<PlayerID> = Set(PlayerID.allCases)) async throws -> (LaserScene, RobotAvatarLayer) {
        _ = await PlayerHoverboard.sharedTemplate()
        let input = try LaserReplayScript.load().input
        let scene = LaserScene()
        let layer = RobotAvatarLayer(scene: scene, calibrations: input.configuration.calibrations.filter { players.contains($0.key) },
                                     layout: input.configuration.playerPlaneLayout,
                                     templates: try await RobotAvatarLayer.sharedTemplates())
        scene.robotAvatars = layer
        layer.smoothing = 0.03 // as the live presenter sets it; without it nothing renders
        return (scene, layer)
    }

    @Test func theTeamFallsTogetherOnceAndCancelsCleanly() async throws {
        let (scene, layer) = try await Self.layer()
        defer { layer.remove(); withExtendedLifetime(scene) {} }
        let lanes = try PlayerID.allCases.map { try #require(scene.players[$0]) }
        let boards = try PlayerID.allCases.map { try #require(layer.hoverboards[$0]) }
        var t = 0.0
        func render(_ seconds: Double) { for _ in 0..<Int((seconds * 60).rounded()) { t += 1.0 / 60; layer.render(now: t) } }
        render(0.5)

        // A nonfatal HIT never starts the defeat.
        layer.startHitReaction(.player1, contact: [0, 1.2, 0])
        render(0.7)
        #expect(layer.defeat(.player1) == nil && boards.allSatisfy { $0.defeat == nil })
        let rest = lanes.map(\.children.count) // the zap's entity included

        for cycle in 0..<3 {
            layer.startHitReaction(.player1, contact: [0, 1.2, 0])
            layer.startDefeat(.player1, as: .struck)
            layer.startDefeat(.player2, as: .teammate)
            render(1.0 / 60)
            let results = try #require(layer.defeatResultsTime)
            layer.startDefeat(.player1, as: .struck) // a repeat is ignored
            render(0.6)
            #expect(boards.allSatisfy { $0.defeat != nil && $0.root.isEnabled }, "both boards fail before the boom")
            render(0.2) // past the boom
            #expect(layer.defeatResultsTime == results, "one defeat per player")
            #expect(boards.allSatisfy { !$0.root.isEnabled }, "both boards gone in the boom")
            render(0.8) // landed and settled
            for (player, lane) in zip(PlayerID.allCases, lanes) {
                let robot = try #require(layer.robots[player])
                let floor = scene.layout.corridorFloorY - lane.position.y
                #expect(abs(robot.container.position.y - floor) < 0.02, "\(player) on the floor (\(robot.container.position.y) vs \(floor))")
                #expect(layer.isBodyCharged(player), "soot on \(player)")
            }
            layer.cancelDefeats()
            layer.cancelHitReactions()
            render(1.0 / 60)
            #expect(layer.defeat(.player1) == nil && layer.defeatResultsTime == nil)
            #expect(boards.allSatisfy { $0.defeat == nil && $0.root.isEnabled }, "both boards back")
            #expect(boards.allSatisfy { simd_distance($0.model.scale, SIMD3(repeating: PlayerHoverboard.scale)) < 1e-5 })
            for player in PlayerID.allCases {
                #expect(!layer.isBodyCharged(player), "the authored materials back")
                let robot = try #require(layer.robots[player])
                #expect(robot.container.orientation == simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), "upright again")
            }
            #expect(lanes.map(\.children.count) == rest, "cycle \(cycle): the effects built at load are reused, never added")
        }
    }

    // MARK: Game Over integration (`TeamDefeatCast`, `TeamDefeatGate`, the presenter)

    private static func event(_ kind: LaserGameEventKind, _ generation: UUID, _ n: UInt64) -> GameEvent {
        GameEvent(id: UUID(), sessionGeneration: generation, sequence: n, gameTime: Double(n), kind: kind)
    }

    /// Who is shown as struck comes only from the round's own events: the players hit in the
    /// encounter whose damage emptied the shared health.
    @Test func theCastIsReadFromTheFatalEncounter() {
        let g = UUID(), earlier = UUID(), fatal = UUID()
        let base: [GameEvent] = [
            Self.event(.playerHit(encounterID: earlier, playerID: .player2), g, 1),
            Self.event(.teamEffectsCommitted(encounterID: earlier, healthDelta: -1, scoreDelta: 0), g, 2),
            Self.event(.playerHit(encounterID: fatal, playerID: .player1), g, 3),
            Self.event(.teamEffectsCommitted(encounterID: fatal, healthDelta: -1, scoreDelta: 0), g, 4),
        ]
        #expect(TeamDefeatCast(events: base, generation: g) == nil, "no defeat before the round ends")
        let lost = base + [Self.event(.roundEnded(.healthDepleted), g, 5)]
        #expect(TeamDefeatCast(events: lost, generation: g)?.struck == [.player1], "P1's HIT emptied the health, not P2's earlier one")
        let both = Array(base.prefix(3)) + [Self.event(.playerHit(encounterID: fatal, playerID: .player2), g, 4)]
            + [Self.event(.teamEffectsCommitted(encounterID: fatal, healthDelta: -2, scoreDelta: 0), g, 5),
               Self.event(.roundEnded(.healthDepleted), g, 6)]
        #expect(TeamDefeatCast(events: both, generation: g)?.struck == [.player1, .player2])
        let unnamed = [Self.event(.teamEffectsCommitted(encounterID: fatal, healthDelta: -1, scoreDelta: 0), g, 1),
                       Self.event(.roundEnded(.healthDepleted), g, 2)]
        #expect(TeamDefeatCast(events: unnamed, generation: g)?.struck == [], "no struck player named: the shared presentation")
        #expect(TeamDefeatCast(events: base + [Self.event(.roundEnded(.vaultFailed), g, 5)], generation: g) == nil)
        #expect(TeamDefeatCast(events: lost, generation: UUID()) == nil, "another round's events are ignored")
    }

    /// The real all-HITs replay through the production presenter: the fatal encounter's HIT and the
    /// team defeat start in the same frame, the round's end keeps the HIT, Results waits for the
    /// defeat and then appears exactly once; the outcome and summary are the game's, untouched.
    @Test func aHealthDepletedReplayPlaysTheDefeatBeforeResults() async throws {
        let (scene, layer) = try await Self.layer()
        defer { layer.remove(); withExtendedLifetime(scene) {} }
        let script = try LaserReplayScript.complete(seed: 1, scenario: .healthDepleted)
        let session = try LaserReplayDriver.makeSession(script: script)
        try await session.start()
        let presenter = GameplayScenePresenter(scene: scene, configuration: script.configuration, encounters: script.encounters)
        let gate = TeamDefeatGate()
        let configuration = try #require(session.configuration)
        // What PlayView draws each frame: the HUD (through the gate) and whether Results shows.
        func hudNow() -> GameplayHUDModel? {
            guard gate.showsHUD(session.summary) else { return nil }
            return gate.hud(GameplayHUDModel(state: session.state, events: session.events, configuration: configuration,
                                             activityDuration: session.activityDuration, stageProgress: session.stageProgress),
                            roundEnded: session.summary != nil)
        }
        var now = 0.0, render = 0.0
        var lastPlayingHUD: GameplayHUDModel?
        while now < script.duration, session.summary == nil {
            try await session.advance(to: now)
            if let state = session.state {
                now = state.gameTime
                presenter.apply(state: state, events: session.events, snapshot: nil)
            }
            render += 1.0 / 30
            layer.render(now: render)
            #expect(!layer.isPlayingDefeat || session.summary != nil, "no defeat before the round ends")
            if session.summary == nil { lastPlayingHUD = hudNow() }
            now += 1.0 / 30
        }
        let summary = try #require(session.summary)
        #expect(summary.outcome == .healthDepleted && summary.remainingTeamHealth == 0)
        // The summary's first frame, before PlayView's `onChange` (`roundEnded`) has run: no Results,
        // the HUD still up, at zero hearts, the final score and the progress last shown in play.
        let lastPlaying = try #require(lastPlayingHUD)
        #expect(lastPlaying.health > 0, "the HUD showed hearts left before the fatal HIT")
        #expect(!gate.showsResults(summary), "Results never shows in the round's first terminal frame")
        func expectFrozenHUD(_ when: String) {
            guard let hud = hudNow() else { Issue.record("\(when): the HUD is gone"); return }
            #expect(hud.health == 0 && hud.maxHealth == lastPlaying.maxHealth, "\(when): zero hearts")
            #expect(hud.score == summary.teamScore, "\(when): the final score")
            #expect(hud.fillEnd == lastPlaying.fillEnd && hud.markerStates == lastPlaying.markerStates,
                    "\(when): the progress as last shown")
            #expect(hud.banner == .none && hud.diamondTimeRemaining == nil, "\(when): no transient banner")
        }
        expectFrozenHUD("first terminal frame")
        let cast = try #require(TeamDefeatCast(events: session.events, generation: summary.sessionGeneration))
        // The presenter started it with the fatal HIT, from the events.
        #expect(layer.isPlayingDefeat)
        for player in PlayerID.allCases {
            #expect(layer.defeat(player)?.role == (cast.struck.contains(player) ? .struck : .teammate))
        }
        // The round's end (PlayView: the gate, then the presentation stops) keeps the fatal HIT.
        // (PlayView passes the host clock, as its frame ticks do.)
        gate.roundEnded(summary, events: session.events, avatars: layer, now: CACurrentMediaTime())
        #expect(gate.holdsResults, "Results waits")
        presenter.stop()
        for player in cast.struck { #expect(layer.isReactingToHit(player), "\(player)'s fatal HIT keeps playing") }
        gate.roundEnded(summary, events: session.events, avatars: layer, now: CACurrentMediaTime()) // repeated: nothing new
        // As in a replay on the device: the presentation has stopped, so nothing presents the mascots
        // but the per-frame `keepDefeatMoving` (real time).
        let ageAtStop = try #require(layer.defeatAge)
        var shownAt: Double?
        var releases = 0, hides = 0
        var resultsShown = false
        let start = CACurrentMediaTime()
        while CACurrentMediaTime() < start + 3 {
            try await Task.sleep(for: .milliseconds(16))
            layer.keepDefeatMoving()
            gate.tick(now: CACurrentMediaTime(), avatars: layer)
            let shows = gate.showsResults(summary)
            if shows, !resultsShown { releases += 1; shownAt = CACurrentMediaTime() }
            if !shows, resultsShown { hides += 1 }
            resultsShown = shows
            if shows {
                #expect(hudNow() == nil, "the HUD leaves as Results comes in")
            } else {
                #expect(layer.isPlayingDefeat, "Results waits only while the defeat plays")
                expectFrozenHUD("during the defeat")
            }
        }
        #expect(releases == 1 && hides == 0, "Results appears exactly once and never leaves again")
        #expect((layer.defeatAge ?? 0) > 2.5, "the defeat kept playing after the presentation stopped")
        let shown = try #require(shownAt) - start + ageAtStop
        #expect(shown > MascotDefeat.resultsAt - MascotDefeat.resultsFade - 0.1 && shown < MascotDefeat.resultsAt,
                "Results fades in over the finishing pose (\(shown) s)")
        #expect(session.summary == summary, "the outcome and summary are the game's, unchanged")
    }

    /// Any other ending shows Results at once, as before; and Results is never held forever.
    @Test func otherEndingsAreUnchangedAndResultsIsNeverStuck() async throws {
        let script = try LaserReplayScript.complete(seed: 1, scenario: .vaultTimeout)
        let session = try LaserReplayDriver.makeSession(script: script)
        try await session.start()
        try await session.advance(to: script.duration)
        let summary = try #require(session.summary)
        #expect(summary.outcome == .vaultFailed)
        let (scene, layer) = try await Self.layer()
        defer { layer.remove(); withExtendedLifetime(scene) {} }
        let gate = TeamDefeatGate()
        gate.roundEnded(summary, events: session.events, avatars: layer, now: 0)
        #expect(!gate.holdsResults && !layer.isPlayingDefeat, "a vault timeout shows Results at once, no defeat")

        // A depleted round whose mascots never render: Results still comes, at the hold limit.
        let lost = try LaserReplayScript.complete(seed: 1, scenario: .healthDepleted)
        let depleted = try LaserReplayDriver.makeSession(script: lost)
        try await depleted.start()
        try await depleted.advance(to: lost.duration)
        let end = try #require(depleted.summary)
        let stuck = TeamDefeatGate()
        stuck.roundEnded(end, events: depleted.events, avatars: layer, now: 100)
        #expect(stuck.holdsResults)
        stuck.tick(now: 100 + TeamDefeatGate.holdLimit - 0.01, avatars: layer)
        #expect(stuck.holdsResults)
        stuck.tick(now: 100 + TeamDefeatGate.holdLimit, avatars: layer)
        #expect(!stuck.holdsResults, "released at the hold limit")
        // Exit or Play Again mid-defeat: the avatars go, the gate lets Results (or nothing) through.
        let gone = TeamDefeatGate()
        gone.roundEnded(end, events: depleted.events, avatars: layer, now: 0)
        layer.cancelDefeats()
        gone.tick(now: 0.1, avatars: layer)
        #expect(!gone.holdsResults)
        let none = TeamDefeatGate()
        none.roundEnded(end, events: depleted.events, avatars: nil, now: 0)
        #expect(!none.holdsResults, "no mascots: nothing to wait for")
    }

    // MARK: Final validation (Kevin, 24 November 2026)

    /// Every Game Over cast, the way the round's end starts it (`startTeamDefeat`): Solo, P1 only,
    /// P2 only, both, and nobody named. Each mascot gets its role, every board vanishes in the boom,
    /// every mascot lands on the floor, and the Results moment is the same for all.
    @Test(arguments: [
        ("solo", [PlayerID.player1], [PlayerID.player1]),
        ("p1", PlayerID.allCases, [.player1]),
        ("p2", PlayerID.allCases, [.player2]),
        ("both", PlayerID.allCases, PlayerID.allCases),
        ("shared", PlayerID.allCases, []),
    ])
    func everyCastFallsTogether(_ name: String, _ players: [PlayerID], _ struck: [PlayerID]) async throws {
        let (scene, layer) = try await Self.layer(Set(players))
        defer { layer.remove(); withExtendedLifetime(scene) {} }
        #expect(Set(layer.robots.keys) == Set(players))
        var t = 0.0
        func render(_ seconds: Double) { for _ in 0..<Int((seconds * 60).rounded()) { t += 1.0 / 60; layer.render(now: t) } }
        render(0.5)
        for player in struck { layer.startHitReaction(player, contact: [0, 1.2, 0]) } // the fatal HIT itself
        layer.startTeamDefeat(TeamDefeatCast(struck: Set(struck)))
        layer.startTeamDefeat(TeamDefeatCast(struck: Set(struck))) // the gate's repeat: idempotent
        for player in players {
            let defeat = try #require(layer.defeat(player), "\(name): \(player) falls")
            #expect(defeat.role == (struck.contains(player) ? .struck : .teammate), "\(name): \(player)'s role")
            #expect(defeat.spreads == !struck.isEmpty, "\(name): the arc only from a struck player")
        }
        #expect(layer.defeatResultsTime == nil, "set from each mascot's first defeat frame")
        render(1.0 / 60)
        #expect(layer.defeatResultsTime != nil)
        render(MascotDefeat.vanishTime + 0.05 - 1.0 / 60)
        #expect(players.allSatisfy { layer.hoverboards[$0]?.root.isEnabled == false }, "\(name): every board gone in the boom")
        render(MascotDefeat.resultsAt - MascotDefeat.vanishTime)
        for player in players {
            let robot = try #require(layer.robots[player]), lane = try #require(scene.players[player])
            let floor = scene.layout.corridorFloorY - lane.position.y
            #expect(abs(robot.container.position.y - floor) < 0.02, "\(name): \(player) on the floor")
            #expect(robot.container.isEnabled, "\(name): \(player) still shown at Results")
        }
        #expect(layer.isPlayingDefeat && (layer.defeatAge ?? 0) >= MascotDefeat.resultsAt - 0.02)
    }

    /// Exit (Home) or Play Again during the defeat: the scene's avatars go mid-boom, as `PlayView`
    /// tears them down. Nothing of the defeat stays in the lanes, nothing keeps the layer alive,
    /// and a fresh round (new scene, new layer) starts clean, round after round.
    @Test func exitAndPlayAgainMidDefeatLeaveNothingBehind() async throws {
        weak var lastLayer: RobotAvatarLayer?
        weak var lastFX: Entity?
        for round in 0..<4 {
            try await {
                let (scene, layer) = try await Self.layer()
                #expect(!layer.isPlayingDefeat, "round \(round) starts clean")
                for player in PlayerID.allCases {
                    #expect(layer.defeat(player) == nil && layer.hoverboards[player]?.defeat == nil)
                    #expect(layer.hoverboards[player]?.root.isEnabled == true)
                    #expect(!layer.isBodyCharged(player))
                }
                let lanes = PlayerID.allCases.compactMap { scene.players[$0] }
                let fxRoots = lanes.flatMap { $0.children.filter { $0.name.hasSuffix(".defeatFX") } }
                #expect(fxRoots.count == 2, "one set of effects per mascot, built at load")
                lastFX = fxRoots.first
                var t = 0.0
                for _ in 0..<30 { t += 1.0 / 60; layer.render(now: t) }
                layer.startHitReaction(.player1, contact: [0, 1.2, 0])
                layer.startTeamDefeat(TeamDefeatCast(struck: [.player1]))
                let gate = TeamDefeatGate()
                // Mid-boom (round 0, 2), or with Results already in (round 1, 3).
                let leaveAt = round.isMultiple(of: 2) ? MascotDefeat.popTime + 0.02 : MascotDefeat.resultsAt + 0.1
                for _ in 0..<Int((leaveAt * 60).rounded()) { t += 1.0 / 60; layer.render(now: t) }
                scene.robotAvatars = layer
                scene.detachLiveAvatars()
                #expect(scene.robotAvatars == nil && !layer.isPlayingDefeat && layer.defeatAge == nil)
                gate.tick(now: 0, avatars: scene.robotAvatars)
                #expect(!gate.holdsResults, "nothing waits on a defeat that is gone")
                for lane in lanes {
                    #expect(!lane.children.contains { $0.name.hasSuffix(".defeatFX") || $0.name.hasSuffix(".hoverboard") },
                            "round \(round): no effects or boards left in \(lane.name)")
                }
                lastLayer = layer
            }()
            #expect(lastLayer == nil, "round \(round): the layer is released")
            #expect(lastFX == nil, "round \(round): its effects are released")
        }
    }

    /// Results' gating needs no defeat state: any other ending shows Results (and drops the HUD) in
    /// its first frame, as before; a depleted round waits from its first frame; one round's release
    /// never lets another's Results through; Play Again (a fresh gate) shows the live HUD again.
    @Test func resultsGatingAndHUDContinuity() async throws {
        let timeout = try LaserReplayScript.complete(seed: 1, scenario: .vaultTimeout)
        let vault = try LaserReplayDriver.makeSession(script: timeout)
        try await vault.start()
        try await vault.advance(to: timeout.duration)
        let failed = try #require(vault.summary)
        let gate = TeamDefeatGate()
        #expect(gate.showsResults(failed) && !gate.showsHUD(failed), "a vault timeout: Results at once, no HUD")

        let lost = try LaserReplayScript.complete(seed: 1, scenario: .healthDepleted)
        var depleted: [RoundSummary] = []
        for _ in 0..<2 {
            let session = try LaserReplayDriver.makeSession(script: try lost.freshRound(generation: UUID()))
            try await session.start()
            try await session.advance(to: lost.duration)
            depleted.append(try #require(session.summary))
        }
        let (first, second) = (depleted[0], depleted[1])
        #expect(first.sessionGeneration != second.sessionGeneration)
        #expect(!gate.showsResults(first) && gate.showsHUD(first), "held before anything else runs")
        gate.roundEnded(first, events: [], avatars: nil, now: 0) // no mascots: nothing to wait for
        #expect(gate.showsResults(first) && !gate.showsHUD(first))
        #expect(!gate.showsResults(second), "another round's release never shows this one's Results")

        // Play Again: a fresh gate; the HUD is the session's live one again.
        let again = TeamDefeatGate()
        #expect(again.showsHUD(nil))
        let configuration = try LaserReplayScript.load().configuration
        let live = GameplayHUDModel(state: nil, events: [], configuration: configuration, activityDuration: 60)
        #expect(again.hud(live, roundEnded: false) == live)
        #expect(again.hud(nil, roundEnded: true) == live, "the HUD last shown in play is kept")
        #expect(TeamDefeatGate().hud(nil, roundEnded: true) == nil, "no HUD shown in play: nothing to freeze")
    }
}
