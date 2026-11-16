import Foundation
import Testing
@testable import Sedactive

func wristForPaw(at position: LaserDiamondPosition, player: PlayerID,
                calibration: PlayerCalibration, layout: PlayerPlaneLayout) -> WristPlanePoint {
    let height = LaserLiveRoundGeometryV1.standingHeight(calibration, layout: layout)
    let raised = (LaserDiamondTimeBoard.height - LaserDiamondTimeBoard.inset - position.y)
        / (LaserDiamondTimeBoard.height - 2 * LaserDiamondTimeBoard.inset)
    let y = LaserDiamondTimeBoard.lowWristHeight
        + raised * (LaserDiamondTimeBoard.highWristHeight - LaserDiamondTimeBoard.lowWristHeight)
    let x = (LaserDiamondTimeBoard.homeX(player: player, solo: false) - position.x) / LaserDiamondTimeBoard.lateralGain
    return WristPlanePoint(x: layout.centerX(for: player) + x * height, y: y * height)
}

@MainActor struct LiveDiamondTimeRoundTests {
    @Test func coopWristContactsOpenFiveVaultsAndFinishDiamondTimeWithRealTotals() async throws {
        let rig = try J07SessionRig(deferredPlan: true)
        try await rig.start(installDeferredPlan: false)
        let calibrations = try LaserReplayScript.load().input.configuration.calibrations
        let complete = try LaserLiveWristRoundPlan.completeRound(context: rig.fixture.context,
            calibrations: calibrations, layout: rig.fixture.input.playerPlaneLayout, seed: 7, segmentLength: 10)
        try rig.session.installLiveWristRound(.init(expectedContext: complete.expectedContext,
            configuration: complete.configuration, encounters: complete.encounters,
            timing: .init(settlingDuration: 0.125, maximumEvidenceAge: 0.5, countdownDuration: 0.25),
            diamonds: complete.diamonds, director: complete.director))
        try await rig.finishStart()

        let outside = Dictionary(uniqueKeysWithValues: LaserContactHand.ordered.map { ($0, WristGameplayFixture.outside) })
        var hostTime = 0.625
        func send(_ points: [LaserContactHand: WristPlanePoint] = [:]) async throws {
            hostTime += 0.125
            let gameTime = hostTime - 0.625
            let samples = try rig.fixture.players.mapValues { standing in
                let center = try EstimatedScalar(value: complete.diamonds.layout.centerX(for: standing.playerID), validity: .valid)
                let target = rig.session.encounters.flatMap(\.targets).first {
                    $0.playerID == standing.playerID && abs($0.crossingTime - gameTime) <= 0.25
                }
                guard let target else {
                    let g = standing.geometry
                    return PlayerBodySample(playerID: standing.playerID, calibrationRevision: standing.calibrationRevision,
                        trackingStatus: standing.trackingStatus, geometry: .init(crownY: g.crownY, leftWristY: g.leftWristY,
                            rightWristY: g.rightWristY, leftSoleY: g.leftSoleY, rightSoleY: g.rightSoleY, centerX: center),
                        jumpState: standing.jumpState)
                }
                let margin = complete.configuration.clearanceMargin
                let upper = try EstimatedScalar(value: target.beam.lowerY - margin - 0.01, validity: .valid)
                let sole = try EstimatedScalar(value: target.beam.upperY + margin + 0.01, validity: .valid)
                return PlayerBodySample(playerID: standing.playerID, calibrationRevision: standing.calibrationRevision,
                    trackingStatus: .reliable, geometry: target.requiredMove == .duck
                        ? .init(crownY: upper, leftWristY: upper, rightWristY: upper, leftSoleY: standing.geometry.leftSoleY,
                                rightSoleY: standing.geometry.rightSoleY, centerX: center)
                        : .init(crownY: standing.geometry.crownY, leftWristY: standing.geometry.leftWristY,
                                rightWristY: standing.geometry.rightWristY, leftSoleY: sole, rightSoleY: sole,
                                centerX: center),
                    jumpState: target.requiredMove == .jump ? .init(phase: .airborne, validity: .valid) : standing.jumpState)
            }
            try await rig.send(hostTime, points: points, bodySamples: samples)
        }

        for vaultNumber in 1...5 {
            for _ in 0..<100 where rig.session.state?.phase == .activity {
                try await send()
            }
            try #require(rig.session.state?.phase == .vault, "Expected vault \(vaultNumber)")
            let zones = try #require(rig.session.liveVaultZones)
            for button in LaserVaultButton.allCases {
                try await send(outside)
                let wrists = Dictionary(uniqueKeysWithValues: zones.filter { $0.button == button }.map {
                    (LaserContactHand(playerID: $0.playerID, wrist: .left), WristPlanePoint(x: $0.position.x, y: $0.position.y))
                })
                try await send(wrists)
            }
            #expect(rig.session.state?.missionProgress == vaultNumber)
        }
        try #require(rig.session.state?.phase == .diamondTime)
        let start = try #require(rig.session.state?.gameTime)
        #expect(rig.session.diamondStates.values.allSatisfy { $0.outcome != nil })
        let score = try #require(rig.session.state?.teamScore)

        // The final vault entry (Lemon, then Tangerine) plays on held game time: a reach
        // during it collects nothing and Diamond Time's seconds have not started.
        let entry = try #require(rig.session.finalVaultEntry)
        #expect(entry.timeline.jumpers == [.player1, .player2] && !entry.isComplete)
        let entryStart = hostTime
        try await send(outside)
        for _ in 0..<100 where rig.session.finalVaultEntry?.isComplete == false { try await send() }
        #expect(rig.session.finalVaultEntry?.isComplete == true)
        #expect(hostTime - entryStart >= entry.timeline.total)
        #expect(rig.session.state?.gameTime == start && rig.session.diamondsCollected == 0)
        #expect(rig.session.state?.phase == .diamondTime)

        try await send(outside)
        #expect(Set(rig.session.diamondTimePaws.keys) == Set(LaserContactHand.ordered))
        let before = rig.session.diamondStates.values.filter { $0.outcome == nil }
        #expect(before.count == 6)
        #expect(before.allSatisfy { $0.interactionDeadline == start + 20 })
        #expect(before.allSatisfy { $0.spawn.eligiblePlayers == Set(PlayerID.allCases) })
        let target = try #require(before.sorted { $0.spawn.id.uuidString < $1.spawn.id.uuidString }.first)
        let hands = LaserContactHand.ordered.filter { $0.playerID == .player2 }
        func wrists(at position: LaserDiamondPosition) throws -> [LaserContactHand: WristPlanePoint] {
            try Dictionary(uniqueKeysWithValues: hands.map { hand in
                let calibration = try #require(calibrations[hand.playerID])
                return (hand, wristForPaw(at: position, player: hand.playerID,
                                          calibration: calibration, layout: complete.diamonds.layout))
            })
        }
        let overlap = try wrists(at: target.spawn.position)

        for (elapsed, count) in [(10.0, 8), (15.0, 10)] {
            for _ in 0..<200 where (rig.session.state?.gameTime ?? 0) < start + elapsed {
                try await send(outside)
            }
            let active = rig.session.diamondStates.values.filter { $0.outcome == nil }
            #expect(active.count == count)
            #expect(before.allSatisfy { active.contains($0) })
        }
        let beforePickup = Set(rig.session.diamondStates.keys)
        let board = LaserDiamondTimeBoard.self
        let activePositions = rig.session.diamondStates.values.filter { $0.outcome == nil }.map { $0.spawn.position }
        // Stage the two hands near the target, outside every hitbox. This
        // isolates the shared pickup from legitimate contacts on other slots.
        let candidates = try (0..<32).map { step in
            let angle = Double(step) * .pi / 16
            return try LaserDiamondPosition(x: target.spawn.position.x + cos(angle) * 0.17,
                                            y: target.spawn.position.y + sin(angle) * 0.17)
        }
        let staging = try #require(candidates.first { point in
            point.x >= board.inset && point.x <= board.width - board.inset
                && point.y >= board.inset && point.y <= board.height - board.inset
                && activePositions.allSatisfy { board.distance(point, $0) > board.pawRadius + board.diamondRadius + 0.012 }
        })

        // The initial target is still collectible near the end of the phase.
        for _ in 0..<200 where (rig.session.state?.gameTime ?? 0) < start + 18 { try await send() }
        #expect(rig.session.diamondTimePaws.isEmpty)
        try await send(overlap)
        #expect(rig.session.diamondsCollected == 0, "a newly reacquired hand cannot collect from inside")
        try await send(wrists(at: staging))
        try await send(overlap)
        #expect(rig.session.diamondsCollected == 1 && rig.session.state?.teamScore == score + 25)
        let active = rig.session.diamondStates.values.filter { $0.outcome == nil }
        #expect(active.count == 10)
        let replacement = try #require(active.first { candidate in !beforePickup.contains(candidate.spawn.id) })
        #expect(replacement.spawn.position != target.spawn.position && replacement.interactionDeadline == start + 20)
        #expect(LaserDiamondTimeBoard.distance(replacement.spawn.position, target.spawn.position)
                >= LaserDiamondTimeBoard.spawnClearance)

        // Keeping both paws at the collected target cannot score again.
        for _ in 0..<20 where rig.session.summary == nil { try await send(overlap) }
        let summary = try #require(rig.session.summary)
        #expect(summary.outcome == .completed && summary.vaultsOpened == 5)
        #expect(summary.diamondsCollected == 1 && summary.teamScore == score + 25)
        #expect(summary.gameDuration == start + 20 && summary.activityDuration == 70)
        #expect(rig.session.diamondStates.values.filter { $0.outcome == nil }.isEmpty)
        await rig.session.stop()
        #expect(rig.session.summary == summary)
        #expect(rig.controls.input.claimCount == 1 && rig.controls.input.releaseCount == 1)
    }
}
