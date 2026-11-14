import Foundation
import Testing
@testable import Sedactive

/// WRISTS ARE ACTION EVIDENCE (PROPOSED by Kevin, 13 November 2026 — needs Jevon's review): wrists are action evidence, not presence. A
/// running round is not blocked by a hidden wrist (the DUCK judge, wall consoles and diamonds
/// check their own wrists); a hidden head, sole or jump state still blocks as before.
@MainActor struct ReadinessWristIndependenceTests {
    private let generation = UUID()
    private var context: BodyInputContext {
        BodyInputContext(sessionGeneration: generation, cameraGeometryRevision: 1,
                         calibrationRevisions: [.player1: 1, .player2: 1], cutovers: [:], isActive: true)
    }
    private func packet(_ frame: UInt64, _ time: Double, hide: KeyPath<BodyGeometry, EstimatedScalar>? = nil) throws -> BodySnapshot {
        let base = try LH00TestData.load().records.first!.snapshot!
        let gone = try EstimatedScalar(value: nil, validity: .lowConfidence)
        let players = base.players.mapValues { s -> PlayerBodySample in
            var g = s.geometry
            if s.playerID == .player1, let hide {
                let pick = { (k: KeyPath<BodyGeometry, EstimatedScalar>) in k == hide ? gone : g[keyPath: k] }
                g = .init(crownY: pick(\.crownY), leftWristY: pick(\.leftWristY), rightWristY: pick(\.rightWristY),
                          leftSoleY: pick(\.leftSoleY), rightSoleY: pick(\.rightSoleY), centerX: g.centerX)
            }
            return PlayerBodySample(playerID: s.playerID, calibrationRevision: 1, trackingStatus: .reliable, geometry: g, jumpState: s.jumpState)
        }
        return BodySnapshot(sessionGeneration: generation, frameID: frame, capturedAt: time, cameraGeometryRevision: 1, players: players)
    }
    private func running() throws -> (LaserLiveReadiness, Double, UInt64) {
        var value = LaserLiveReadiness(policy: LaserLiveWristRoundPlan.liveTiming)
        var t = 1000.0, frame: UInt64 = 1
        while value.phase != .ready, t < 1003 { try value.observe(packet(frame, t), context: context, bindingConfirmed: true, at: t); t += 0.125; frame += 1 }
        try value.beginCountdown(at: t)
        while value.phase != .running, t < 1008 { try value.observe(packet(frame, t), context: context, bindingConfirmed: true, at: t); t += 0.125; frame += 1 }
        #expect(value.phase == .running)
        return (value, t, frame)
    }

    @Test func aHiddenWristDoesNotBlockARunningRound() throws {
        for wrist in [\BodyGeometry.leftWristY, \.rightWristY] {
            var (value, t, frame) = try running()
            try value.observe(packet(frame, t, hide: wrist), context: context, bindingConfirmed: true, at: t)
            #expect(value.phase == .running && value.blocker == nil)
        }
    }

    @Test func aHiddenHeadOrSoleStillBlocks() throws {
        for required in [\BodyGeometry.crownY, \.leftSoleY, \.rightSoleY] {
            var (value, t, frame) = try running()
            try value.observe(packet(frame, t, hide: required), context: context, bindingConfirmed: true, at: t)
            #expect(value.blocker == .measurements, "\(required)")
        }
    }
}
