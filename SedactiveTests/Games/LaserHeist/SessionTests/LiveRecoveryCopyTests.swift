import Foundation
import Testing
@testable import Sedactive

/// The recovery screens say what is actually happening and who needs to act (13 November 2026):
/// no promise of an automatic resume or restart the session will not make, the player the round
/// is waiting for is named, and a recovery that needs a tap shows its button.
nonisolated struct LiveRecoveryCopyTests {
    private static func sample(_ player: PlayerID, tracking: TrackingStatus = .reliable, crown: Bool = true,
                               wrists: Bool = true, soles: Bool = true) throws -> PlayerBodySample {
        func v(_ ok: Bool, _ x: Double) throws -> EstimatedScalar {
            try EstimatedScalar(value: ok ? x : nil, validity: ok ? .valid : .missingLandmarks)
        }
        return PlayerBodySample(playerID: player, calibrationRevision: 1, trackingStatus: tracking,
            geometry: .init(crownY: try v(crown, 1.7), leftWristY: try v(wrists, 1), rightWristY: try v(wrists, 1),
                            leftSoleY: try v(soles, 0), rightSoleY: try v(soles, 0), centerX: try v(true, 0)),
            jumpState: .init(phase: .grounded, validity: .valid))
    }

    @Test func attentionFollowsTheReadinessRule() throws {
        #expect(LiveEvidenceAttention.of(try Self.sample(.player1)) == nil)
        #expect(LiveEvidenceAttention.of(try Self.sample(.player1, tracking: .uncertain)) == .tracking)
        #expect(LiveEvidenceAttention.of(try Self.sample(.player1, crown: false)) == .head)
        #expect(LiveEvidenceAttention.of(try Self.sample(.player1, wrists: false)) == .hands)
        #expect(LiveEvidenceAttention.of(try Self.sample(.player2, soles: false)) == .feet)
        #expect(LiveEvidenceAttention.of(nil) == .tracking)
        #expect(LiveEvidenceAttention.players(nil, roster: PlayerID.allCases).isEmpty, "no packet: nothing claimed")
        #expect(LiveEvidenceAttention.line([.player2: .feet], solo: false) == "P2: keep both feet in view.")
        #expect(LiveEvidenceAttention.line([.player1: .head, .player2: .tracking], solo: false)
                == "P1: keep your head in view. P2: step back into your place.")
        #expect(LiveEvidenceAttention.line([.player1: .tracking], solo: true) == "Step back into the middle.")
    }

    @Test func aRoundWaitingForOnePlayerNamesThem() {
        let ready = LaserAutomaticSetupCopy(.init(sessionPhase: .awaitingSetup, setupPhase: .awaitingGameplayReadiness,
            hasRoundPlan: true, readinessBlocker: .measurements, attention: [.player2: .feet]))
        #expect(ready.title == "Get ready!" && ready.instruction == "P2: keep both feet in view.")
        let paused = LaserAutomaticSetupCopy(.init(sessionPhase: .paused, setupPhase: .awaitingGameplayReadiness,
            hasRoundPlan: true, roundStarted: true, readinessBlocker: .measurements, attention: [.player1: .hands]))
        #expect(paused.title == "Tracking paused" && paused.action == nil)
        #expect(paused.instruction.hasPrefix("P1: keep your hands in view.") && paused.instruction.contains("score is kept"))
    }

    @Test func aCoopIdentityLossMidRoundDoesNotPromiseAResume() {
        let coop = LaserAutomaticSetupCopy(.init(sessionPhase: .paused, setupPhase: .restartRequired,
                                                 hasRoundPlan: true, roundStarted: true))
        #expect(coop.title == "Tracking paused" && coop.action == .restartSetup)
        #expect(coop.instruction.contains("Restart setup") && !coop.instruction.contains("to continue"))
        let solo = LaserAutomaticSetupCopy(.init(sessionPhase: .paused, setupPhase: .restartRequired,
                                                 hasRoundPlan: true, roundStarted: true, solo: true))
        #expect(solo.instruction.hasPrefix("Return to the middle to continue"), "Solo can re-link its one player")
    }

    @Test func anAutomaticRestartIsOnlyPromisedWhenItWillHappen() {
        let automatic = LaserAutomaticSetupCopy(.init(sessionPhase: .restartRequired, setupPhase: .restartRequired))
        #expect(automatic.instruction.contains("restarts by itself"))
        let exhausted = LaserAutomaticSetupCopy(.init(sessionPhase: .restartRequired, setupPhase: .restartRequired,
                                                      restartsAutomatically: false))
        #expect(!exhausted.instruction.contains("by itself") && exhausted.action == .restartSetup)
    }

    @Test func aRecoveryThatNeedsATapShowsContinue() {
        let copy = LaserAutomaticSetupCopy(.init(sessionPhase: .paused, setupPhase: .awaitingGameplayReadiness,
                                                 hasRoundPlan: true, roundStarted: true, recoveryNeedsContinue: true))
        #expect(copy.action == .continueRound && !copy.instruction.contains("automatically"))
    }

    #if DEBUG
    @Test func theDropoutProbeReportsEachRunOnce() throws {
        var probe = LiveEvidenceDropoutProbe()
        func packet(_ frame: UInt64, _ t: Double, p2Feet: Bool) throws -> BodySnapshot {
            BodySnapshot(sessionGeneration: UUID(), frameID: frame, capturedAt: t, cameraGeometryRevision: 1,
                         players: [.player1: try Self.sample(.player1), .player2: try Self.sample(.player2, soles: p2Feet)])
        }
        var lines: [String] = []
        for (i, ok) in [true, false, false, false, true, true].enumerated() {
            lines += probe.observe(try packet(UInt64(i + 1), Double(i) / 30, p2Feet: ok), roster: PlayerID.allCases, phase: "running")
        }
        #expect(lines.count == 1)
        #expect(lines.first?.hasPrefix("[LaserDropout] player2 unusable 3 frames · 0.100 s · missing feet(missingLandmarks) · during running") == true,
                "\(lines)")
        #expect(probe.observe(nil, roster: PlayerID.allCases, phase: "running").isEmpty)
    }

    /// The probe names the moment the tracker demands a re-bind, with each player's unusable time.
    @Test func theDropoutProbeReportsARebindOnce() throws {
        let fixture = try WristGameplayFixture()
        var probe = LiveEvidenceDropoutProbe()
        var lines: [String] = []
        for frame in UInt64(1)...4 {
            let packet = try fixture.packet(frame, 100 + Double(frame) * 0.1, points: [:], bad: frame >= 3 ? "rebind" : nil)
            lines += probe.observe(packet, roster: PlayerID.allCases, phase: "running")
        }
        let rebinds = lines.filter { $0.contains("re-bind required") }
        #expect(rebinds.count == 1 && rebinds[0].hasPrefix("[LaserDropout] player1 re-bind required (identity latched)"), "\(lines)")
    }
    #endif
}
