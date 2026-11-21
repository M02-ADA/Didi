import Foundation
import Testing
@testable import Sedactive

/// Verdict (and so zap) timing, 16 November 2026: a verdict is decided as soon as the deadline's
/// verdict is already certain from the evidence received, never predicted. Frames at 30 Hz with an
/// 80 ms camera-to-game latency; each case is played with early verdicts and with the deadline only.
nonisolated struct ZapTimingTests {
    enum Posture: Equatable { case stand, duck, jump, dodge, unseen }

    struct Outcome: Equatable {
        var judgements: [PlayerID: Judgement] = [:]
        var verdictDelay: [PlayerID: Double] = [:]
        var judgedEvents = 0
    }

    static let latency = 0.08, frame = 1.0 / 30, crossing = 6.0

    /// Plays one encounter with each player's `move` and posture, frames from 0 to 7 s.
    func play(_ moves: [PlayerID: LaserMove], _ postures: [PlayerID: Posture], early: Bool, poseFirst: Bool = false,
              outOfOrderAt: Double? = nil) throws -> Outcome {
        let script = try LaserReplayScript.load()
        let input = script.input.configuration
        let context = BodyInputContext(sessionGeneration: input.sessionGeneration, cameraGeometryRevision: script.input.cameraGeometryRevision,
            calibrationRevisions: input.calibrations.mapValues(\.revision), cutovers: [:], isActive: true, wristContact: nil)
        let configuration = try LaserFullReplayPlan.roundConfiguration()
        var game = try LaserGame(configuration: configuration, context: context, historyCapacityPerPlayer: 400)
        game.decidesEarly = early
        game.poseFirstCandidate = poseFirst
        game.configureBoards(try LaserBoardField.make(calibrations: input.calibrations, layout: input.playerPlaneLayout))
        func height(_ p: PlayerID) -> Double { LaserLiveRoundGeometryV1.standingHeight(input.calibrations[p]!, layout: input.playerPlaneLayout) }
        let id = UUID(uuidString: "2A900000-0000-4000-8000-000000000001")!
        let targets = try PlayerID.allCases.map { p -> LaserTarget in
            let h = height(p), move = moves[p]!
            let band = try move == .duck ? LaserBeamBand(lowerY: h * 0.93, upperY: h * 0.94)
                : move == .jump ? LaserBeamBand(lowerY: h * 0.005, upperY: h * 0.015) : LaserBeamBand(lowerY: 0, upperY: h)
            return try LaserTarget(playerID: p, calibrationRevision: input.calibrations[p]!.revision, requiredMove: move, beam: band,
                warningTime: Self.crossing - 3, crossingTime: Self.crossing,
                lean: move == .lean ? LaserLeanBeam(intent: .outward) : nil)
        }
        var encounter = try LaserEncounter(id: id, attemptID: id, targets: targets)
        var registered = false
        var frameID: UInt64 = 0
        var outcome = Outcome()
        var captures = stride(from: 0.0, through: 7.0, by: Self.frame).map { $0 }
        if let swap = outOfOrderAt, let i = captures.firstIndex(where: { $0 >= swap }), i + 1 < captures.count {
            captures.swapAt(i, i + 1)
        }
        var lastArrival = 0.0
        for t in captures {
            if !registered, t >= Self.crossing - 4 {
                try game.advance(to: max(game.gameTime, t))
                encounter = try game.register(encounter)
                registered = true
            }
            frameID += 1
            var players: [PlayerID: PlayerBodySample] = [:]
            for p in PlayerID.allCases {
                let h = height(p), posture = postures[p]!
                func v(_ x: Double) throws -> EstimatedScalar { try EstimatedScalar(value: x, validity: .valid) }
                let target = encounter.targets.first { $0.playerID == p }!
                let near = abs(t - Self.crossing) <= 0.2
                // Unseen through the whole evidence window (−0.35 … +0.25 s around the crossing).
                if posture == .unseen && abs(t - Self.crossing) <= 0.4 {
                    let lost = try EstimatedScalar(value: nil, validity: .identityUncertain)
                    players[p] = PlayerBodySample(playerID: p, calibrationRevision: input.calibrations[p]!.revision, trackingStatus: .lost,
                        geometry: BodyGeometry(crownY: lost, leftWristY: lost, rightWristY: lost, leftSoleY: lost, rightSoleY: lost,
                                               centerX: lost, trunkLeanX: lost),
                        jumpState: JumpState(phase: .unknown, validity: .identityUncertain))
                    continue
                }
                let ducking = posture == .duck && near
                let airborne = posture == .jump && abs(t - Self.crossing) <= 0.15
                let crown = ducking ? target.beam.lowerY - 0.02 : h
                let sole = airborne ? target.beam.upperY + 0.02 : 0
                var lean = 0.0
                if posture == .dodge, let beam = target.lean, let e = beam.escape, let center = beam.centerX,
                   let x = game.boardReadings[p]?.x, t >= 3.4,
                   abs(x - center) < LaserLeanPlacement.clearance(halfWidth: beam.halfWidth, margin: configuration.clearanceMargin) + 0.1 {
                    lean = -Double(e) * 0.08 * h
                }
                players[p] = try PlayerBodySample(playerID: p, calibrationRevision: input.calibrations[p]!.revision, trackingStatus: .reliable,
                    geometry: BodyGeometry(crownY: v(crown + sole), leftWristY: v(min(crown, 0.6 * h) + sole), rightWristY: v(min(crown, 0.6 * h) + sole),
                        leftSoleY: v(sole), rightSoleY: v(sole), centerX: v(input.playerPlaneLayout.centerX(for: p)), trunkLeanX: v(lean)),
                    jumpState: JumpState(phase: airborne ? .airborne : .grounded, validity: .valid))
            }
            let snapshot = BodySnapshot(sessionGeneration: input.sessionGeneration, frameID: frameID, capturedAt: t,
                                        cameraGeometryRevision: script.input.cameraGeometryRevision, players: players)
            let arrival = max(lastArrival, t + Self.latency)
            lastArrival = arrival
            try game.receive(snapshot, capturedGameTime: t, arrivedAt: arrival)
            for event in game.drainEvents() {
                if case .targetJudged(_, let player, let judgement) = event.kind {
                    outcome.judgedEvents += 1
                    outcome.judgements[player] = judgement
                    outcome.verdictDelay[player] = event.gameTime - Self.crossing
                }
            }
        }
        try game.advance(to: 8)
        for event in game.drainEvents() {
            if case .targetJudged(_, let player, let judgement) = event.kind {
                outcome.judgedEvents += 1
                outcome.judgements[player] = judgement
                outcome.verdictDelay[player] = event.gameTime - Self.crossing
            }
        }
        return outcome
    }

    struct Case: CustomStringConvertible, Sendable {
        let name: String
        let moves: [PlayerID: LaserMove]
        let postures: [PlayerID: Posture]
        var poseFirst = false
        var description: String { name }
    }

    static let cases: [Case] = [
        Case(name: "DUCK hit", moves: [.player1: .duck, .player2: .duck], postures: [.player1: .stand, .player2: .stand]),
        Case(name: "DUCK clear", moves: [.player1: .duck, .player2: .duck], postures: [.player1: .duck, .player2: .duck]),
        Case(name: "JUMP hit", moves: [.player1: .jump, .player2: .jump], postures: [.player1: .stand, .player2: .stand]),
        Case(name: "JUMP clear", moves: [.player1: .jump, .player2: .jump], postures: [.player1: .jump, .player2: .jump]),
        Case(name: "JUMP hit (timed event)", moves: [.player1: .jump, .player2: .jump],
             postures: [.player1: .stand, .player2: .stand], poseFirst: true),
        Case(name: "JUMP clear (timed event)", moves: [.player1: .jump, .player2: .jump],
             postures: [.player1: .jump, .player2: .jump], poseFirst: true),
        Case(name: "LEAN hit", moves: [.player1: .lean, .player2: .lean], postures: [.player1: .stand, .player2: .stand]),
        Case(name: "LEAN clear", moves: [.player1: .lean, .player2: .lean], postures: [.player1: .dodge, .player2: .dodge]),
        // Independent outcomes in one encounter (one move per encounter: DUCK/JUMP splits cannot exist).
        Case(name: "LEAN hit / LEAN clear", moves: [.player1: .lean, .player2: .lean], postures: [.player1: .stand, .player2: .dodge]),
        Case(name: "DUCK clear / DUCK hit", moves: [.player1: .duck, .player2: .duck], postures: [.player1: .duck, .player2: .stand]),
    ]

    @Test("A verdict comes as soon as it is certain, and it is the deadline's verdict", arguments: cases)
    func verdictsComeEarlyAndUnchanged(_ c: Case) throws {
        let before = try play(c.moves, c.postures, early: false, poseFirst: c.poseFirst)
        let after = try play(c.moves, c.postures, early: true, poseFirst: c.poseFirst)
        // The same authoritative verdicts, one event per target: only the moment changes.
        #expect(after.judgements == before.judgements)
        #expect(after.judgedEvents == 2 && before.judgedEvents == 2)
        for player in PlayerID.allCases {
            let b = try #require(before.verdictDelay[player]), a = try #require(after.verdictDelay[player])
            print(String(format: "[ZapTiming] %@ %@: %@ · verdict +%.3f s → +%.3f s", c.name, player.rawValue,
                         "\(after.judgements[player]!)", b, a))
            #expect(abs(b - 0.35) < 1e-9, "before: the deadline")
            // After: the first frame at or after the crossing (plus latency), or for a timed jump
            // CLEAR/HIT, once its flight or the tolerance is past (still before the deadline).
            #expect(a < b - 0.1, "after \(a)")
            #expect(a >= 0, "never before the laser crosses")
        }
    }

    @Test func unavailableAndOutOfOrderStillWaitForTheDeadline() throws {
        // P2 unseen at the crossing: nothing is decided early (its encounter commits at the deadline).
        let unseen = try play([.player1: .duck, .player2: .duck], [.player1: .stand, .player2: .unseen], early: true)
        #expect(unseen.verdictDelay[.player1].map { abs($0 - 0.35) < 1e-9 } == true)
        if case .unavailable = unseen.judgements[.player2] {} else { Issue.record("P2 \(String(describing: unseen.judgements[.player2]))") }
        // A capture that arrived out of order: that player's verdicts wait for the deadline all round.
        let swapped = try play([.player1: .duck, .player2: .duck], [.player1: .stand, .player2: .stand], early: true, outOfOrderAt: 2)
        #expect(swapped.verdictDelay.values.allSatisfy { abs($0 - 0.35) < 1e-9 })
        #expect(swapped.judgements[.player1] == .hit(.insufficientClearance))
    }
}
