import Foundation
import Testing
@testable import Sedactive

/// The final vault entry is scripted presentation on held game time: Lemon jumps first,
/// Tangerine only in co-op, and while it plays `GameClock` neither advances nor maps a
/// capture to game time, so Diamond Time's seconds and collections start inside the vault.
nonisolated struct FinalVaultEntryTests {
    @Test func lemonJumpsFirstAndTangerineOnlyInCoop() throws {
        let coop = LaserFinalVaultTimeline(roster: [.player2, .player1])
        #expect(coop.jumpers == [.player1, .player2])
        let lemon = try #require(coop.jump(of: .player1)), tangerine = try #require(coop.jump(of: .player2))
        // One after the other: Tangerine takes off once Lemon is in the air.
        #expect(lemon.lowerBound >= LaserFinalVaultTimeline.open.upperBound)
        #expect(tangerine.lowerBound > lemon.lowerBound + LaserFinalVaultTimeline.anticipation)
        #expect(coop.push.lowerBound >= tangerine.upperBound && coop.land.lowerBound == coop.push.upperBound)
        #expect(coop.total == coop.land.upperBound)

        let solo = LaserFinalVaultTimeline(roster: [.player1])
        #expect(solo.jumpers == [.player1] && solo.jump(of: .player2) == nil)
        #expect(solo.jump(of: .player1) == lemon)
        #expect(solo.push.lowerBound >= lemon.upperBound && solo.total < coop.total)
        // About five seconds, never long enough to feel like a stall.
        #expect(solo.total > 4 && coop.total < 6)
    }

    @Test func anEntryOnlyMovesForwardAndStopsAtItsEnd() {
        var entry = LaserFinalVaultEntry(roster: [.player1])
        entry.advance(by: -1)
        entry.advance(by: .nan)
        #expect(entry.elapsed == 0 && !entry.isComplete)
        entry.advance(by: 2)
        #expect(entry.elapsed == 2)
        entry.advance(by: 100)
        #expect(entry.elapsed == entry.timeline.total && entry.isComplete)
    }

    // MARK: - Held GameClock

    private let generation = UUID(uuidString: "33000000-0000-4000-8000-0000000000f1")!
    private var context: BodyInputContext {
        BodyInputContext(sessionGeneration: generation, cameraGeometryRevision: 1,
                         calibrationRevisions: [.player1: 1, .player2: 1], cutovers: [:], isActive: true)
    }
    private func packet(_ frame: UInt64, _ time: Double) throws -> BodySnapshot {
        let base = try LH00TestData.load().records.first!.snapshot!
        let players = base.players.mapValues { sample in
            PlayerBodySample(playerID: sample.playerID, calibrationRevision: 1, trackingStatus: .reliable,
                             geometry: sample.geometry, jumpState: sample.jumpState)
        }
        return BodySnapshot(sessionGeneration: generation, frameID: frame, capturedAt: time,
                            cameraGeometryRevision: 1, players: players)
    }
    private func running() throws -> LaserLiveReadiness {
        var value = LaserLiveReadiness(policy: try LaserLiveTimingPolicy(settlingDuration: 0.125,
            maximumEvidenceAge: 0.5, countdownDuration: 0.25)) // Controlled fixture values only.
        try value.observe(packet(1, 1000), context: context, bindingConfirmed: true, at: 1000)
        try value.observe(packet(2, 1000.125), context: context, bindingConfirmed: true, at: 1000.125)
        try value.beginCountdown(at: 1000.125)
        try value.observe(packet(3, 1000.25), context: context, bindingConfirmed: true, at: 1000.25)
        try value.observe(packet(4, 1000.375), context: context, bindingConfirmed: true, at: 1000.375)
        return value
    }

    @Test func aHeldClockStaysRunningButSpendsNoGameTimeAndFencesCaptures() throws {
        var value = try running()
        for (frame, time) in zip(UInt64(5)..., stride(from: 1000.625, through: 1001.375, by: 0.25)) {
            try value.observe(packet(frame, time), context: context, bindingConfirmed: true, at: time)
        }
        #expect(value.gameTime == 1)
        try value.holdClock()
        #expect(value.isClockHeld && value.phase == .running)
        for (frame, time) in zip(UInt64(10)..., stride(from: 1001.5, through: 1006.5, by: 0.25)) {
            let held = try packet(frame, time)
            try value.observe(held, context: context, bindingConfirmed: true, at: time)
            #expect(value.gameTime == 1)
            #expect(value.capturedGameTime(for: held) == nil)
        }
        try value.releaseClock(at: 1006.5)
        #expect(!value.isClockHeld && value.gameTime == 1)
        // Game time continues where it stopped; nothing captured before the release counts.
        let before = try packet(100, 1006.25), after = try packet(101, 1006.75)
        #expect(value.capturedGameTime(for: before) == nil)
        try value.observe(after, context: context, bindingConfirmed: true, at: 1006.75)
        #expect(value.phase == .running && value.gameTime == 1.25)
        #expect(value.capturedGameTime(for: after) == 1.25)
    }

    @Test func aPauseEndsTheHoldAndTheCountdownResumesTheClockAsUsual() throws {
        var value = try running()
        try value.observe(packet(5, 1000.75), context: context, bindingConfirmed: true, at: 1000.75)
        try value.holdClock()
        #expect(value.isClockHeld && value.gameTime == 0.375)
        try value.setManualPause(true, at: 1002)
        #expect(!value.isClockHeld && value.phase == .paused && value.gameTime == 0.375)
        // Releasing outside a hold, or holding outside RUNNING, changes nothing.
        try value.releaseClock(at: 1002.5)
        try value.holdClock()
        #expect(!value.isClockHeld && value.gameTime == 0.375)
    }
}
