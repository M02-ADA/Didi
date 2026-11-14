import Foundation
import Testing
@testable import Sedactive

/// Live vault zones judged where the mascot's hand reaches (owner Option A, 12 November 2026): the
/// consumer adds each player's shift (body centre + the mascot's distance from its console dock) to
/// the approved zone, and still needs a genuine outside→inside wrist entry. SYNTHETIC wrist points.
nonisolated struct VaultZoneShiftTests {
    private static func open() throws -> (WristGameplayFixture, LaserGame, LaserWristDiamondConsumer, [LaserVaultZone]) {
        let f = try WristGameplayFixture()
        var g = try f.game()
        let vault = UUID()
        try g.openVault(id: vault, at: 0)
        let zones = try LaserVaultButton.allCases.enumerated().map { i, b in
            LaserVaultZone(targetID: UUID(), playerID: .player1, button: b,
                           position: try LaserDiamondPosition(x: 1, y: 0.5 + Double(i) * 0.4), radius: 0.15)
        }
        var c = try LaserWristDiamondConsumer(configuration: f.plan(), context: f.context, lifetime: UUID(), afterCapturedAt: 100)
        try c.openVault(id: vault, zones: zones, game: g, atHostTime: 100)
        return (f, g, c, zones)
    }

    private static func send(_ f: WristGameplayFixture, _ c: inout LaserWristDiamondConsumer, _ g: inout LaserGame,
                             frame: UInt64, point: WristPlanePoint, shifts: [PlayerID: Double]) throws {
        let s = try f.packet(frame, 100 + Double(frame) * 0.05, points: [WristGameplayFixture.left: point])
        try c.receive(s, context: f.context, atHostTime: 100 + Double(frame) * 0.05, capturedGameTime: Double(frame) * 0.05,
                      arrivedGameTime: Double(frame) * 0.05, game: &g, vaultZoneShifts: shifts)
    }

    @Test func docked_theApprovedZonePresses() throws {
        var (f, g, c, zones) = try Self.open()
        let top = zones[0]
        try Self.send(f, &c, &g, frame: 3, point: WristGameplayFixture.outside, shifts: [.player1: 0])
        try Self.send(f, &c, &g, frame: 4, point: .init(x: top.position.x, y: top.position.y), shifts: [.player1: 0])
        #expect(g.vault?.buttons[.player1] == [top.button])
    }

    @Test func awayFromTheDock_theZoneMovesOutAndOnlyTheFurtherReachPresses() throws {
        var (f, g, c, zones) = try Self.open()
        let top = zones[0]
        // The mascot is 1.0 plane units short of its dock: the approved zone is in mid-air.
        try Self.send(f, &c, &g, frame: 3, point: WristGameplayFixture.outside, shifts: [.player1: 1])
        try Self.send(f, &c, &g, frame: 4, point: .init(x: top.position.x, y: top.position.y), shifts: [.player1: 1])
        #expect(g.vault?.buttons[.player1]?.isEmpty != false, "no press at the unshifted zone")
        try Self.send(f, &c, &g, frame: 5, point: WristGameplayFixture.outside, shifts: [.player1: 1])
        try Self.send(f, &c, &g, frame: 6, point: .init(x: top.position.x + 1, y: top.position.y), shifts: [.player1: 1])
        #expect(g.vault?.buttons[.player1] == [top.button], "the shifted zone presses")
    }

    /// The DEBUG readout carries the judge's own reasons: unavailable (unplaceable), outside with its
    /// distance, inside, and the press.
    @Test func theReadoutReportsTheJudgesOwnReasons() throws {
        var (f, g, c, zones) = try Self.open()
        let top = zones[0]
        try Self.send(f, &c, &g, frame: 3, point: WristGameplayFixture.outside, shifts: [.player1: .infinity])
        #expect(c.lastVaultReadout.contains { $0.status.hasPrefix("UNAVAILABLE: zone unplaceable") })
        try Self.send(f, &c, &g, frame: 4, point: WristGameplayFixture.outside, shifts: [.player1: 0])
        let out = try #require(c.lastVaultReadout.first { $0.button == top.button && $0.wrist == .left })
        #expect(out.status == "outside" && (out.distance ?? 0) > top.radius && !out.pressed)
        #expect(c.lastVaultReadout.contains { $0.wrist == .right && $0.status.hasPrefix("UNAVAILABLE") }, "the other wrist had no evidence")
        try Self.send(f, &c, &g, frame: 5, point: .init(x: top.position.x, y: top.position.y), shifts: [.player1: 0])
        let press = try #require(c.lastVaultReadout.first { $0.button == top.button && $0.wrist == .left })
        #expect(press.status == "inside" && press.pressed && press.distance == 0)
    }

    @Test func anUnplaceableZoneIsUnavailableNeverAPress() throws {
        var (f, g, c, zones) = try Self.open()
        let top = zones[0]
        try Self.send(f, &c, &g, frame: 3, point: WristGameplayFixture.outside, shifts: [.player1: .infinity])
        try Self.send(f, &c, &g, frame: 4, point: .init(x: top.position.x, y: top.position.y), shifts: [.player1: .infinity])
        #expect(g.vault?.buttons[.player1]?.isEmpty != false)
    }

    @Test func aHeldWristPressesOnceTheMascotArrivesAtTheButton() throws {
        // The wrist waits in the approved place while the mascot is away (outside its shifted zone),
        // then the mascot docks (shift 0): the wrist is inside without a fresh outside→inside entry
        // only if it was outside first, which it was: one press, from a real entry.
        var (f, g, c, zones) = try Self.open()
        let top = zones[0], held = WristPlanePoint(x: top.position.x, y: top.position.y)
        try Self.send(f, &c, &g, frame: 3, point: held, shifts: [.player1: 1])
        try Self.send(f, &c, &g, frame: 4, point: held, shifts: [.player1: 0.5])
        #expect(g.vault?.buttons[.player1]?.isEmpty != false)
        try Self.send(f, &c, &g, frame: 5, point: held, shifts: [.player1: 0])
        #expect(g.vault?.buttons[.player1] == [top.button], "outside (mascot away) → inside (mascot docked) is an entry")
    }
}

