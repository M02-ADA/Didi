import Foundation
import RealityKit
import Testing
@testable import Sedactive

/// The vertical laser rendering adapter (16 November 2026): game-state cues to drawn frames, the
/// authoritative board override and the DEBUG one-laser replay. Presentation only.
@MainActor
struct VerticalLaserTrackTests {
    private let mapping = GameWorldMapping()
    private let layout = LaserWorldLayout()

    /// Phases equal up to float rounding of their times.
    private func same(_ a: VerticalLaser.Phase, _ b: VerticalLaser.Phase) -> Bool {
        switch (a, b) {
        case (.inactive, .inactive), (.off, .off): true
        case (.warning(let x), .warning(let y)): abs(x - y) < 1e-5
        case (.active(let x), .active(let y)), (.powerDown(let x), .powerDown(let y)): abs(x - y) < 1e-9
        default: false
        }
    }

    private func cue(_ outcome: VerticalLaserCue.Outcome = .pending, placedAt: Double = 7) -> VerticalLaserCue {
        VerticalLaserCue(id: UUID().uuidString, player: .player1, beamX: -0.45, halfWidth: 0.025, placedAt: placedAt,
                         warningTime: 7, cueTime: 8.6, crossingTime: 10, outcome: outcome)
    }

    @Test func theCorridorAxisIsTheOneWorldConversionAndKeepsP1Left() {
        #expect(mapping.worldX(corridorX: -0.45) == -0.45 * mapping.metersPerGameUnit)
        #expect(abs(mapping.corridorX(worldX: mapping.worldX(corridorX: 1.3)) - 1.3) < 1e-6)
        #expect(mapping.laneCorridorX(.player1) < mapping.laneCorridorX(.player2))
    }

    @Test func itIsFirstDrawnWhereItWillCrossAndFadesInWithoutMoving() {
        let c = cue()
        #expect(!VerticalLaserTrack.frame(c, at: 6.99, mapping: mapping, layout: layout).isVisible)
        let first = VerticalLaserTrack.frame(c, at: 7, mapping: mapping, layout: layout)
        #expect(first.isVisible && first.appearance == 0)
        var lastAppearance: Float = -1
        for step in 0...300 {
            let t = 7 + Double(step) / 100
            let f = VerticalLaserTrack.frame(c, at: t, mapping: mapping, layout: layout)
            // Sideways it never moves; it only fades in, never out, before its verdict.
            #expect(f.worldX == first.worldX)
            #expect(f.appearance >= lastAppearance)
            lastAppearance = f.appearance
        }
        #expect(VerticalLaserTrack.frame(c, at: 7 + VerticalLaserTrack.appearDuration, mapping: mapping, layout: layout).appearance == 1)
        // It reaches the players' plane exactly at its crossing.
        #expect(VerticalLaserTrack.frame(c, at: 10, mapping: mapping, layout: layout).worldZ == mapping.interactionPlaneZ)
    }

    @Test func itWarnsThenArmsAtItsCue() {
        let c = cue()
        #expect(same(VerticalLaserTrack.phase(c, at: 7), .warning(progress: 0)))
        #expect(same(VerticalLaserTrack.phase(c, at: 7.8), .warning(progress: Float(0.8 / 1.6))))
        #expect(same(VerticalLaserTrack.phase(c, at: 8.6), .active(elapsed: 0)))
        #expect(same(VerticalLaserTrack.phase(c, at: 10.3), .active(elapsed: 1.7)))
        // Placed before its warning (an earlier announcement), it approaches unpowered.
        #expect(same(VerticalLaserTrack.phase(cue(placedAt: 5), at: 5.5), .inactive))
    }

    @Test("CLEAR, UNAVAILABLE and a withdrawal power down at the verdict; a HIT strikes first",
          arguments: [VerticalLaserCue.Outcome.clear(at: 10.35), .unavailable(at: 10.35), .withdrawn(at: 10.35)])
    func itPowersDownFromItsOwnVerdict(outcome: VerticalLaserCue.Outcome) {
        let c = cue(outcome)
        #expect(same(VerticalLaserTrack.phase(c, at: 10.34), .active(elapsed: 10.34 - 8.6)))
        #expect(same(VerticalLaserTrack.phase(c, at: 10.45), .powerDown(elapsed: 10.45 - 10.35)))
        #expect(same(VerticalLaserTrack.phase(c, at: 10.35 + VerticalLaser.powerDownDuration + 1e-6), .off))
        #expect(!VerticalLaserTrack.frame(c, at: 11, mapping: mapping, layout: layout).isVisible)
        let hit = cue(.hit(at: 10.35))
        #expect(same(VerticalLaserTrack.phase(hit, at: 10.35 + LaserGate.longestTransition - 0.01), .active(elapsed: 10.35 + LaserGate.longestTransition - 0.01 - 8.6)))
        #expect(same(VerticalLaserTrack.phase(hit, at: 10.35 + LaserGate.longestTransition + 0.1), .powerDown(elapsed: 0.1)))
    }

