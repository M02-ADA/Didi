import Foundation
import Testing
@testable import Sedactive

@MainActor struct FTUELaserPracticeTests {
    static func make(coop: Bool = true, poseFirst: Bool = true, generation: UUID = UUID()) throws -> FTUELaserPractice {
        let script = try LaserReplayScript.load().freshRound(generation: generation)
        var input = script.input.configuration
        if !coop { input = input.replacingCalibrations(input.calibrations.filter { $0.key == .player1 }); input.soloPlayer = .player1 }
        let context = BodyInputContext(sessionGeneration: input.sessionGeneration, cameraGeometryRevision: 1,
            calibrationRevisions: input.calibrations.mapValues(\.revision), cutovers: [:], isActive: true)
        return try .init(input: input, configuration: try LaserFullReplayPlan.roundConfiguration(), context: context, poseFirst: poseFirst)
    }
    static func packet(_ practice: FTUELaserPractice, at time: Double, frame: UInt64,
                       clear: Set<PlayerID>, unavailable: Set<PlayerID> = []) throws -> BodySnapshot {
        func value(_ v: Double, _ valid: Bool) throws -> EstimatedScalar { try .init(value: valid ? v : nil, validity: valid ? .valid : .missingLandmarks) }
        var players: [PlayerID: PlayerBodySample] = [:]
        for target in practice.encounter.targets {
            let p = target.playerID, yes = clear.contains(p), valid = !unavailable.contains(p)
            let h = LaserLiveRoundGeometryV1.standingHeight(practice.input.calibrations[p]!, layout: practice.input.playerPlaneLayout)
            let crown = practice.move == .duck && yes ? target.beam.lowerY - practice.configuration.clearanceMargin - 0.05 : h
            let foot = practice.move == .jump && yes ? target.beam.upperY + practice.configuration.clearanceMargin + 0.05 : 0
            players[p] = .init(playerID: p, calibrationRevision: target.calibrationRevision, trackingStatus: .reliable,
                geometry: .init(crownY: try value(crown, valid), leftWristY: try value(crown * 0.5, valid),
                    rightWristY: try value(crown * 0.5, valid), leftSoleY: try value(foot, valid),
                    rightSoleY: try value(foot, valid), centerX: try value(practice.input.playerPlaneLayout.centerX(for: p), valid)),
                jumpState: .init(phase: practice.move == .jump && yes ? .airborne : .grounded, validity: .valid))
        }
        for p in PlayerID.allCases where players[p] == nil {
            let missing = try value(0, false)
            players[p] = .init(playerID: p, calibrationRevision: nil, trackingStatus: .lost,
                geometry: .init(crownY: missing, leftWristY: missing, rightWristY: missing,
                    leftSoleY: missing, rightSoleY: missing, centerX: missing),
                jumpState: .init(phase: .unknown, validity: .missingLandmarks))
        }
        return .init(sessionGeneration: practice.generation, frameID: frame, capturedAt: time,
            cameraGeometryRevision: 1, players: players)
    }
    static func run(_ practice: inout FTUELaserPractice, clear: Set<PlayerID>, unavailable: Set<PlayerID> = [], start: Double = 1000) throws {
        try practice.update(at: start, eligible: true, context: practice.context)
        for i in 1...90 {
            let time = start + Double(i) * 0.05
            let p = try packet(practice, at: time - 0.01, frame: UInt64(start * 100) + UInt64(i), clear: clear, unavailable: unavailable)
            try practice.receive(p, at: time, maximumAge: 0.25)
            try practice.update(at: time, eligible: true, context: practice.context)
            if practice.outcome != .pending { break }
        }
    }
    @Test(arguments: [false, true], [false, true])
    func committedClearAdvancesOnlyAfterFeedback(coop: Bool, poseFirst: Bool) throws {
        var p = try Self.make(coop: coop, poseFirst: poseFirst)
        let id = p.attemptID
        try Self.run(&p, clear: Set(p.roster))
        #expect(p.outcome == .clear && p.move == .jump && !p.completed)
        try p.feedbackFinished(attempt: UUID(), generation: p.generation)
        #expect(p.attemptID == id)
        try p.feedbackFinished(attempt: id, generation: p.generation)
        #expect(p.move == .duck && p.attemptID != id && p.verdicts.isEmpty)
        try p.feedbackFinished(attempt: id, generation: p.generation)
        #expect(p.move == .duck && p.outcome == .pending)
        try Self.run(&p, clear: Set(p.roster), start: 1100)
        try p.feedbackFinished(attempt: p.attemptID, generation: p.generation)
        #expect(p.completed && p.state.teamScore == 0)
    }
    @Test(arguments: [Set<PlayerID>(), [.player1], [.player2]])
    func mixedFailureRetriesWholeRosterWithoutHealthEffects(clear: Set<PlayerID>) throws {
        var p = try Self.make()
        for i in 0...2 {
            let id = p.attemptID
            try Self.run(&p, clear: clear, start: 1000 + Double(i) * 10)
            #expect(p.outcome == .hit && p.state.teamHealth == 5 && p.state.teamScore == 0)
            try p.feedbackFinished(attempt: id, generation: p.generation)
            #expect(p.move == .jump && p.attemptID != id && p.verdicts.isEmpty)
        }
    }
    @Test func duckFailureStaysDuckAndPauseCannotScheduleRetry() throws {
        var p = try Self.make()
        try Self.run(&p, clear: Set(p.roster))
        try p.feedbackFinished(attempt: p.attemptID, generation: p.generation)
        #expect(p.move == .duck)
        try Self.run(&p, clear: [.player1], start: 1100)
        let id = p.attemptID
        #expect(p.outcome == .hit)
        try p.update(at: 1104, eligible: false, context: p.context)
        try p.feedbackFinished(attempt: id, generation: p.generation)
        #expect(p.attemptID == id && p.move == .duck)
        try p.update(at: 1200, eligible: true, context: p.context)
        try p.feedbackFinished(attempt: id, generation: p.generation)
        #expect(p.move == .duck && p.attemptID != id && p.verdicts.isEmpty)
    }
    @Test(arguments: [PlayerID.player1, .player2])
    func coopDuckRequiresBothPlayersAndRecoversOnFreshAttempt(missing: PlayerID) throws {
        var practice = try Self.make()
        let roster = Set(practice.roster)
        try Self.run(&practice, clear: roster)
        try practice.feedbackFinished(attempt: practice.attemptID, generation: practice.generation)
        try Self.run(&practice, clear: roster, unavailable: [missing], start: 1100)
        let refused = practice.attemptID
        #expect(practice.outcome == .unavailable)
        #expect(practice.verdicts[roster.subtracting([missing]).first!] == .clear)
        #expect(practice.verdicts[missing] == .unavailable(.invalidEvidence(.crown, .missingLandmarks)))
        try practice.feedbackFinished(attempt: refused, generation: practice.generation)
        #expect(!practice.completed)

        try Self.run(&practice, clear: roster, start: 1200)
        let accepted = practice.attemptID
        #expect(accepted != refused)
        #expect(practice.outcome == .clear)
        try practice.feedbackFinished(attempt: refused, generation: practice.generation)
        #expect(!practice.completed)
        try practice.feedbackFinished(attempt: accepted, generation: UUID())
        #expect(!practice.completed)
        try practice.feedbackFinished(attempt: accepted, generation: practice.generation)
        #expect(practice.completed)
        try practice.feedbackFinished(attempt: accepted, generation: practice.generation)
        #expect(practice.attemptID == accepted)
    }