/// The coordinator's shift for one capture: the player's own body centre (from that capture) plus
/// the mascot's distance from its dock (from the renderer); none without mascots.
@MainActor struct CoordinatorVaultZoneShiftTests {
    @Test func theShiftIsTheBodyCentrePlusTheMascotsDistanceFromItsDock() throws {
        let rig = try J07SessionRig()
        let session = rig.session
        let layout = session.inputConfiguration.playerPlaneLayout
        func samples(_ offset: Double?) throws -> [PlayerID: PlayerBodySample] {
            try rig.fixture.players.mapValues { s in
                let center = try offset.map { try EstimatedScalar(value: layout.centerX(for: s.playerID) + $0, validity: .valid) }
                    ?? EstimatedScalar(value: nil, validity: .notCalibrated)
                let g = s.geometry
                return PlayerBodySample(playerID: s.playerID, calibrationRevision: s.calibrationRevision, trackingStatus: s.trackingStatus,
                    geometry: .init(crownY: g.crownY, leftWristY: g.leftWristY, rightWristY: g.rightWristY,
                                    leftSoleY: g.leftSoleY, rightSoleY: g.rightSoleY, centerX: center), jumpState: s.jumpState)
            }
        }
        let snapshot = try rig.fixture.packet(5, 0.5, points: [:], bodySamples: samples(0.1))
        #expect(session.vaultZoneShifts(for: snapshot).isEmpty, "no mascots: the approved zones")
        session.vaultMascotReach = { player, _ in player == .player1 ? 0.3 : -0.2 }
        let shifts = session.vaultZoneShifts(for: snapshot)
        #expect(abs((shifts[.player1] ?? 0) - 0.4) < 1e-9 && abs((shifts[.player2] ?? 0) - (-0.1)) < 1e-9)
        let unknown = try rig.fixture.packet(6, 0.625, points: [:], bodySamples: samples(nil))
        #expect(session.vaultZoneShifts(for: unknown).values.allSatisfy { !$0.isFinite }, "no body centre: unplaceable")
        session.vaultMascotReach = { _, _ in nil }
        #expect(session.vaultZoneShifts(for: snapshot).values.allSatisfy { !$0.isFinite }, "no mascot position: unplaceable")
    }
}
