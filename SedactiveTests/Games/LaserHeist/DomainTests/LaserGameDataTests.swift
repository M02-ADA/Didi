import Foundation
import Testing
@testable import Sedactive

nonisolated struct LaserGameDataTests {
    @Test func rejectsInvalidGeometryAndTiming() throws {
        for edges in [(Double.nan, 1.0), (1.0, 1.0), (2.0, 1.0), (-1.0, 1.0)] {
            #expect(throws: LaserDataError.self) { try LaserBeamBand(lowerY: edges.0, upperY: edges.1) }
        }
        #expect(throws: LaserDataError.self) {
            try LaserEvidenceTiming(windowBefore: 0.3, windowAfter: -0.1, deliveryAllowance: 0)
        }
        #expect(throws: LaserDataError.self) {
            try LaserEvidenceTiming(windowBefore: .infinity, windowAfter: 0, deliveryAllowance: 0)
        }
        let timing = try LaserEvidenceTiming(windowBefore: 0.35, windowAfter: 0.25, deliveryAllowance: 0.1)
        #expect(timing.captureWindow(crossing: 10) == 9.65...10.25)
        #expect(abs(timing.finalizationTime(crossing: 10) - 10.35) < 1e-9)
        #expect(throws: LaserDataError.self) {
            try LaserRoundConfiguration(evidenceTiming: timing, clearanceMargin: -1, diamondPoints: nil)
        }
    }

    @Test func preventsDuplicatePlayersAndMixedLaserMoves() throws {
        let encounter = try #require(LaserReplayScenarios.make().first).encounter
        let p1 = encounter.targets[0], p2 = encounter.targets[1]
        #expect(throws: LaserDataError.self) {
            try LaserEncounter(id: encounter.id, attemptID: encounter.attemptID, targets: [p1, p1])
        }
        let jumping = try LaserTarget(playerID: p2.playerID, calibrationRevision: 1, requiredMove: .jump,
                                      beam: p2.beam, warningTime: 7, crossingTime: 10)
        #expect(throws: LaserDataError.self) {
            try LaserEncounter(id: encounter.id, attemptID: encounter.attemptID, targets: [p1, jumping])
        }
        #expect(try LaserEncounter(id: encounter.id, attemptID: encounter.attemptID, targets: [p2, p1]).targets == [p1, p2])
    }

    @Test func fixturesAreRepeatableAndReuseSharedContracts() throws {
        let first = try LaserReplayScenarios.make()
        #expect(first.map(\.id) == (1...9).map { "R\($0)" })
        for _ in 0..<3 { #expect(try LaserReplayScenarios.make() == first) }
        for scenario in first {
            try scenario.input.validate()
            #expect(scenario.configuration.diamondPoints == nil)
            #expect(scenario.configuration.activityDuration + scenario.configuration.diamondTimeDuration == 315)
            #expect(scenario.encounter.targets.map(\.playerID) == PlayerID.allCases)
            for target in scenario.encounter.targets {
                let calibration = try #require(scenario.input.configuration.calibrations[target.playerID])
                #expect(target.calibrationRevision == calibration.revision)
                let baseline = calibration.mapping.gameY(imageY: calibration.standingCrownImageY,
                                                         layout: scenario.input.configuration.playerPlaneLayout)
                #expect(target.beam.lowerY < baseline)
            }
        }
    }

    @Test func officialReplayCasesPreserveTheirCriticalInputs() throws {
        let cases = try LaserReplayScenarios.make()
        #expect(cases[2].expected.allSatisfy { $0.judgement == .unavailable(.stale) })
        #expect(cases[3].input.records[0].deliveredAt - cases[3].captureEpoch > cases[3].expected[0].checkpoint)
        #expect(cases[4].input.records[0].snapshot?.players[.player1]?.jumpState.phase == .airborne)
        #expect(cases[4].input.records[1].snapshot?.players[.player1]?.jumpState.phase == .grounded)
        #expect(cases[5].input.records[0].snapshot == cases[5].input.records[1].snapshot)
        #expect(cases[6].pauseAtGameTime == 10.1)
        #expect(cases[6].expected.allSatisfy { $0.judgement == nil })
        #expect(cases[7].expected.map(\.selectedFrameID) == [1, 2])
        #expect(cases[8].input.records[0].snapshot?.players[.player1]?.geometry.crownY.validity == .missingLandmarks)
        #expect(cases[8].expected.allSatisfy { $0.selectedFrameID == 2 })
    }

    @Test func sharedValidityReasonsRemainAvailableOutsideMainActor() {
        let reason = Judgement.unavailable(.invalidEvidence(.leftWrist, .lowConfidence))
        func sendable<T: Sendable>(_ value: T) -> T { value }
        #expect(sendable(reason) == reason)
    }

    @MainActor
    @Test func sharedReplayDeliversIdenticalPacketsIncludingDuplicatesAndLateFrames() async throws {
        let scenarios = try LaserReplayScenarios.make()
        let last = try #require(scenarios.last)
        let earlier = try #require(last.input.records[0].snapshot)
        let later = try #require(last.input.records[1].snapshot)
        let outOfOrder = ReplayFixture(
            schemaVersion: 2, configuration: last.input.configuration, cameraGeometryRevision: 1,
            records: [ReplayRecord(deliveredAt: 110.2, snapshot: later),
                      ReplayRecord(deliveredAt: 110.3, snapshot: earlier)])
        for fixture in scenarios.map(\.input) + [outOfOrder] {
            try fixture.validate()
            for _ in 0..<2 {
                let provider = try ReplayBodyInput(fixture: fixture)
                try await provider.start(configuration: fixture.configuration)
                let stream = try provider.snapshotStream(generation: fixture.configuration.sessionGeneration)
                try provider.advance(to: try #require(fixture.records.last).deliveredAt)
                #expect(provider.diagnostics.rejectedSnapshotCount == 0)
                let expected = fixture.records.compactMap(\.snapshot)
                #expect(provider.latestSnapshot?.frameID == expected.map(\.frameID).max())
                await provider.stop() // Finishes the stream; buffered deliveries remain drainable.
                var delivered: [BodySnapshot] = []
                for await packet in stream { delivered.append(packet) }
                #expect(delivered == expected)
            }
        }
    }
}