    @Test func fastCaptureCadenceDoesNotOverflowWarningHistory() throws {
        var p = try Self.make()
        try p.update(at: 1000, eligible: true, context: p.context)
        for i in 1...240 {
            let now = 1000 + Double(i) / 60
            try p.receive(Self.packet(p, at: now - 0.001, frame: UInt64(i + 10000), clear: Set(p.roster)), at: now, maximumAge: 0.25)
            try p.update(at: now, eligible: true, context: p.context)
            if p.outcome != .pending { break }
        }
        #expect(p.outcome == .clear)
    }

    @Test func unavailablePauseAndOldEvidenceNeverComplete() throws {
        var p = try Self.make()
        try Self.run(&p, clear: [], unavailable: Set(p.roster))
        #expect(p.outcome == .unavailable)
        let id = p.attemptID
        try p.update(at: 1100, eligible: false, context: p.context)
        #expect(p.attemptID == id)
        try p.update(at: 1101, eligible: true, context: p.context)
        #expect(p.attemptID != id && p.elapsed == 0)
        let fresh = p.attemptID
        try p.receive(Self.packet(p, at: 1001, frame: 999999, clear: Set(p.roster)), at: 1101, maximumAge: 0.25)
        try p.update(at: 1101.1, eligible: false, context: p.context)
        try p.update(at: 1200, eligible: true, context: p.context)
        #expect(p.attemptID != fresh && p.elapsed == 0 && p.verdicts.isEmpty)
    }
}
