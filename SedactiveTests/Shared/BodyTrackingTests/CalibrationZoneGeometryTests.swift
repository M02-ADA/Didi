import CoreGraphics
import Foundation
import Testing
@testable import Sedactive

/// The tracker's acquisition zones (`PlayerAcquisitionZones`) agree with the boxes the players see
/// (`CalibrationStageLayout`) for every delivered frame shape: the built-in camera's 1280 × 720 and
/// staging's external cameras (20 November 2026), e.g. 960 × 720 (4:3), 1440 × 960 (3:2) and
/// 1280 × 800 (16:10). The preview is mirrored once for display; the zones are in the unmirrored source.
nonisolated struct CalibrationZoneGeometryTests {
    typealias F = TrackingFixtures
    typealias Zones = PlayerAcquisitionZones

    static let frames: [(width: Int, height: Int)] = [(1280, 720), (960, 720), (1440, 960), (1280, 800)]
    static let cases: [(PlayerID, Bool)] = [(.player1, false), (.player2, false), (.player1, true)]

    /// The built-in camera keeps the zones it had (the previous constants, to their 3 decimals).
    @Test func theBuiltInCameraKeepsItsZones() {
        let previous: [(PlayerID, Bool, ClosedRange<Double>)] = [
            (.player1, false, 0.521...0.808), (.player2, false, 0.173...0.461), (.player1, true, 0.358...0.642)]
        for (player, solo, box) in previous {
            let now = Zones.box(player, solo: solo, imageAspect: 1280.0 / 720.0)
            #expect(abs(now.lowerBound - box.lowerBound) < 0.001 && abs(now.upperBound - box.upperBound) < 0.001,
                    "\(player) solo \(solo): \(now) vs \(box)")
        }
        #expect(Zones.zone(.player1, solo: false) == Zones.zone(.player1, solo: false, imageAspect: 16.0 / 9.0),
                "the default is the built-in camera")
    }

    /// Every drawn box, on every supported screen and frame shape, lies inside its zone, and the zone
    /// reaches at most `margin` beyond the union of those boxes.
    @Test(arguments: frames.map { "\($0.width)x\($0.height)" })
    func theZonesContainTheDrawnBoxes(frame: String) {
        let parts = frame.split(separator: "x").compactMap { Double($0) }
        let aspect = parts[0] / parts[1]
        for screen in Zones.screens {
            let fill = CalibrationStageLayout.canFill(in: screen, aspect: aspect)
            for (player, solo) in Self.cases {
                let drawn = CalibrationStageLayout.boxRect(player, solo: solo, in: screen)
                let source = CalibrationStageLayout.sourceRect(for: drawn, in: screen, aspect: aspect, fill: fill)
                let zone = Zones.zone(player, solo: solo, imageAspect: aspect)
                #expect(zone.contains(Double(source.minX)) && zone.contains(Double(source.maxX)),
                        "\(frame) \(screen) \(player) solo \(solo): box \(source.minX)…\(source.maxX) in \(zone)")
            }
        }
        for (player, solo) in Self.cases {
            let box = Zones.box(player, solo: solo, imageAspect: aspect), zone = Zones.zone(player, solo: solo, imageAspect: aspect)
            #expect(abs(box.lowerBound - zone.lowerBound - Zones.margin) < 1e-12 && abs(zone.upperBound - box.upperBound - Zones.margin) < 1e-12)
        }
    }

    /// Display → tracker: a torso drawn at the centre of a box, or just inside its outer edge, is
    /// that box's player; just outside the zone, nobody's. P1's box is on the LEFT of the mirrored
    /// screen and the RIGHT of the source (x > 0.5).
    @Test(arguments: frames.map { "\($0.width)x\($0.height)" })
    func aTorsoDrawnInABoxBelongsToThatBoxsPlayer(frame: String) {
        let parts = frame.split(separator: "x").compactMap { Double($0) }
        let aspect = parts[0] / parts[1]
        for screen in Zones.screens {
            let fill = CalibrationStageLayout.canFill(in: screen, aspect: aspect)
            let content = CalibrationStageLayout.contentRect(in: screen, aspect: aspect, fill: fill)
            func sourceX(screenX: CGFloat) -> Double { Double(1 - (screenX - content.minX) / content.width) }
            for (player, solo) in Self.cases {
                let drawn = CalibrationStageLayout.boxRect(player, solo: solo, in: screen)
                if !solo { #expect((drawn.midX < screen.width / 2) == (player == .player1), "P1's box is on the screen's left") }
                for screenX in [drawn.midX, drawn.minX + 2, drawn.maxX - 2] {
                    let x = sourceX(screenX: screenX)
                    #expect(Zones.player(atX: x, solo: solo, imageAspect: aspect) == player,
                            "\(frame) \(screen) \(player) solo \(solo): screen x \(screenX) → source \(x)")
                }
            }
        }
        for (player, solo) in Self.cases {
            let zone = Zones.zone(player, solo: solo, imageAspect: aspect)
            #expect(Zones.player(atX: zone.lowerBound - 0.005, solo: solo, imageAspect: aspect) != player)
            #expect(Zones.player(atX: zone.upperBound + 0.005, solo: solo, imageAspect: aspect) != player)
            #expect(Zones.player(atX: zone.upperBound - 0.005, solo: solo, imageAspect: aspect) == player
                    || (!solo && player == .player2 && zone.upperBound - 0.005 > 0.5), "inside the outer edge")
        }
    }

    /// The left/right split stays at the image centre for every frame shape: P1's zone never
    /// links anyone on the source's left half, P2's never on its right half.
    @Test(arguments: frames.map { "\($0.width)x\($0.height)" })
    func theZonesNeverCrossTheCentre(frame: String) {
        let parts = frame.split(separator: "x").compactMap { Double($0) }
        let aspect = parts[0] / parts[1]
        for x in stride(from: 0.40, through: 0.60, by: 0.01) {
            let player = Zones.player(atX: x, solo: false, imageAspect: aspect)
            if x < 0.5 { #expect(player != .player1) } else if x > 0.5 { #expect(player != .player2) }
        }
    }

    /// The tracker uses its frame's own shape. On a 960 × 720 external camera P1's drawn box reaches
    /// x 0.91 of the source, beyond the built-in camera's zone (0.848): a player standing at its
    /// outer edge now links, and two people in one box still refuse (no guessing).
    @Test func anExternalCameraPlayerAtTheOuterEdgeOfTheirBoxLinks() throws {
        let context = F.context(width: 960, height: 720)
        let aspect = 960.0 / 720.0
        let edge = 0.89
        #expect(Zones.player(atX: edge, solo: false, imageAspect: aspect) == .player1)
        #expect(Zones.player(atX: edge, solo: false) == nil, "the built-in camera's zone would have ignored them")
        var t = try F.tracker(context: context)
        var r = t.snapshot
        for i in 1...3 {
            r = try t.process(F.input(UInt64(i), Double(i) * 0.125, [F.candidate(10, x: edge), F.candidate(20, x: 0.12)], context: context))
        }
        #expect(r.player1.candidateID == 10 && r.player2.candidateID == 20, "both link at the outer edges of their boxes")
        // A second person in P1's box on the same camera: nobody links.
        var crowded = try F.tracker(context: context)
        for i in 1...3 {
            r = try crowded.process(F.input(UInt64(i), Double(i) * 0.125,
                [F.candidate(10, x: 0.65), F.candidate(20, x: 0.25), F.candidate(30, x: 0.88)], context: context))
        }
        #expect(r.player1.state == .unbound && r.player2.state == .unbound)
    }

    /// Solo on an external camera: the centred box is wider in the source, and its zone follows.
    @Test func anExternalCameraSoloZoneFollowsTheDrawnBox() throws {
        let context = F.context(width: 960, height: 720)
        var t = try PlayerTracker(policy: F.policy())
        try t.reset(context: context, controlRevision: 1)
        try t.armBinding(controlRevision: 1, solo: true)
        let x = 0.30 // inside the 4:3 Solo box (0.31… on the 11-inch screen, within the margin), outside the 16:9 zone
        #expect(Zones.player(atX: x, solo: true, imageAspect: 960.0 / 720.0) == .player1)
        #expect(Zones.player(atX: x, solo: true) == nil)
        var r = t.snapshot
        for i in 1...3 { r = try t.process(F.input(UInt64(i), Double(i) * 0.125, [F.candidate(10, x: x)], context: context)) }
        #expect(r.player1.state == .tracking && r.player1.candidateID == 10)
    }

    /// A frame shape that cannot be used (zero or invalid) falls back to the built-in camera's zones.
    @Test func anInvalidFrameShapeFallsBackToTheBuiltInZones() {
        for aspect in [0.0, -1, .nan, .infinity] {
            #expect(Zones.zone(.player1, solo: false, imageAspect: aspect) == Zones.zone(.player1, solo: false))
        }
    }
}
