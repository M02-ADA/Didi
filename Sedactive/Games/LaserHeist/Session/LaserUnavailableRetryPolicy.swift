//
//  LaserUnavailableRetryPolicy.swift
//  Sedactive
//

import Foundation

/// POSE-FIRST TRACKING (Kevin, 14 November 2026; production default, DEBUG `-trackingBaseline`
/// restores the previous rule). Previously every UNAVAILABLE verdict paused the round. Now an UNAVAILABLE for a
/// player who is still PRESENT is what the rules already make it: an unscored attempt (no damage,
/// no points), and play continues. It cannot become a way around the lasers:
/// - the `consecutive`-th UNAVAILABLE in a row for one player pauses the round;
/// - so does the `perRound`-th for one player in a round;
/// - so does any UNAVAILABLE for a player who is not present.
/// The pause is today's: unresolved lasers, and the one that triggered it, are withdrawn and retried
/// by the existing recovery planner after the countdown. A CLEAR or HIT resets that player's run.
/// An UNAVAILABLE let through without a pause is final: unscored, counted, and never withdrawn by a
/// later pause (withdrawing an old laser would shift every later laser of the round back to it).
/// The UNAVAILABLE that triggers the pause is withdrawn and retried, as in production.
nonisolated struct LaserUnavailableRetryPolicy: Sendable {
    let budget: PoseFirstCandidate.UnavailableBudget
    private(set) var reviewed: Set<LaserTargetKey> = []
    private(set) var consecutive: [PlayerID: Int] = [:]
    private(set) var total: [PlayerID: Int] = [:]
    /// Encounters with an UNAVAILABLE let through without a pause (unscored, not to be withdrawn).
    private(set) var forgiven: Set<UUID> = []
    /// Why the last review asked for a pause (diagnostics).
    private(set) var lastPauseReason: String?

    init(budget: PoseFirstCandidate.UnavailableBudget = .init()) { self.budget = budget }

    /// Reviews every finalized target verdict once, in order. Returns true when the round must pause.
    mutating func review(_ verdicts: [(key: LaserTargetKey, judgement: Judgement)],
                         isPresent: (PlayerID) -> Bool) -> Bool {
        var pause = false
        for (key, judgement) in verdicts where !reviewed.contains(key) {
            let player = key.playerID
            switch judgement {
            case .pending: continue
            case .clear, .hit:
                reviewed.insert(key)
                consecutive[player] = 0
            case .unavailable(let reason):
                reviewed.insert(key)
                consecutive[player, default: 0] += 1
                total[player, default: 0] += 1
                var triggers = true
                if !isPresent(player) {
                    lastPauseReason = "\(player.rawValue) not present (\(reason))"
                } else if consecutive[player, default: 0] >= budget.consecutive {
                    lastPauseReason = "\(player.rawValue) \(budget.consecutive) UNAVAILABLE in a row (\(reason))"
                } else if total[player, default: 0] >= budget.perRound {
                    lastPauseReason = "\(player.rawValue) \(budget.perRound) UNAVAILABLE this round (\(reason))"
                } else { triggers = false }
                if triggers { pause = true; forgiven.remove(key.encounterID) }
                else { forgiven.insert(key.encounterID) }
            }
        }
        return pause
    }

    /// After a pause and its countdown: the run of UNAVAILABLEs starts again (the round total stays).
    mutating func resumed() { consecutive = [:] }
}
