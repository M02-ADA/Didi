import Foundation
import Testing
@testable import Sedactive

/// The live path end to end in one session: real setup gates (bind, confirm, accepted
/// calibration), the complete-round plan built from the accepted references, the one live
/// GameClock, and verdicts produced only from the CP1 packets the provider delivers.
/// The packets are the existing controlled synthetic CP1 fixture (players standing still).
@MainActor struct LiveCompleteRoundIntegrationTests {
    private static func readyRig() async throws -> (J07SessionRig, LaserLiveWristRoundPlan) {
        let rig = try J07SessionRig(deferredPlan: true)
        try await rig.start(installDeferredPlan: false)
        let calibrations = try LaserReplayScript.load().input.configuration.calibrations
        let plan = try LaserLiveWristRoundPlan.completeRound(context: rig.fixture.context,
            calibrations: calibrations, layout: rig.fixture.input.playerPlaneLayout)
        try rig.session.installLiveWristRound(plan)
        return (rig, plan)
    }

    @Test func theFirstLaserIsJudgedFromDeliveredEvidence() async throws {
        let (rig, plan) = try await Self.readyRig()
        let session = rig.session
        #expect(session.hasLiveRoundPlan && session.encounters.isEmpty, "the director registers lasers as they come")
        #expect(session.plannedEncounters.count == 50)
        let host = try session.attachLiveFrameHost(); session.advanceLive(frameHost: host)
        var time = 0.25
        // Settling: one second of steady, valid evidence before Start is offered.
        while !session.canStartLiveRound, time < 3 { try await rig.send(time); time += 0.125 }
        #expect(session.canStartLiveRound)
        try session.beginLiveCountdown()
        while session.phase != .running, time < 8 { try await rig.send(time); time += 0.125 }
        #expect(session.phase == .running)
        // Keep delivering standing players until the first laser is judged.
        while session.events.contains(where: { if case .targetJudged = $0.kind { true } else { false } }) == false,
              time < 30 {
            try await rig.send(time); time += 0.125
        }
        let first = try #require(session.encounters.first)
        // Rebased once, at the minute's start (game time 0): exactly the script's own times.
        let script = try #require(plan.encounters.first { $0.id == first.id })
        #expect(first.targets.map(\.warningTime) == script.targets.map(\.warningTime))
        #expect(first.targets.map(\.crossingTime) == script.targets.map(\.crossingTime))
        #expect(first.attemptID != script.attemptID, "a fresh live attempt")
        let verdicts = try #require(session.state?.encounters.first { $0.encounter.id == first.id }?.judgements)
        // Judged from the delivered evidence: CLEAR or HIT, never UNAVAILABLE or pending.
        var hits = 0, clears = 0
        for player in PlayerID.allCases {
            switch try #require(verdicts[player]) {
            case .hit: hits += 1
            case .clear: clears += 1
            default: Issue.record("\(player): \(String(describing: verdicts[player]))")
            }
        }
        // Each verdict reaches team health and score through the one game.
        let configuration = try LaserFullReplayPlan.roundConfiguration()
        #expect(session.state?.teamHealth == configuration.initialTeamHealth - hits)
        #expect(session.state?.teamScore == clears * configuration.clearTargetPoints)
        #expect(session.results.filter { $0.encounterID == first.id }.count == 2)
        await session.stop()
    }

    /// The App path: no manual install. Once both calibrations are accepted for the current
    /// context, the session builds and installs the complete round itself, exactly once.
    @Test func acceptedSetupInstallsTheCompleteRoundByItself() async throws {
        var calls = 0
        let calibrations = try LaserReplayScript.load().input.configuration.calibrations
        let rig = try J07SessionRig(deferredPlan: true, liveRoundPlanner: { context, _ in
            calls += 1
            return try LaserLiveWristRoundPlan.completeRound(context: context, calibrations: calibrations,
                layout: .init(leftCenterX: -1, rightCenterX: 1, gameUnitsPerImageHeight: 2))
        })
        try await rig.start(installDeferredPlan: false)
        #expect(rig.session.hasLiveRoundPlan && rig.session.livePlanError == nil)
        #expect(rig.session.plannedEncounters.count == 50 && rig.session.state == nil, "nothing runs before Start")
        let installs = calls
        try await rig.send(0.25)
        #expect(calls == installs, "installed once")
        await rig.session.stop()
    }

    @Test func thePlanRefusesCalibrationsFromAnotherContext() async throws {
        let rig = try J07SessionRig(deferredPlan: true)
        try await rig.start(installDeferredPlan: false)
        var calibrations = try LaserReplayScript.load().input.configuration.calibrations
        calibrations.removeValue(forKey: .player2)
        #expect(throws: LaserDataError.self) {
            try LaserLiveWristRoundPlan.completeRound(context: rig.fixture.context, calibrations: calibrations,
                                                      layout: rig.fixture.input.playerPlaneLayout)
        }
        #expect(!rig.session.hasLiveRoundPlan)
        await rig.session.stop()
    }
}