    @Test func eachVerdictShowsItsOwnFeedbackOnceAndUnavailableIsNeverClear() {
        let scene = LaserScene()
        let layer = VerticalLaserLayer(scene: scene)
        var shown: [LaserFeedback.Outcome] = []
        layer.onOutcome = { _, outcome in shown.append(outcome) }
        var c = cue()
        for step in 0...40 { layer.update([c], at: 7 + Double(step) / 10) }
        #expect(shown.isEmpty, "no feedback while pending")
        c.outcome = .unavailable(at: 10.35)
        for step in 0...20 { layer.update([c], at: 10 + Double(step) / 10) }
        #expect(shown == [.unavailable])
        let hit = cue(.hit(at: 10.35))
        layer.update([hit], at: 10.4)
        layer.update([hit], at: 10.5)
        let withdrawn = cue(.withdrawn(at: 10.35))
        layer.update([withdrawn], at: 10.6)
        #expect(shown == [.unavailable, .hit], "the HIT once; a withdrawal shows nothing")
        // Before its crossing the beam is drawn at its contract position and width.
        let early = cue()
        layer.update([early], at: 9)
        #expect(layer.laser(for: early.id)?.root.position.x == mapping.worldX(corridorX: early.beamX))
        #expect(abs(Double(VerticalLaser.coreWidth / 2) - early.halfWidth) < 1e-6)
    }

    @Test func placingABoardPutsItExactlyThereAtRest() {
        var steering = LateralSteering(lanes: [.player1: -0.7, .player2: 0.7], bounds: -1.95...1.95, halfWidth: 0.58)
        steering.step(dt: 0.05, inputs: [.player1: .init(targetSpeed: 1, sway: 0.03)])
        steering.place(.player1, boardX: -1.3)
        #expect(abs((steering.boardX(.player1) ?? 0) - -1.3) < 1e-6)
        #expect(steering.riders[.player1]?.velocity == 0)
    }

    @Test func authoritativeBoardsAreDrawnWhereGameStatePutsThemNotWhereALeanWould() async throws {
        _ = await PlayerHoverboard.sharedTemplate()
        let input = try LaserReplayScript.load().input
        let scene = LaserScene()
        let robots = RobotAvatarLayer(scene: scene, calibrations: input.configuration.calibrations,
                                      layout: input.configuration.playerPlaneLayout,
                                      templates: try await RobotAvatarLayer.sharedTemplates())
        scene.robotAvatars = robots
        robots.smoothing = 0.03
        try #require(robots.steering != nil, "boards loaded: steering exists")
        RobotAvatarLayer.debugTestSteer = 0.8 // a held lean on Lemon, through the same step
        defer { RobotAvatarLayer.debugTestSteer = nil }
        for step in 0...60 {
            let x = -0.7 - 0.6 * Float(step) / 60
            robots.authoritativeBoardX = [.player1: x, .player2: 0.7]
            robots.render(now: Double(step) / 60)
            #expect(abs((robots.mascotWorldX(.player1) ?? .nan) - x) < 0.01, "step \(step)")
            #expect(abs((robots.mascotWorldX(.player2) ?? .nan) - 0.7) < 0.01)
        }
        // Without authoritative positions the presentation steering is back in charge.
        robots.authoritativeBoardX = [:]
        let parked = robots.mascotWorldX(.player1) ?? 0
        for step in 61...90 { robots.render(now: Double(step) / 60) }
        #expect((robots.mascotWorldX(.player1) ?? 0) > parked + 0.05, "the lean steers again")
    }

    @Test("The one-laser replay's scripted verdicts follow the proposed rule",
          arguments: VerticalLaserReplay.Mode.allCases)
    func theReplayVerdictsFollowTheProposedRule(mode: VerticalLaserReplay.Mode) async throws {
        let scene = LaserScene()
        let robots = RobotAvatarLayer(scene: scene, players: [.player1, .player2],
                                      templates: try await RobotAvatarLayer.sharedTemplates())
        let replay = VerticalLaserReplay(scene: scene, robots: robots, request: .init(mode: mode))
        // Aimed at the board when it is placed: standing still is never a CLEAR.
        let atPlacement = abs(replay.boardX(at: VerticalLaserReplay.placedAt) - replay.beamX)
        #expect(atPlacement < VerticalLaserReplay.boardHalfWidth)
        switch mode {
        case .clear: #expect(replay.expectedVerdict() == .clear(at: VerticalLaserReplay.verdictTime))
        case .hit: #expect(replay.expectedVerdict() == .hit(at: VerticalLaserReplay.verdictTime))
        case .unavailable:
            // The board did get clear, but without evidence the verdict is UNAVAILABLE, never CLEAR.
            let clearReplay = VerticalLaserReplay(scene: scene, robots: robots, request: .init(mode: .clear))
            #expect(replay.boardX(at: VerticalLaserReplay.crossingTime) == clearReplay.boardX(at: VerticalLaserReplay.crossingTime))
            #expect(replay.expectedVerdict() == .unavailable(at: VerticalLaserReplay.verdictTime))
        }
        // Co-op: Lemon's way out is toward its own wall, so Tangerine's lane is never crowded.
        let partner = GameWorldMapping().laneCorridorX(.player2)
        let separation = 2 * VerticalLaserReplay.boardHalfWidth + Double(LateralSteering.partnerGap)
        for step in 0...900 {
            #expect(partner - replay.boardX(at: Double(step) / 100) >= separation - 1e-9)
        }
    }
}
