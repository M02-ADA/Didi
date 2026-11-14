import Foundation
import Testing
@testable import Sedactive

/// SQUAT PRESENCE (PROPOSED by Kevin, 13 November 2026 — needs Edo's review): a player still in view as a partial body (both
/// shoulders, hips unseen in a squat) where they just were is PRESENT: their identity does not
/// expire, so the other player is never latched; it never matches, measures or confirms. Every
/// takeover protection stays: an absent player, an ambiguous partial, or a partial at the other
/// player's place keeps today's behaviour.
nonisolated struct SquatPresenceTrackingTests {
    typealias F = TrackingFixtures
    private static let squat = F.candidate(10, x: 0.75, y: 0.4, missing: [.leftHip, .rightHip])

    private func run(_ hidden: [PoseCandidate], seconds: Double) throws -> (during: PlayerTrackingSnapshot, after: PlayerTrackingSnapshot) {
        var tracker = try F.tracker(policy: B2bExperimentalPolicyV1.value)
        var t = 1.0, frame: UInt64 = 0
        func step(_ people: [PoseCandidate]) throws -> PlayerTrackingSnapshot {
            frame += 1; t += 1.0 / 30
            return try tracker.process(F.input(frame, t, people))
        }
        for _ in 0..<10 { _ = try step(F.pair) }
        var during = tracker.snapshot
        for _ in 0..<Int((seconds * 30).rounded()) { during = try step(hidden) }
        var after = tracker.snapshot
        for _ in 0..<15 { after = try step(F.pair) }
        return (during, after)
    }

    @Test(arguments: [1.0, 2.0, 4.0]) func aHeldSquatKeepsBothIdentities(seconds: Double) throws {
        let (during, after) = try run([Self.squat, F.candidate(20, x: 0.25)], seconds: seconds)
        #expect(during.player1.state == .uncertain && during.player1.candidateID == nil, "present, never matched or measured")
        #expect(during.player2.state == .tracking && !during.player2.requiresRebind, "the other player is never latched")
        #expect(after.player1.state == .tracking && after.player1.candidateID == 10 && !after.player1.requiresRebind)
        #expect(after.player2.candidateID == 20 && !after.player2.requiresRebind)
    }

    @Test func anAbsentPlayerIsStillUnknownNotPresent() throws {
        let (_, after) = try run([F.candidate(20, x: 0.25)], seconds: 1.2)
        #expect(after.player1.requiresRebind || after.player2.requiresRebind, "unchanged: an expired competitor is unknown")
    }

    @Test func aPartialBodyAtTheOtherPlayersPlaceKeepsNoOnePresent() throws {
        // P1 gone; a shoulders-only body appears right where P2 stands (beside P2's own body).
        let impostor = F.candidate(30, x: 0.27, y: 0.5, missing: [.leftHip, .rightHip])
        let (_, after) = try run([F.candidate(20, x: 0.25), impostor], seconds: 1.2)
        #expect(after.player1.requiresRebind || after.player2.requiresRebind)
    }

    @Test func twoPartialBodiesNearTheMissingPlayerKeepNoOnePresent() throws {
        let a = F.candidate(30, x: 0.72, y: 0.45, missing: [.leftHip, .rightHip])
        let b = F.candidate(31, x: 0.80, y: 0.45, missing: [.leftHip, .rightHip])
        let (_, after) = try run([a, b, F.candidate(20, x: 0.25)], seconds: 1.2)
        #expect(after.player1.requiresRebind || after.player2.requiresRebind, "ambiguous presence is no presence")
    }

    /// A scripted 30 Hz sequence after binding the standard pair: each step's people.
    private func play(_ script: [[PoseCandidate]], settle: [PoseCandidate] = F.pair, settleFrames: Int = 15) throws -> PlayerTrackingSnapshot {
        var tracker = try F.tracker(policy: B2bExperimentalPolicyV1.value)
        var t = 1.0, frame: UInt64 = 0
        func step(_ people: [PoseCandidate]) throws -> PlayerTrackingSnapshot {
            frame += 1; t += 1.0 / 30
            return try tracker.process(F.input(frame, t, people))
        }
        for _ in 0..<10 { _ = try step(F.pair) }
        for people in script { _ = try step(people) }
        var last = tracker.snapshot
        for _ in 0..<settleFrames { last = try step(settle) }
        return last
    }

    @Test func bothPlayersCrouchingAtOnceKeepTheirIdentities() throws {
        let both = [Self.squat, F.candidate(20, x: 0.25, y: 0.4, missing: [.leftHip, .rightHip])]
        let after = try play(Array(repeating: both, count: 60))
        #expect(after.player1.candidateID == 10 && after.player2.candidateID == 20)
        #expect(!after.player1.requiresRebind && !after.player2.requiresRebind)
    }

    @Test func aSmallerPlayersSquatKeepsTheirIdentity() throws {
        // A child: a shorter torso; the standard pair replaced by an adult and a child.
        let child = F.candidate(20, x: 0.25, y: 0.35, length: 0.12)
        let childSquat = F.candidate(20, x: 0.25, y: 0.28, length: 0.12, missing: [.leftHip, .rightHip])
        var tracker = try F.tracker(policy: B2bExperimentalPolicyV1.value)
        var t = 1.0, frame: UInt64 = 0
        func step(_ people: [PoseCandidate]) throws -> PlayerTrackingSnapshot {
            frame += 1; t += 1.0 / 30
            return try tracker.process(F.input(frame, t, people))
        }
        for _ in 0..<10 { _ = try step([F.candidate(10, x: 0.75), child]) }
        for _ in 0..<60 { _ = try step([F.candidate(10, x: 0.75), childSquat]) }
        var after = tracker.snapshot
        for _ in 0..<15 { after = try step([F.candidate(10, x: 0.75), child]) }
        #expect(after.player2.candidateID == 20 && !after.player1.requiresRebind && !after.player2.requiresRebind)
    }

    /// A crouching player who moves next to the other player is no longer unambiguous: presence
    /// stops there and today's rule applies (never a silent swap).
    @Test func aCrouchingPlayerBesideTheOtherIsNotPresent() throws {
        var script: [[PoseCandidate]] = []
        for i in 0..<45 { // P1 crouches and shuffles toward P2 (0.75 → 0.30)
            let x = 0.75 - 0.45 * Double(i) / 44
            script.append([F.candidate(10, x: x, y: 0.4, missing: [.leftHip, .rightHip]), F.candidate(20, x: 0.25)])
        }
        let after = try play(script, settle: [F.candidate(10, x: 0.30), F.candidate(20, x: 0.25)])
        #expect(after.player2.candidateID != 10, "the crouching player never becomes P2")
        #expect(after.player1.candidateID != 20, "and P2 never becomes P1")
    }

    /// The takeover the presence rule must not open: P1 crouches, shuffles out of view at the edge,
    /// and within half a second a different person stands up where P1 USED to stand.
    @Test func aNewPersonWherePlayerOneUsedToStandIsNotPlayerOne() throws {
        var script: [[PoseCandidate]] = []
        for i in 0..<15 { // crouched, shuffling to the right edge
            let x = 0.75 + 0.18 * Double(i) / 14
            script.append([F.candidate(10, x: x, y: 0.4, missing: [.leftHip, .rightHip]), F.candidate(20, x: 0.25)])
        }
        script += Array(repeating: [F.candidate(20, x: 0.25)], count: 9) // gone (0.3 s)
        let after = try play(script, settle: [F.candidate(40, x: 0.75), F.candidate(20, x: 0.25)])
        #expect(after.player1.candidateID != 40, "the newcomer never inherits P1 (or P1's calibration)")
        #expect(after.player2.candidateID == 20)
    }

    /// Two players crossing (standing, both fully visible) are untouched by the presence rule.
    @Test func crossingPlayersKeepTodaysRules() throws {
        var script: [[PoseCandidate]] = []
        for i in 0..<30 {
            let k = Double(i) / 29
            script.append([F.candidate(10, x: 0.75 - 0.5 * k), F.candidate(20, x: 0.25 + 0.5 * k)])
        }
        let after = try play(script, settle: [F.candidate(10, x: 0.25), F.candidate(20, x: 0.75)])
        #expect(after.player1.candidateID != 20 && after.player2.candidateID != 10, "no silent swap")
    }
}
